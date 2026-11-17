--!strict
-- Which plan views this window has asked to keep waiting for a plan, so it can always take the request back. MIT.
-- A view's host may be on another machine, so the request is an event (`sync-wait` on / off), never a plugin-store
-- value. `sync(want)` is called every tick: it revokes (off) every view asked earlier that is not `want` now (the
-- attachment moved, sync turned Off, the attachment closed) and renews (on) the one that is. The renewal is also the
-- host's lease (lib/host_selection PATIENCE_MS): a window that stops renewing, closed or crashed, ends the wait there.
local wait_requests = {}

function wait_requests.new(send: (number, boolean) -> ())
    local asked: { [number]: boolean } = {}
    local self = {}
    function self.sync(want: number?)
        for panel in asked do
            if panel ~= want then asked[panel] = nil; send(panel, false) end
        end
        if want ~= nil then asked[want] = true; send(want, true) end
    end
    function self.revokeAll() self.sync(nil) end
    function self.asked(): { number }
        local out = {}
        for panel in asked do table.insert(out, panel) end
        table.sort(out)
        return out
    end
    return self
end

return wait_requests
