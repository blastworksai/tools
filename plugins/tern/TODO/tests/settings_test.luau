-- Settings model: defaults, closed validation, eligibility and transitions; no Files button.
local settings = require("../lib/settings")
local function cand(pane, remote, live) return { pane = pane, label = "p" .. pane, remote = remote, live = live ~= false } end
local cands = { cand(1, false), cand(2, true), cand(3, false, false) }
local function nodes(ui) return ui end
local ui = {
    el = function(tag, props) return { tag = tag, props = props } end,
    row = function(c) return { row = c } end, col = function(c) return { col = c } end,
    text = function(spans) return { text = spans } end, span = function(t) return t end, rule = function() return { rule = true } end,
}
local function flatten(node, out)
    out = out or {}
    if type(node) ~= "table" then table.insert(out, tostring(node)); return out end
    if node.props and node.props.text then table.insert(out, node.props.text); if node.props.actions then table.insert(out, "ACT:" .. node.props.actions.click) end end
    for _, key in { "col", "row", "text" } do for _, child in node[key] or {} do flatten(child, out) end end
    return out
end
local function joined(node) return table.concat(flatten(node), "\n") end

return {
    {"fresh install defaults: Glitch off, board on, sync off, nothing attached", function()
        local s = settings.normalize(nil)
        assert(s.glitch == false and s.board == true and s.sync == false and s.attach == nil)
        assert(settings.mode(s) == "native-board")
    end},
    {"closed validation drops unknown keys and falls back on wrong types", function()
        local s = settings.normalize({ glitch = "yes", board = false, sync = 1, attach = -4, extra = true })
        assert(s.glitch == false and s.board == false and s.sync == false and s.attach == nil and s.extra == nil)
        assert(settings.normalize({ attach = 2.5 }).attach == nil and settings.normalize({ attach = 7 }).attach == 7)
        assert(settings.normalize("junk").board == true)
    end},
    {"load/save round-trips through kv and survives a throwing store", function()
        local store = {}
        local kv = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
        assert(settings.save(kv, { glitch = true, sync = true, attach = 1 }))
        local s = settings.load(kv); assert(s.glitch and s.sync and s.attach == 1)
        local bad = { get = function() error("io") end, set = function() error("io") end }
        assert(settings.load(bad).board == true and settings.save(bad, s) == false)
    end},
    {"modes: none, native-board, glitch, glitch-sync", function()
        assert(settings.mode({ glitch = false, board = false }) == "none")
        assert(settings.mode({ glitch = true, sync = false }) == "glitch" and settings.mode({ glitch = true, sync = true }) == "glitch-sync")
    end},
    {"attach list never offers stale/closed panes, and excludes remote panes for board modes", function()
        local native = settings.eligible({ glitch = false, board = true }, cands)
        assert(#native == 1 and native[1].pane == 1)
        local glitchOff = settings.eligible({ glitch = true, sync = false }, cands)
        assert(#glitchOff == 2, "remote panes stay eligible for plain Glitch viewing")
        local synced = settings.eligible({ glitch = true, sync = true }, cands)
        assert(#synced == 1 and synced[1].pane == 1)
        assert(#settings.eligible({ glitch = false, board = false }, cands) == 0)
    end},
    {"a transition drops an attach the new mode makes ineligible, immediately", function()
        local s = { glitch = true, sync = false, board = true, attach = 2 }
        assert(settings.isEligible(s, cands, 2))
        local after = settings.apply(s, "sync", "on", cands)
        assert(after.sync == true and after.attach == nil)
        assert(settings.apply({ glitch = false, board = true }, "attach", "2", cands).attach == nil)
        assert(settings.apply({ glitch = false, board = true }, "attach", "1", cands).attach == 1)
        assert(settings.apply({ glitch = false, board = true, attach = 1 }, "attach", "3", cands).attach == nil)
    end},
    {"toggles change only their own field", function()
        local s = settings.normalize({ attach = 1 })
        local g = settings.apply(s, "glitch", "on", cands)
        assert(g.glitch and g.board == true and g.sync == false and g.attach == 1)
        local b = settings.apply(s, "board", "off", cands)
        assert(b.board == false and b.glitch == false)
    end},
    {"the pane shows the agreed fields and texts for each mode", function()
        local off = joined(settings.draw(ui, settings.normalize({ board = false }), {}, nil))
        assert(off:find(settings.EMPTY, 1, true) and off:find("Attach to", 1, true) and off:find("Do you use Glitch?", 1, true))
        local native = joined(settings.draw(ui, settings.normalize(nil), settings.eligible(settings.normalize(nil), cands), nil))
        assert(native:find("Board", 1, true) and not native:find(settings.EMPTY, 1, true) and not native:find("Sync Glitch Plan", 1, true))
        local glitch = joined(settings.draw(ui, settings.normalize({ glitch = true }), cands, "Board synced"))
        assert(glitch:find("/glitch-plan progress will be shown in the TODO pane.", 1, true))
        assert(glitch:find("Sync Glitch Plan to Tern Board?", 1, true) and glitch:find("ACT:sync=on", 1, true) and glitch:find("Board synced", 1, true))
        assert(glitch:find("ACT:attach=1", 1, true))
    end},
    {"two windows changing different fields keep both changes, from stale snapshots", function()
        local store = {}
        local kv = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
        settings.save(kv, { glitch = true, sync = true, board = true, attach = 1 })
        -- Both windows loaded the same settings; one turns sync off, the other changes the attach.
        local base = settings.load(kv)
        local first = settings.apply(base, "sync", "off", cands)
        local second = settings.apply(base, "attach", "5", { cand(1, false), cand(5, false) })
        settings.save(kv, first, base)
        settings.save(kv, second, base)
        local s = settings.load(kv)
        assert(s.glitch == true and s.sync == false and s.attach == 5, tostring(s.sync) .. "/" .. tostring(s.attach))
    end},
    {"a cleared attach stays cleared and a legacy whole-object value is still read", function()
        local store = { settings = { schema = 1, glitch = true, board = true, sync = true, attach = 4 } }
        local kv = { get = function(k) return store[k] end, set = function(k, v) store[k] = v end }
        local s = settings.load(kv)
        assert(s.glitch and s.sync and s.attach == 4)
        local cleared = settings.normalize(s); cleared.attach = nil
        settings.save(kv, cleared, s)
        local after = settings.load(kv)
        assert(after.attach == nil and after.sync == true and after.glitch == true)
    end},
}
