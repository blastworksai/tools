-- The window's read of a plan view through the pane surface: one path for a local and a remote session. Blastworks.ai; MIT.
local read = require("../lib/plan_read")
local publication = require("../lib/plan_publish")
local sync_pane = require("../lib/sync_pane")
local sync_gate = require("../lib/sync_gate")
local settings = require("../lib/settings")
local BLOCK = "todo.list"
local function planOf(id)
    return { schema = 2, plan_id = id, title = id, current = "impl", checkpoints = {
        { id = "ui", text = "UI", state = "active", tasks = { { id = "impl", text = "Implement", state = "active", items = {
            { id = "impl-step", kind = "step", text = "Do it", state = "pending" } } } } } } }
end
-- The tree a pane returns for `main.plan-sync`, shaped like the TSP wire form ORCH+ reads.
local function tree(text, role)
    return { surface = { id = "s", role = "plugin." .. BLOCK, mode = "block" },
        main = { id = "main", k = "col", c = { { id = "main.plan-sync", k = "text", p = { role = role or "todo.plan", hidden = true, spans = { text } } } } } }
end
-- A window context whose session holds `panes[panel] = { block, tree }`; `reads` counts surface calls.
local function fakeCx(panes)
    local f = { reads = 0, last = nil }
    f.session = {}
    function f.session:pane(panel) local p = panes[panel]; return p and { pane = panel, block = p.block } end
    function f.session:surface(panel, opts)
        f.reads += 1; f.last = opts
        local p = panes[panel]
        if p.fail then error("surface unavailable") end
        return p.tree
    end
    return f
end
local function payload(plan, wait)
    local p = publication.new(tern.json.encode, function() return 7 end)
    if plan then p.publish(plan) end
    return p.payload(wait)
end
local decode = function(text: string): any return tern.json.decode(text) end
return {
    {"a session on another machine is read through the pane surface, never through plugin KV", function()
        local cx = fakeCx({ [5] = { block = BLOCK, tree = tree(payload(planOf("plan-0123456789ab"), true)) } })
        local r = read.plan(cx, 5, BLOCK, decode)
        assert(r.kind == "entry" and r.entry.plan.plan_id == "plan-0123456789ab" and r.entry.rev == 7 and r.wait == true, r.kind)
        assert(cx.last.root == "main.plan-sync" and cx.last.max_chars == 64000)
    end},
    {"a view with no plan reads as waiting, and the wait flag comes back", function()
        local r = read.plan(fakeCx({ [5] = { block = BLOCK, tree = tree(payload(nil, false)) } }), 5, BLOCK, decode)
        assert(r.kind == "waiting" and r.wait == false and r.entry == nil)
    end},
    {"a plan over the cap reads as too_large, not as a cut document", function()
        local huge = planOf("plan-0123456789ab"); huge.title = string.rep("x", publication.LIMIT)
        local r = read.plan(fakeCx({ [5] = { block = BLOCK, tree = tree(payload(huge, false)) } }), 5, BLOCK, decode)
        assert(r.kind == "too_large")
        -- text the host never could have written (over the cap, or cut mid-document) is unreadable
        assert(read.plan(fakeCx({ [5] = { block = BLOCK, tree = tree(string.rep("x", publication.LIMIT + 1)) } }), 5, BLOCK, decode).kind == "unreadable")
        local whole = payload(planOf("plan-0123456789ab"), false)
        assert(read.parse(whole:sub(1, #whole - 9), decode).kind == "unreadable")
    end},
    {"every failed read is unreadable", function()
        local good = payload(planOf("plan-0123456789ab"), false)
        local cases = {
            { "surface raises", { block = BLOCK, fail = true } },
            { "pane of another block", { block = "other.list", tree = tree(good) } },
            { "wrong role", { block = BLOCK, tree = tree(good, "orchplus.x") } },
            { "no surface", { block = BLOCK, tree = nil } },
            { "omitted nodes", { block = BLOCK, tree = (function() local t = tree(good); t.more = 3; return t end)() } },
            { "not JSON", { block = BLOCK, tree = tree("hello") } },
            { "invalid plan", { block = BLOCK, tree = tree(payload({ schema = 2, plan_id = "x", title = "T", checkpoints = {} }, false)) } },
        }
        for _, case in cases do
            local r = read.plan(fakeCx({ [5] = case[2] }), 5, BLOCK, decode)
            assert(r.kind == "unreadable", case[1] .. " -> " .. r.kind)
        end
        assert(read.plan(fakeCx({}), 9, BLOCK, decode).kind == "unreadable", "a closed pane")
    end},
    {"the fallback wording appears for a remote session only after the node stayed unreadable, and never for a local one", function()
        local kv = {}
        kv["settings.glitch"] = true; kv["settings.sync"] = true; kv["settings.attach"] = 2
        local s = settings.load({ get = function(k) return kv[k] end, set = function(k, v) kv[k] = v end })
        local memo = sync_pane.new({ gate = sync_gate.new(), repaint = function() end, clear = function() end })
        local remote, localCand = { pane = 2, remote = true, live = true }, { pane = 2, remote = false, live = true }
        local gone = { kind = "unreadable" }
        for tick = 1, 2 do
            local verdict, text = memo.decide(s, remote, "match", 11, gone, tick * 1000, false)
            assert(verdict == "blocked" and text:find("/glitch-execute", 1, true), "a view just opened has no node for a moment: " .. tostring(text))
        end
        local verdict, text = memo.decide(s, remote, "match", 11, gone, 9000, false) -- the third unreadable tick in a row
        assert(verdict == "blocked" and text == "Board sync for this session works only when the session runs on this window's machine.", text)
        -- a readable answer ends the streak at once
        assert(select(2, memo.decide(s, remote, "match", 11, { kind = "waiting" }, 9100, false)):find("/glitch-execute", 1, true))
        local local1 = sync_pane.new({ gate = sync_gate.new(), repaint = function() end, clear = function() end })
        for tick = 1, 6 do
            local _, t = local1.decide(s, localCand, "match", 11, gone, tick * 1000, false)
            assert(t:find("/glitch-execute", 1, true), "a local session never gets the remote limit: " .. tostring(t))
        end
        local _, big = memo.decide(s, remote, "match", 11, { kind = "too_large" }, 9200, false)
        assert(big == settings.REMOTE_TOO_LARGE and big:find("works only when the session runs on this window's machine", 1, true), big)
        local _, bigLocal = memo.decide(s, localCand, "match", 11, { kind = "too_large" }, 9200, false)
        assert(bigLocal == settings.TOO_LARGE)
    end},
    {"a readable remote plan runs a sync pass exactly like a local one", function()
        local kv = {}
        kv["settings.glitch"] = true; kv["settings.sync"] = true; kv["settings.attach"] = 2
        local s = settings.load({ get = function(k) return kv[k] end, set = function(k, v) kv[k] = v end })
        local memo = sync_pane.new({ gate = sync_gate.new(), repaint = function() end, clear = function() end })
        local cx = fakeCx({ [11] = { block = BLOCK, tree = tree(payload(planOf("plan-0123456789ab"), true)) } })
        local verdict, key = memo.decide(s, { pane = 2, remote = true, live = true }, "match", 11, read.plan(cx, 11, BLOCK, decode), 1000, false)
        assert(verdict == "run" and key == "11:plan-0123456789ab", tostring(verdict))
    end},
}
