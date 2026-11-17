--!strict
-- What the settings pane shows about the synced board, and when a sync tick may skip, bound to ONE key: the
-- attachment this window reads now. MIT.
-- Several windows share one attachment (plugin KV) but each keeps its own memory of its last sync. Three pieces of
-- window state follow that attachment: the board memo, the revision gate (lib/sync_gate) and the repaint of the
-- open pane (lib/sync_status). They are kept in step here, in one place, so none can outlive the attachment it
-- belongs to:
--   * the displayed board is derived on every paint from (current attachment, memo keyed by attachment);
--   * `start` runs at the head of every tick, before any early return: it notices an attachment change, the target
--     closing or sync turned off (also by another window) and, in one step, forgets the board, resets the revision
--     gate and clears the status; the pane repaints whenever what is DRAWN differs from what was last drawn
--     (lib/sync_status), not when the status text alone changes;
--   * `decide` is the whole tick decision (blocked / skip / run); a tick that is blocked also resets the gate,
--     because a status that is not "synced" means the next unblocked tick must repeat the pass to restore it.
local settings = require("./settings")
local plan_view = require("./plan_view")
local sync_pane = {}

export type Board = { attach: number, title: string, path: string }
export type Gate = { reset: () -> (), matches: (string, number, number?) -> boolean, passed: (string, number, number, number, number) -> boolean }
export type Env = { gate: Gate, repaint: () -> (), clear: () -> () }

local UNSET = {}
-- A plan view whose node cannot be read this many ticks in a row (about 6 s) is reported as unreadable. A view that
-- was only just opened has no node for a moment; saying "works only on this machine" then would be untrue.
sync_pane.UNREADABLE_TICKS = 3

function sync_pane.new(env: Env)
    local board: Board? = nil
    local seen: any = UNSET -- what the memory above was last checked against: the attachment, false (none / closed) or "off"
    local streak = 0
    local self = {}
    function self.record(attach: number, title: string, path: string) board = { attach = attach, title = title, path = path } end
    function self.forget() board = nil end
    -- The board to show for these settings, or nil: sync off, nothing attached, or another session attached.
    function self.boardFor(s: any): Board?
        if settings.mode(s) ~= "glitch-sync" or board == nil or s.attach ~= board.attach then return nil end
        return board
    end
    -- Called every tick with what the window sees now (target = the attached candidate, or nil when it closed).
    -- Sync turned off counts as a change too: another window can do that. Returns true when the key moved.
    function self.observe(s: any, target: any): boolean
        local key: any = if settings.mode(s) ~= "glitch-sync" then "off" elseif target ~= nil and s.attach ~= nil then s.attach else false
        if seen == key then return false end
        local first = seen == UNSET
        seen = key
        streak = 0
        if board ~= nil and (board :: Board).attach ~= key then board = nil end
        if not first then env.gate.reset() end
        return not first
    end
    -- The head of EVERY tick, before any early return (a busy pass, sync off): notice what moved, drop what no
    -- longer holds and ask for one repaint when what is drawn differs. Returns whether sync is on.
    function self.start(s: any, target: any): boolean
        local on = settings.mode(s) == "glitch-sync"
        local moved = self.observe(s, target)
        if moved or not on then env.clear() end
        env.repaint()
        return on
    end
    -- One tick's decision after `start`. Returns "blocked", text | "skip" | "run", key.
    -- read: what this window read of the matching view (lib/plan_read; nil without a view); retrying: a failed pass is cooling down.
    function self.decide(s: any, target: any, view: string, panel: number?, read: any, nowMs: number, retrying: boolean): (string, string?)
        local kind = if type(read) == "table" then read.kind else "waiting"
        if view == "match" and kind == "unreadable" then streak += 1 else streak = 0 end
        local entry = if kind == "entry" then read.entry else nil
        local entryOk = type(entry) == "table" and type(entry.rev) == "number" and plan_view.validate(entry.plan) == nil
        local why = if kind == "too_large" then "too_large" elseif kind == "unreadable" and streak >= sync_pane.UNREADABLE_TICKS then "unreadable" else nil
        local blocker = settings.syncBlocker(s, target, view, entryOk, why)
        if blocker then env.gate.reset(); return "blocked", blocker end
        local key = string.format("%.0f", panel :: number) .. ":" .. entry.plan.plan_id
        if env.gate.matches(key, entry.rev, nowMs) or retrying then return "skip", nil end
        return "run", key
    end
    -- A pass for `key` at `rev` succeeded with `count` board changes: remember it and the board for its session.
    function self.succeeded(attach: number, key: string, rev: number, gen: number, count: number, nowMs: number, title: string, path: string)
        env.gate.passed(key, rev, gen, count, nowMs)
        self.record(attach, title, path)
        env.repaint()
    end
    -- Everything the settings pane draws that this memory decides: mode, attachment, board name and link. The pane is
    -- repainted when this (or the status text) differs from what was last drawn.
    function self.renderKey(s: any): string
        local shown = self.boardFor(s)
        return settings.mode(s) .. "|" .. tostring(s.attach) .. "|" .. (if shown then shown.title .. "|" .. shown.path else "-")
    end
    function self.extra(s: any, candidates: { any }): any
        return { hidden = settings.hiddenCount(s, candidates), board = self.boardFor(s) }
    end
    return self
end
return sync_pane
