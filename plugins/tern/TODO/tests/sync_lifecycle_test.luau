-- The window and host lifecycles behind board sync, driven through the same libraries window.luau and host.luau call.
local settings = require("../lib/settings")
local sync_pane = require("../lib/sync_pane")
local selection = require("../lib/host_selection")
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
local function change(kv, act, value)
    local before = settings.load(kv)
    settings.save(kv, settings.apply(before, act, value, cands), before)
end

return {
    {"another window moving the shared attachment never leaves this window showing the old session's board", function()
        local kv = sharedKv()
        change(kv, "glitch", "on"); change(kv, "sync", "on"); change(kv, "attach", "1")
        local a = sync_pane.new()
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
        local a = sync_pane.new()
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
