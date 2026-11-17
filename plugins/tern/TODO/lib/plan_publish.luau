--!strict
-- The last plan a TODO panel validated, as the text of ONE hidden node in the panel's own view (key `plan-sync`).
-- The window reads that node through the pane surface (lib/plan_read), so it works wherever the session runs: plugin
-- KV is per machine, a pane surface is not. A failed read, a closed panel or a fresh start removes the plan, so a
-- window never syncs a stale success.
-- The text is JSON {v, rev, wait, plan?, too_large?}. `rev` changes whenever the plan changes (the window's
-- "already synced" gate compares it); `wait` echoes the host's wait-for-publication flag, which the window sets by event.
-- A plan whose JSON passes LIMIT is never cut: the node carries `too_large` instead. Blastworks.ai; MIT.
local publication = {}

publication.KEY = "plan-sync"
publication.ROLE = "todo.plan"
publication.LIMIT = 60000 -- bytes of node text; the surface read is capped at 64000 characters

export type Publisher = {
    publish: (plan: any?) -> (),
    clear: () -> (),
    payload: (wait: boolean) -> string,
}

function publication.new(encode: (value: any) -> string, now: () -> number): Publisher
    local encoded: string? = nil
    local rev = 0
    local self = {} :: Publisher
    local function bump() rev = math.max(rev + 1, math.floor(now())) end
    function self.publish(plan: any?)
        local text = if plan then encode(plan) else nil
        if text == encoded then return end
        encoded = text
        bump()
    end
    -- A fresh start publishes nothing, whatever an earlier instance of this panel showed.
    function self.clear()
        encoded = nil
        bump()
    end
    function self.payload(wait: boolean): string
        local head = '{"v":1,"rev":' .. string.format("%.0f", rev) .. ',"wait":' .. (if wait then "true" else "false")
        if encoded == nil then return head .. "}" end
        local text = head .. ',"plan":' .. encoded .. "}"
        if #text > publication.LIMIT then return head .. ',"too_large":true}' end
        return text
    end
    return self
end

return publication
