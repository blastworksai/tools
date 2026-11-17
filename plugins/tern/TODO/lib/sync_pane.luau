--!strict
-- What the settings pane shows about the synced board, bound to the session it was synced for. MIT.
-- Several windows share one attachment (plugin KV) but each keeps its own memory of its last sync, so a board
-- is shown only while the attachment this window reads now is still the one that board belongs to.
local settings = require("./settings")
local sync_pane = {}

export type Board = { attach: number, title: string, path: string }

function sync_pane.new()
    local board: Board? = nil
    local self = {}
    function self.record(attach: number, title: string, path: string) board = { attach = attach, title = title, path = path } end
    function self.forget() board = nil end
    -- The board to show for these settings, or nil: sync off, nothing attached, or another session attached.
    function self.boardFor(s: any): Board?
        if settings.mode(s) ~= "glitch-sync" or board == nil or s.attach ~= board.attach then return nil end
        return board
    end
    -- Called with what the window sees now; a closed attachment forgets the board.
    function self.observe(s: any, target: any)
        if board ~= nil and (s.attach ~= board.attach or target == nil) then board = nil end
    end
    function self.extra(s: any, candidates: { any }): any
        return { hidden = settings.hiddenCount(s, candidates), board = self.boardFor(s) }
    end
    return self
end
return sync_pane
