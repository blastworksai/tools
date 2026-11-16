-- Plan publication to plugin KV: stale success never survives a reload. CodexBWAI; MIT.
local publication = require("../lib/plan_publish")
local function kvStore()
    local store, sets = {}, 0
    return { store = store, sets = function() return sets end,
        get = function(k) return store[k] end,
        set = function(k, v) sets += 1; store[k] = v end }
end
local function new(kv, panel)
    return publication.new(kv, tern.json.encode, function() return 42 end, panel)
end
local plan = { schema = 2, plan_id = "plan-0123456789ab", title = "T", checkpoints = {} }
return {
    {"publish stores the plan and revision; an unchanged plan is not written twice", function()
        local kv = kvStore(); local p = new(kv, 7)
        p.publish(plan); p.publish(plan)
        assert(kv.store["plan/7"].plan == plan and kv.store["plan/7"].rev == 42 and kv.sets() == 1)
    end},
    {"a failed read after a reload removes the plan the previous instance published", function()
        local kv = kvStore()
        new(kv, 7).publish(plan)
        assert(kv.store["plan/7"] ~= nil)
        -- Plugin reload: a new instance of the same panel starts with nothing published.
        local reloaded = new(kv, 7)
        reloaded.clear()
        reloaded.publish(nil)
        assert(kv.store["plan/7"] == nil, "stale plan survived the reload")
    end},
    {"publish(nil) after a success deletes it, and repeated nil writes nothing more", function()
        local kv = kvStore(); local p = new(kv, 3)
        p.publish(plan); p.publish(nil)
        assert(kv.store["plan/3"] == nil)
        local before = kv.sets(); p.publish(nil); p.publish(nil)
        assert(kv.sets() == before)
    end},
    {"a throwing store is tolerated", function()
        local bad = { get = function() end, set = function() error("io") end }
        local p = new(bad, 1); p.publish(plan); p.clear(); p.publish(nil)
    end},
}
