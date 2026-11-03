-- Read-only SSH polling must not penalize other sessions on the same host.
-- CodexBWAI; MIT.
local polling = {}
function polling.delay(ssh, consecutiveFailures)
    if not ssh then return 1500 end
    if consecutiveFailures == 0 then return 15000 end
    return math.min(60000 * 2 ^ math.min(consecutiveFailures - 1, 3), 300000)
end
return polling
