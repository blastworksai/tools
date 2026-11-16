--!strict
-- The last plan a TODO panel validated, kept in plugin KV for the window half (board sync).
-- A failed read, a closed panel or a fresh start removes it, so a window never syncs a stale success.
-- CodexBWAI; MIT.
local publication = {}

export type Kv = { get: (key: string) -> any, set: (key: string, value: any) -> () }
export type Publisher = {
    publish: (plan: any?) -> (),
    clear: () -> (),
}

function publication.key(panel: number): string return "plan/" .. string.format("%.0f", panel) end

function publication.new(kv: Kv, encode: (value: any) -> string, now: () -> number, panel: number): Publisher
    local key = publication.key(panel)
    local published: string? = nil
    local self = {} :: Publisher
    function self.publish(plan: any?)
        local encoded = if plan then encode(plan) else nil
        if encoded ~= nil and encoded == published then return end
        if encoded == nil and published == nil then return end
        published = encoded
        pcall(function() kv.set(key, if plan then { plan = plan, rev = now() } else nil) end)
    end
    -- Deletes whatever an earlier instance of this panel left behind. Run at start: after a plugin
    -- reload `published` is nil, so publish(nil) alone would leave the old entry in place.
    function self.clear()
        published = nil
        pcall(function() kv.set(key, nil) end)
    end
    return self
end

return publication
