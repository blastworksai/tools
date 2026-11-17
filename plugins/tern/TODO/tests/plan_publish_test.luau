-- The plan-sync node text: one JSON document, never a cut one. CodexBWAI; MIT.
local publication = require("../lib/plan_publish")
local clock = 40
local function new() return publication.new(tern.json.encode, function() clock += 1; return clock end) end
local plan = { schema = 2, plan_id = "plan-0123456789ab", title = "T", checkpoints = {} }
local function parsed(p, wait) return tern.json.decode(p.payload(wait)) end
return {
    {"a view with no plan says so and echoes the wait flag", function()
        local p = new()
        local v = parsed(p, false)
        assert(v.v == 1 and v.plan == nil and v.too_large == nil and v.wait == false and type(v.rev) == "number")
        assert(parsed(p, true).wait == true)
    end},
    {"publish carries the plan and a revision; an unchanged plan keeps its revision, a changed one moves it", function()
        local p = new()
        p.publish(plan)
        local first = parsed(p, false)
        assert(first.plan.plan_id == plan.plan_id and type(first.rev) == "number")
        p.publish(plan)
        assert(parsed(p, true).rev == first.rev, "an unchanged plan must not look new")
        p.publish({ schema = 2, plan_id = "plan-0123456789ab", title = "Changed", checkpoints = {} })
        assert(parsed(p, false).rev > first.rev)
    end},
    {"a failed read or a fresh start removes the plan, and the revision moves so the window sees the change", function()
        local p = new()
        p.publish(plan)
        local with = parsed(p, false)
        p.publish(nil)
        local without = parsed(p, false)
        assert(without.plan == nil and without.rev > with.rev)
        local reloaded = new()
        reloaded.clear()
        assert(parsed(reloaded, false).plan == nil)
    end},
    {"a plan over the cap is never sent cut: the node says too_large and is still valid JSON", function()
        local huge = { schema = 2, plan_id = "plan-0123456789ab", title = string.rep("x", publication.LIMIT), checkpoints = {} }
        local p = new()
        p.publish(huge)
        local text = p.payload(true)
        assert(#text < 200, #text)
        local v = tern.json.decode(text)
        assert(v.too_large == true and v.plan == nil and v.wait == true)
        p.publish(plan)
        assert(parsed(p, false).too_large == nil, "a smaller plan must be sent again")
    end},
    {"a plan right under the cap is sent whole", function()
        local p = new()
        local head = #'{"v":1,"rev":41,"wait":false,"plan":}'
        local base = #tern.json.encode({ schema = 2, plan_id = "plan-0123456789ab", title = "", checkpoints = {} })
        local fit = { schema = 2, plan_id = "plan-0123456789ab", title = string.rep("x", publication.LIMIT - head - base - 4), checkpoints = {} }
        p.publish(fit)
        local text = p.payload(false)
        assert(#text <= publication.LIMIT and tern.json.decode(text).plan ~= nil, #text)
    end},
}
