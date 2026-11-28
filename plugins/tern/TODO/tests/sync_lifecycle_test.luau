-- The window and host lifecycles behind board sync, driven through the same libraries window.luau and host.luau call.
local settings = require("../lib/settings")
local sync_pane = require("../lib/sync_pane")
local selection = require("../lib/host_selection")
local sync_gate = require("../lib/sync_gate")
local sync_status = require("../lib/sync_status")
local wait_requests = require("../lib/wait_requests")
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
-- A bare memo wired the way window.luau wires it (gate + repaint request + status clear).
local function newMemo() return sync_pane.new({ gate = sync_gate.new(), repaint = function() end, clear = function() end }) end
local function change(kv, act, value)
    local before = settings.load(kv)
    settings.save(kv, settings.apply(before, act, value, cands), before)
end

-- A window as window.luau builds it: the real status line (zero-delay repaint timers), memo and gate, a pane that
-- draws from them, and `tick` running the same start -> decide -> succeeded path as syncTick. `async = true` leaves a
-- pass pending (as the real board claim and read are) until `finish`, so a repaint can run before it completes.
local function windowFixture(kv)
    local f = { timers = {}, paints = 0, shown = "", async = false }
    f.gate = sync_gate.new()
    f.memo = sync_pane.new({ gate = f.gate, repaint = function() f.status.check() end, clear = function() f.status.set(nil) end })
    f.status = sync_status.new({
        timer = function(_ms, fn) table.insert(f.timers, fn) end,
        pane = function(_cx) return 9 end,
        paint = function(_cx, _pane) f.paints += 1; f.draw(); f.status.drawn() end,
        key = function() return f.memo.renderKey(settings.load(kv)) end,
    })
    function f.draw()
        local s = settings.load(kv)
        f.shown = table.concat(flat(settings.draw(ui, s, settings.eligible(s, cands), f.status.get(), f.memo.extra(s, cands))), "\n")
    end
    function f.flush() local queued = f.timers; f.timers = {}; for _, fn in queued do fn({}) end end
    f.syncs = 0
    function f.finish()
        local p = f.pending; f.pending = nil; f.busy = false
        f.memo.succeeded(p.attach, p.key, p.rev, p.gen, 0, p.now, p.title, "/boards/" .. p.title .. ".md")
        f.status.set("Board \"" .. p.title .. "\" synced \xc2\xb7 0 change(s)")
    end
    -- session -> { panel, entry | read, title } for sessions whose view is open; a session missing from it has no view.
    function f.tick(views, now)
        local s = settings.load(kv)
        local target
        for _, c in settings.eligible(s, cands) do if c.pane == s.attach then target = c end end
        local on = f.memo.start(s, target) -- before every early return, as syncTick does
        if not on or f.busy then return end
        local v = target and views[target.pane]
        local read = if v then (v.read or (if v.entry then { kind = "entry", entry = v.entry } else { kind = "waiting" })) else nil
        local verdict, detail = f.memo.decide(s, target, if v then "match" else "none", if v then v.panel else nil, read, now, false)
        if verdict == "blocked" then f.status.set(detail); return end
        if verdict == "skip" then return end
        f.syncs += 1
        f.pending = { attach = target.pane, key = detail, rev = v.entry.rev, gen = f.gate.generation(), now = now, title = v.title }
        f.busy = true
        if not f.async then f.finish() end
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
        assert(a.status.get():find("Waiting for this session to publish a plan. Run /glitch-execute", 1, true), tostring(a.status.get()))
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
        local waiting = { discover_pid = 4242, discover_birth = "linux:boot:1", discovery_label = "Local · host" }
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
        for _, bad in { { schema = 2, discover_pid = -1, birth = "b" }, { schema = 2, discover_pid = 1.5, birth = "b" }, { schema = 2, discover_pid = "9", birth = "b" },
            { schema = 2, discover_pid = 5, birth = "b", label = 7 }, { schema = 1, discover_pid = 5, birth = "b" } } do
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
        local none = { ok = true, state = "none" }
        -- The host never reads the plugin store: its view waits only because the window's event said so.
        local view = { patient = false }
        local now = 1000
        local waits = wait_requests.new(function(panel, on) selection.applyLease(view, selection.waitLease({ ev = "action", id = "main", act = "sync-wait", value = if on then "on:w1" else "off:w1" }), now) end)
        local function patient() return selection.patience(view, now) end
        assert(not patient(), "a view that was never told to wait must not wait")
        waits.sync(77)
        assert(patient())
        for _ = 1, 5 do
            now += 5000; waits.sync(77)
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
    {"an async pass whose status text repeats still repaints the restored board (repaint ran before it finished)", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "sync", "on"); change(kv, "attach", "1")
        local a = windowFixture(kv)
        local x = { panel = 10, entry = { rev = 1, plan = planOf("plan-0123456789ab") }, title = "Plan X" }
        a.tick({ [1] = x }, 1000); a.flush(); a.draw()
        assert(a.shown:find("Open board", 1, true) and a.status.get():find("synced", 1, true), a.shown)
        -- another window's work makes this one forget its board while the success text stays on screen
        a.memo.forget(); a.status.check(); a.flush()
        assert(not a.shown:find("Open board", 1, true), "the forgotten board was not repainted away")
        local same = a.status.get()
        -- the pass runs again, asynchronously: the repaint happens BEFORE it completes
        a.gate.reset(); a.async = true
        a.tick({ [1] = x }, 2000)
        a.flush()
        assert(a.pending and not a.shown:find("Open board", 1, true))
        a.finish() -- records the board; the status text is identical to the one already shown
        assert(a.status.get() == same, "the test needs an identical success text")
        a.flush()
        assert(a.shown:find("Board: Plan X", 1, true) and a.shown:find("Open board", 1, true), "restored board stayed invisible: " .. a.shown)
    end},
    {"another window turning sync Off clears the board and the success line here at the next tick, even mid-pass", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "sync", "on"); change(kv, "attach", "1")
        local a = windowFixture(kv)
        local x = { panel = 10, entry = { rev = 1, plan = planOf("plan-0123456789ab") }, title = "Plan X" }
        a.tick({ [1] = x }, 1000); a.flush(); a.draw()
        assert(a.shown:find("Open board", 1, true) and a.shown:find("synced", 1, true))
        change(kv, "sync", "off") -- window B
        a.tick({ [1] = x }, 2000); a.flush()
        assert(not a.shown:find("Open board", 1, true) and not a.shown:find("synced", 1, true) and not a.shown:find("Plan X", 1, true), a.shown)
        assert(a.status.get() == nil)
        -- turning it on again repeats the pass: nothing remembered from before survives
        change(kv, "sync", "on")
        local before = a.syncs
        a.tick({ [1] = x }, 2500)
        assert(a.syncs == before + 1, "the revision gate still matched after sync was off")
        -- and with a pass still running (busy returns early too)
        a.async = true; a.gate.reset(); a.tick({ [1] = x }, 3000)
        assert(a.busy)
        change(kv, "sync", "off")
        a.tick({ [1] = x }, 4000); a.flush()
        assert(not a.shown:find("Open board", 1, true) and a.status.get() == nil, a.shown)
    end},
    {"a restored waiting view is bound to the process it saw: the saved birth is required and a reused PID has another birth", function()
        local valid = function(src) return type(src) == "table" and type(src.path) == "string" end
        local saved = selection.saveState({ discover_pid = 4242, discover_birth = "linux:boot:111", discovery_label = "L" })
        assert(saved.discover_pid == 4242 and saved.birth == "linux:boot:111")
        local restored = selection.restoreState(saved, valid)
        assert(restored.discover_pid == 4242 and restored.discover_birth == "linux:boot:111")
        assert(selection.saveState({ discover_pid = 4242 }).discover_pid == nil, "a PID without its process birth must not be saved")
        for _, bad in { { schema = 2, discover_pid = 4242 }, { schema = 2, discover_pid = 4242, birth = 7 }, { schema = 2, discover_pid = 4242, birth = "" },
            { schema = 2, discover_pid = 4242, birth = string.rep("b", 161) } } do
            assert(not selection.hasWork(selection.restoreState(bad, valid)), "an unbound waiting save must restore nothing")
        end
    end},
    {"the wait request is only the window's sync-wait action, with on or off", function()
        assert(selection.waitRequest({ ev = "action", id = "main", act = "sync-wait", value = "on" }) == true)
        assert(selection.waitRequest({ ev = "action", id = "main", act = "sync-wait", value = "off" }) == false)
        for _, bad in { { ev = "action", id = "main", act = "sync-wait", value = "yes" }, { ev = "action", id = "main", act = "confirm-selection", value = "on" },
            { ev = "action", id = "other", act = "sync-wait", value = "on" }, { ev = "key", id = "main", act = "sync-wait", value = "on" } } do
            assert(selection.waitRequest(bad) == nil)
        end
    end},
    {"switching the attachment revokes the wait on the previous view, and its host stops discovery", function()
        -- Two views, each with its own host state; events are the only road from window to host.
        local hosts, now, discoveries = { [10] = {}, [20] = {} }, 1000, { [10] = 0, [20] = 0 }
        local waits = wait_requests.new(function(panel, on)
            selection.applyLease(hosts[panel], selection.waitLease({ ev = "action", id = "main", act = "sync-wait", value = if on then "on:w1" else "off:w1" }), now)
        end)
        local none = { ok = true, state = "none" }
        local function hostTick(panel)
            if selection.discoveryStep(0, true, none, selection.patience(hosts[panel], now)).action == "wait" then discoveries[panel] += 1 end
        end
        waits.sync(10) -- session A, sync On
        hostTick(10); assert(discoveries[10] == 1)
        waits.sync(20) -- another tab selects session B: the window now wants B's view only
        assert(not selection.patience(hosts[10], now) and selection.patience(hosts[20], now))
        for _ = 1, 3 do now += 2000; waits.sync(20); hostTick(10); hostTick(20) end
        assert(discoveries[10] == 1, "A kept polling after the switch: " .. discoveries[10])
        assert(discoveries[20] == 3)
        waits.sync(nil) -- sync turned Off for B
        now += 2000; hostTick(20); assert(discoveries[20] == 3)
    end},
    {"sync turned Off, and an attachment that becomes nil, each revoke the wait", function()
        local log = {}
        local waits = wait_requests.new(function(panel, on) table.insert(log, panel .. (if on then ":on" else ":off")) end)
        waits.sync(10); waits.sync(10)
        assert(table.concat(log, ",") == "10:on,10:on", table.concat(log, ",")) -- renewed every tick
        waits.sync(nil) -- sync Off
        assert(log[#log] == "10:off" and #waits.asked() == 0)
        waits.sync(nil); assert(#log == 3, "revoke is sent once")
        waits.sync(11); waits.revokeAll() -- attachment became nil / window teardown
        assert(log[#log] == "11:off" and #waits.asked() == 0, table.concat(log, ","))
    end},
    {"a host whose window stops renewing drops patience after 15 s, and the view goes dormant, never closed", function()
        local view = { leases = { w1 = 1000 }, hadWait = true }
        assert(selection.PATIENCE_MS == 15000)
        assert(selection.patience(view, 1000 + 15000))
        assert(not selection.patience(view, 1000 + 15001) and next(view.leases) == nil)
        local none = { ok = true, state = "none" }
        local step = selection.discoveryStep(0, true, none, selection.patience(view, 99999), view.hadWait)
        assert(step.action == "dormant", step.action)
        assert(selection.discoveryStep(0, true, none, false, false).action == "none", "a view that never waited still closes")
        assert(not selection.patience({ leases = { w1 = "x" } }, 5), "an unstamped lease is not trusted")
        selection.applyLease(view, { on = true, rid = "w1" }, 100000) -- the window renewed
        assert(selection.patience(view, 100000 + 14000))
        assert(selection.discoveryStep(0, true, none, true, true).action == "wait")
        -- a renewal reactivates, and a plan published meanwhile is then found
        local published = { ok = true, state = "active", source = { path = "/p.md", plan_id = "plan-abc", publication = { k = 1 } } }
        assert(selection.discoveryStep(0, true, published, selection.patience(view, 100000), true).action == "active")
    end},
    {"two requesters: one window's revoke leaves the other's renewed wait alive; both revoked is dormant", function()
        local view, now = {}, 1000
        local on = function(rid) return selection.waitLease({ ev = "action", id = "main", act = "sync-wait", value = "on:" .. rid }) end
        local off = function(rid) return selection.waitLease({ ev = "action", id = "main", act = "sync-wait", value = "off:" .. rid }) end
        local none = { ok = true, state = "none" }
        selection.applyLease(view, on("aaa"), now); selection.applyLease(view, on("bbb"), now)
        now += 2000
        selection.applyLease(view, on("aaa"), now) -- A renews
        selection.applyLease(view, off("bbb"), now) -- B revokes
        assert(selection.patience(view, now))
        assert(selection.discoveryStep(0, true, none, selection.patience(view, now), true).action == "wait")
        now += 6000
        selection.applyLease(view, on("aaa"), now)
        assert(selection.patience(view, now))
        selection.applyLease(view, off("aaa"), now)
        assert(not selection.patience(view, now))
        assert(selection.discoveryStep(0, true, none, selection.patience(view, now), view.hadWait).action == "dormant")
        assert(selection.applyLease(view, on("bbb"), now), "a renewal after dormancy changes patience")
        assert(selection.patience(view, now))
        assert(selection.waitLease({ ev = "action", id = "main", act = "sync-wait", value = "on:bad id!" }) == nil)
        assert(selection.waitLease({ ev = "action", id = "main", act = "sync-wait", value = "on" }).rid == "legacy")
    end},
    {"the lease map is bounded; the oldest lease is dropped first", function()
        local view = {}
        for i = 1, 20 do selection.applyLease(view, { on = true, rid = "r" .. i }, 1000 + i) end
        local n = 0
        for _ in view.leases do n += 1 end
        assert(selection.MAX_LEASES == 16 and n == 16, n)
        assert(view.leases.r1 == nil and view.leases.r4 == nil and view.leases.r5 ~= nil and view.leases.r20 ~= nil)
        local saved = selection.saveState({ discover_pid = 9, discover_birth = "b", leases = view.leases })
        assert(#saved.leases == 16)
    end},
    {"a restored waiting view restores its leases fresh and stays patient, then lapses to dormant", function()
        local valid = function() return false end
        local saved = selection.saveState({ discover_pid = 4242, discover_birth = "linux:boot:111", discovery_label = "L", leases = { aaa = 1, bbb = 2 } })
        local r = selection.restoreState(saved, valid, 50000)
        assert(r.hadWait == true and r.leases.aaa == 50000 and r.leases.bbb == 50000)
        assert(selection.patience(r, 50000 + 15000) and not selection.patience(r, 50000 + 15001))
        local none = selection.restoreState({ schema = 2, discover_pid = 4242, birth = "b" }, valid, 7000)
        assert(selection.patience(none, 7000) and none.hadWait == true, "a save with no leases restarts one anonymous lease")
        local bad = selection.restoreState({ schema = 2, discover_pid = 4242, birth = "b", leases = { "ok-1", "bad id", 5 } }, valid, 1)
        assert(bad.leases["ok-1"] == 1 and bad.leases["bad id"] == nil)
    end},
    -- Dormant polling and wake: a host view driven through the same selection functions host.luau calls.
    {"a dormant view schedules a slow poll (30 s), never none, and a fresh lease returns it to the 5 s poll", function()
        local view = { panel = 5, hadWait = true, discover_pid = 9, leases = {} }
        local none = { ok = true, state = "none" }
        local timers = {}
        local timer = function(ms, fn) table.insert(timers, { ms = ms, fn = fn }) end
        local outcome = selection.discoveryStep(0, true, none, selection.patience(view, 1000), view.hadWait)
        local delay = selection.settle(view, outcome)
        selection.schedule(view, timer, delay :: number, function() end)
        assert(selection.DORMANT_POLL_MS == 30000 and view.dormant == true and timers[1].ms == 30000, tostring(timers[1] and timers[1].ms))
        selection.applyLease(view, { on = true, rid = "w1" }, 2000)
        outcome = selection.discoveryStep(0, true, none, selection.patience(view, 2000), view.hadWait)
        assert(selection.settle(view, outcome) == selection.WAIT_MS and view.dormant == false)
    end},
    {"a nonterminal error keeps a dormant view on its slow poll until a fresh lease; other views are unchanged", function()
        local view = { panel = 5, dormant = true, hadWait = true, leases = {} }
        assert(selection.retryDelay(view, 1500, 1000) == selection.DORMANT_POLL_MS, "dormant + error stays slow")
        assert(selection.retryDelay({ panel = 6, leases = {} }, 1500, 1000) == 1500, "non-dormant unchanged")
        assert(selection.retryDelay({ panel = 6, leases = {} }, 15000, 1000) == 15000, "non-dormant ssh unchanged")
        selection.applyLease(view, { on = true, rid = "w1" }, 2000)
        assert(selection.retryDelay(view, 1500, 2000) == 1500, "fresh lease: fast")
    end},
    {"a dormant view picks up a plan published later on its slow tick (Sync Off, hadWait true)", function()
        local view = { panel = 5, hadWait = true, discover_pid = 9, leases = { w1 = 1000 } }
        local none = { ok = true, state = "none" }
        local published = { ok = true, state = "active", source = { path = "/p.md", plan_id = "plan-abc", publication = { k = 1 } } }
        local now, ticks, refreshed = 1000, {}, 0
        local timer = function(_ms, fn) table.insert(ticks, fn) end
        local function tick(envelope)
            refreshed += 1
            now += selection.DORMANT_POLL_MS
            local outcome = selection.discoveryStep(0, true, envelope, selection.patience(view, now), view.hadWait)
            local delay = selection.settle(view, outcome)
            if delay then selection.schedule(view, timer, delay, function() end) end
            return outcome
        end
        assert(tick(none).action == "dormant" and view.dormant)
        assert(tick(none).action == "dormant", "Sync Off: nothing renews, the view stays dormant and keeps polling")
        assert(#ticks == 2)
        assert(tick(published).action == "active", "the slow tick found the plan with no user action")
    end},
    {"a slow tick drops the instance of a closed dormant pane and withdraws its publication", function()
        local view = { panel = 5, dormant = true, hadWait = true, discover_pid = 9 }
        local instances, withdrawn = { [5] = view }, 0
        local publish = function(_state, plan) if plan == nil then withdrawn += 1 end end
        assert(selection.live(view, instances, { { pane = 5, program = "todo.list" } }, "todo.list", publish) == true)
        assert(instances[5] == view)
        assert(selection.live(view, instances, { { pane = 6, program = "todo.list" } }, "todo.list", publish) == false)
        assert(instances[5] == nil and withdrawn == 1, "the closed pane's entry leaked")
    end},
    {"a dormant view whose process ended is ended by the slow tick (terminal helper answer)", function()
        local ended = { ok = false, terminal = true, error = "The selected process ended." }
        local outcome = selection.discoveryStep(1, true, ended, false, true)
        assert(outcome.action == "terminal", tostring(outcome.action))
        assert(selection.settle({ hadWait = true }, outcome) == nil, "a terminal answer schedules no more polls")
    end},
    {"re-selecting the same session wakes a dormant view for an immediate refresh; only the window's event does", function()
        local view = { panel = 5, dormant = true, hadWait = true, discover_pid = 9 }
        assert(selection.wakeEvent({ ev = "action", id = "main", act = "sync-wake", value = "" }))
        assert(not selection.wakeEvent({ ev = "action", id = "main", act = "sync-wait", value = "on" }))
        assert(not selection.wakeEvent({ ev = "key", id = "main", act = "sync-wake" }))
        local timers = {}
        local timer = function(ms, fn) table.insert(timers, { ms = ms, fn = fn }) end
        selection.schedule(view, timer, selection.DORMANT_POLL_MS, function() error("the old slow tick must not run after a wake") end)
        assert(selection.wake(view) and view.dormant == false)
        local ran = 0
        selection.schedule(view, timer, 1, function() ran += 1 end)
        assert(timers[2].ms == 1)
        timers[1].fn(); timers[2].fn()
        assert(ran == 1, "the superseded slow timer still fired or the wake never refreshed")
        assert(not selection.wake({ source = { path = "/p" } }), "a view that serves a source has nothing to discover")
    end},
}
