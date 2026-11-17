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
        local waits = wait_requests.new(function(panel, on) view.patient = selection.waitRequest({ ev = "action", id = "main", act = "sync-wait", value = if on then "on" else "off" }); view.patientAt = now end)
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
        local hosts, now, discoveries = { [10] = { patient = false }, [20] = { patient = false } }, 1000, { [10] = 0, [20] = 0 }
        local waits = wait_requests.new(function(panel, on)
            local h = hosts[panel]; h.patient = selection.waitRequest({ ev = "action", id = "main", act = "sync-wait", value = if on then "on" else "off" }); h.patientAt = now
        end)
        local none = { ok = true, state = "none" }
        local function hostTick(panel)
            if selection.discoveryStep(0, true, none, selection.patience(hosts[panel], now)).action == "wait" then discoveries[panel] += 1 end
        end
        waits.sync(10) -- session A, sync On
        hostTick(10); assert(discoveries[10] == 1)
        waits.sync(20) -- another tab selects session B: the window now wants B's view only
        assert(hosts[10].patient == false and hosts[20].patient == true)
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
    {"a host whose window stops renewing drops patience after 15 s, so it never polls forever", function()
        local view = { patient = true, patientAt = 1000 }
        assert(selection.PATIENCE_MS == 15000)
        assert(selection.patience(view, 1000 + 15000))
        assert(not selection.patience(view, 1000 + 15001) and view.patient == false)
        local none = { ok = true, state = "none" }
        assert(selection.discoveryStep(0, true, none, selection.patience(view, 99999)).action == "none")
        local unstamped = { patient = true } -- a patient flag with no stamp is not trusted
        assert(not selection.patience(unstamped, 5))
        local renewed = { patient = true, patientAt = 1000 }
        renewed.patientAt = 14000 -- the window renewed
        assert(selection.patience(renewed, 20000))
    end},
}
