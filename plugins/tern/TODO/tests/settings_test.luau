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
        assert(#synced == 2, "sync must not change which sessions can be attached")
        assert(#settings.eligible({ glitch = true, sync = false }, cands) == #synced)
        assert(#settings.eligible({ glitch = false, board = false }, cands) == 0)
    end},
    {"a transition drops an attach the new mode makes ineligible, immediately", function()
        local s = { glitch = true, sync = false, board = true, attach = 2 }
        assert(settings.isEligible(s, cands, 2))
        local after = settings.apply(s, "sync", "on", cands)
        assert(after.sync == true and after.attach == 2)
        assert(settings.apply({ glitch = false, board = true }, "attach", "2", cands).attach == nil)
        local keep = settings.apply({ glitch = true, sync = false, board = true, attach = 2 }, "sync", "on", cands)
        assert(keep.sync == true and keep.attach == 2, "turning sync on keeps an attached remote session")
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
    {"the pane says plainly why Glitch Off offers no session, and labels both board settings alike", function()
        local s = settings.normalize(nil)
        local remoteOnly = { cand(2, true) }
        local text = joined(settings.draw(ui, s, settings.eligible(s, remoteOnly), nil, { hidden = settings.hiddenCount(s, remoteOnly) }))
        assert(text:find("on this computer", 1, true) and text:find("1 session", 1, true), text)
        assert(settings.hiddenCount({ glitch = true, sync = true }, remoteOnly) == 0)
        assert(text:find("Tern Board?", 1, true), "Glitch Off label names the Tern Board")
        local on = joined(settings.draw(ui, settings.normalize({ glitch = true, sync = true }), cands, nil))
        assert(on:find("Sync Glitch Plan to Tern Board?", 1, true) and not on:find("No eligible session", 1, true))
    end},
    {"a synced board is named in the pane with an Open board control", function()
        local s = settings.normalize({ glitch = true, sync = true, attach = 1 })
        local text = joined(settings.draw(ui, s, cands, "Board synced", { board = { title = "TODO · CSV import", path = "/d/boards/p.md" } }))
        assert(text:find("TODO · CSV import", 1, true) and text:find("ACT:openboard=go", 1, true), text)
        local none = joined(settings.draw(ui, s, cands, nil, nil))
        assert(not none:find("openboard", 1, true))
    end},
    {"sync never stays silent: each blocker names what is missing", function()
        local s = { glitch = true, sync = true, attach = nil }
        assert(settings.syncBlocker(s, nil, "none", false):find("Attach to", 1, true))
        s.attach = 1
        assert(settings.syncBlocker(s, nil, "none", false):find("no longer open", 1, true))
        local local1, remote2 = cand(1, false), cand(2, true)
        assert(settings.syncBlocker(s, local1, "none", false):find("plan view", 1, true))
        assert(settings.syncBlocker(s, local1, "match", false):find("/glitch-plan", 1, true))
        -- A remote session waits like a local one; only a view that cannot be read says the limit.
        assert(settings.syncBlocker(s, remote2, "match", false):find("/glitch-plan", 1, true))
        assert(settings.syncBlocker(s, remote2, "match", false, "unreadable") == settings.REMOTE_ONLY)
        assert(settings.syncBlocker(s, local1, "match", false, "unreadable"):find("/glitch-plan", 1, true), "a local session never gets the remote limit")
        assert(settings.syncBlocker(s, local1, "match", false, "too_large") == settings.TOO_LARGE)
        assert(settings.syncBlocker(s, remote2, "match", false, "too_large") == settings.REMOTE_TOO_LARGE)
        assert(settings.syncBlocker(s, local1, "match", true) == nil)
    end},
}
