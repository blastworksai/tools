--!strict
-- What the settings pane shows about the synced board, and when a sync tick may skip, bound to ONE key: the
-- attachment this window reads now. MIT.
-- Several windows share one attachment (plugin KV) but each keeps its own memory of its last sync. Three pieces of
-- window state follow that attachment: the board memo, the revision gate (lib/sync_gate) and the repaint of the
-- open pane (lib/sync_status). They are kept in step here, in one place, so none can outlive the attachment it
-- belongs to:
--   * the displayed board is derived on every paint from (current attachment, memo keyed by attachment);
--   * `observe` notices an attachment change (or the target closing) and, in one step, forgets the board,
--     resets the revision gate and, when a board was on screen, asks for one repaint;
--   * `decide` is the whole tick decision (blocked / skip / run); a tick that is blocked also resets the gate,
--     because a status that is not "synced" means the next unblocked tick must repeat the pass to restore it.
local settings = require("./settings")
local plan_view = require("./plan_view")
local sync_pane = {}

export type Board = { attach: number, title: string, path: string }
export type Gate = { reset: () -> (), matches: (string, number, number?) -> boolean, passed: (string, number, number, number, number) -> boolean }
export type Env = { gate: Gate, repaint: () -> () }

local UNSET = {}

function sync_pane.new(env: Env)
    local board: Board? = nil
    local seen: any = UNSET -- the attachment (or false: none / closed) the memory above was last checked against
    local self = {}
    function self.record(attach: number, title: string, path: string) board = { attach = attach, title = title, path = path } end
    function self.forget() board = nil end
    -- The board to show for these settings, or nil: sync off, nothing attached, or another session attached.
    function self.boardFor(s: any): Board?
        if settings.mode(s) ~= "glitch-sync" or board == nil or s.attach ~= board.attach then return nil end
        return board
    end
    -- Called every tick with what the window sees now (target = the attached candidate, or nil when it closed).
    function self.observe(s: any, target: any)
        local key: any = if target ~= nil and s.attach ~= nil then s.attach else false
        if seen == key then return end
        local first = seen == UNSET
        seen = key
        local hadBoard = board ~= nil and (board :: Board).attach ~= key
        if hadBoard then board = nil end
        if not first then env.gate.reset() end
        if hadBoard then env.repaint() end
    end
    -- One tick's decision after `observe`. Returns "blocked", text | "skip" | "run", key.
    -- entry: the plan this window read for the matching view (or nil); retrying: a failed pass is still cooling down.
    function self.decide(s: any, target: any, view: string, panel: number?, entry: any, nowMs: number, retrying: boolean): (string, string?)
        local entryOk = type(entry) == "table" and type(entry.rev) == "number" and plan_view.validate(entry.plan) == nil
        local blocker = settings.syncBlocker(s, target, view, entryOk)
        if blocker then env.gate.reset(); return "blocked", blocker end
        local key = string.format("%.0f", panel :: number) .. ":" .. entry.plan.plan_id
        if env.gate.matches(key, entry.rev, nowMs) or retrying then return "skip", nil end
        return "run", key
    end
    -- A pass for `key` at `rev` succeeded with `count` board changes: remember it and the board for its session.
    function self.succeeded(attach: number, key: string, rev: number, gen: number, count: number, nowMs: number, title: string, path: string)
        env.gate.passed(key, rev, gen, count, nowMs)
        self.record(attach, title, path)
    end
    function self.extra(s: any, candidates: { any }): any
        return { hidden = settings.hiddenCount(s, candidates), board = self.boardFor(s) }
    end
    return self
end
return sync_pane
