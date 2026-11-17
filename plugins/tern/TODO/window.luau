-- English-first native connection detection, status entry, settings pane and optional board sync.
-- CodexBWAI; MIT.
local status_prompt = require("./status/status_prompt")
local settings = require("./lib/settings")
local board_sync = require("./lib/board_sync")
local plan_view = require("./lib/plan_view")
local board_claim = require("./lib/board_claim")
local sync_gate = require("./lib/sync_gate")
local sync_status = require("./lib/sync_status")
local sync_pane = require("./lib/sync_pane")
local wait_requests = require("./lib/wait_requests")
local plan_read = require("./lib/plan_read")
local KIND = tern.plugin.id .. ".list"
local TITLE = "TODO Settings"
local SYNC_MS, RETRY_MS = 2000, 10000

-- Every view this window asked to wait is tracked, so a move of the attachment, sync Off or a closed session revokes it.
-- This window's own requester id (random, once per load): a host keeps one lease per requester, so this window's revoke
-- never cancels another window's renewal. Tern gives an event no sender identity to use instead.
local requester = string.format("%x-%x", math.floor(tern.now()) % 0x7fffffff, math.random(1, 0x7fffffff))
local function sendWait(cx: any, panel: number, on: boolean)
    pcall(function() cx.session:event(panel, { ev = "action", id = "main", act = "sync-wait", value = (if on then "on:" else "off:") .. requester }) end)
end
local waitCx: any = nil
local waits = wait_requests.new(function(panel: number, on: boolean) if waitCx then sendWait(waitCx, panel, on) end end)

local controller = require("./lib/attach").new({
    plugin = { id = tern.plugin.id },
    now = function(): number return tern.now() end,
    timer = function(ms: number, callback: (WindowCx?) -> ()) return tern.timer(ms, callback) end,
    -- The window remembers which session each view serves; both halves of this binding live in this window's own store.
    bind = function(panel: number, target: number) pcall(tern.kv.set, "target/" .. string.format("%.0f", panel), target) end,
    -- The view's host may run on another machine: it is told by event, never through this machine's plugin store.
    configure = function(cx: WindowCx, panel: number, target: number)
        if settings.waitsForPublication(settings.load(tern.kv), target) then
            waitCx = cx; waits.sync(panel)
        end
    end,
    json = { encode = function(value: any): string return tern.json.encode(value) end },
})

-- Live agent/terminal panes on connected hosts, as the settings model wants them.
local function candidates(cx: any): { any }
    local hosts, out = {}, {}
    for _, host in cx.hosts:list() do
        if host.state == "connected" then for _, id in host.panes do hosts[id] = host end end
    end
    for _, pane in cx.session:panes() do
        local host = hosts[pane.pane]
        if host and pane.tab and not pane.parked and pane.exited == nil and (pane.kind == "agent" or pane.kind == "terminal") then
            table.insert(out, {
                pane = pane.pane, tab = pane.tab, cwd = pane.cwd, live = true, remote = host.kind == "remote",
                label = (if pane.title ~= "" and pane.title ~= nil then pane.title else pane.program or "Terminal") .. " · " .. string.format("%.0f", pane.pane),
                detail = (host.address or host.name) .. " · " .. (pane.program or "Terminal"),
            })
        end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    return out
end

-- The TODO view in the target's tab, and whether it serves the target ("match") or another
-- session of that tab ("other"). The attach controller records the target per panel.
local function viewPanel(cx: any, target: number): (string, number?)
    return controller.viewFor(cx, target, function(panel: number): number?
        local ok, value = pcall(tern.kv.get, "target/" .. string.format("%.0f", panel))
        return if ok and type(value) == "number" then value else nil
    end)
end

local syncStatus: any -- assigned below, once paint and settingsPane exist
local synced = sync_gate.new()
local failedAt = -RETRY_MS
local busy = false

local boardMemo: any -- assigned below, once syncStatus exists
local function drawExtra(s: any, cands: { any }): any return boardMemo.extra(s, cands) end
local function paint(cx: any, pane: number)
    local s = settings.load(tern.kv)
    local before = settings.load(tern.kv)
    local cands = candidates(cx)
    local eligible = settings.eligible(s, cands)
    if s.attach and not settings.isEligible(s, eligible, s.attach) then s.attach = nil; settings.save(tern.kv, s, before) end
    cx.canvas:set(pane, { view = settings.draw(tern.ui, s, eligible, syncStatus.get(), drawExtra(s, cands)) })
    syncStatus.drawn()
end
local function settingsPane(cx: any): number?
    for _, info in cx.canvas:list() do
        if info.owner == tern.plugin.id and info.title == TITLE then return info.pane end
    end
    return nil
end
syncStatus = sync_status.new({
    timer = function(ms: number, fn: (any?) -> ()) return tern.timer(ms, fn) end,
    pane = settingsPane,
    paint = paint,
    -- Everything the pane draws besides the status text: a repaint is due whenever this or the status changes.
    key = function(): string return boardMemo.renderKey(settings.load(tern.kv)) end,
})
-- The board this window last synced, shown only while its session is still attached; one key (the attachment)
-- keeps it, the revision gate and the repaint in step (lib/sync_pane).
boardMemo = sync_pane.new({ gate = synced, repaint = function() syncStatus.check() end, clear = function() syncStatus.set(nil) end })
local function openSettings(cx: any)
    local pane = settingsPane(cx)
    if pane then paint(cx, pane); cx.layout:focus(pane); return end
    local s = settings.load(tern.kv)
    local cands = candidates(cx)
    local opened, problem = cx.canvas:open({
        title = TITLE,
        view = settings.draw(tern.ui, s, settings.eligible(s, cands), syncStatus.get(), drawExtra(s, cands)),
        about = "TODO settings: which session to attach to, Glitch integration, the board and plan sync. A click changes TODO's own settings only; it never edits a plan.",
        focus = true,
    })
    if opened then syncStatus.drawn() else cx:toast("error", "Could not open TODO Settings.", problem) end
end

-- Native board: open or select Tern's ordinary board in the attached pane's folder.
local function openBoard(cx: any, pane: any)
    if not pane.cwd or pane.cwd == "" then cx:toast("info", "The attached session has no folder to hold a board."); return end
    local prefix = pane.cwd .. "/"
    cx.board:boards():next(function(list: any, _err: any, fresh: any)
        local live = fresh or cx
        for _, entry in list or {} do
            if entry.path:sub(1, #prefix) == prefix then live.board:open(entry.path); return end
        end
        live.board:open(prefix .. "TODO.md")
    end)
end

local function attached(cx: any, s: any): any
    for _, c in settings.eligible(s, candidates(cx)) do if c.pane == s.attach then return c end end
    return nil
end

-- Counts settings changes. A delayed replacement is stamped with the count at scheduling time and
-- dropped when a later change (another session, or the mode turned off) has superseded it.
local changeGen = 0

-- One settings change: revalidate against the panes as they are now, then act.
local function changed(cx: any, before: any, after: any, act: string)
    changeGen += 1
    local gen = changeGen
    local target = attached(cx, after)
    if act == "attach" and not target and after.attach == nil then
        cx:toast("error", "That session is no longer eligible. Pick another.")
        return
    end
    if not target then return end
    local mode = settings.mode(after)
    local view, panel = viewPanel(cx, target.pane)
    if (mode == "glitch" or mode == "glitch-sync") and view == "other" and panel then
        -- The tab's plan view belongs to another session. Replace it, never keep showing it.
        cx.layout:close(panel)
        tern.timer(300, function(fresh: WindowCx?)
            if not fresh or gen ~= changeGen then return end
            local now = settings.load(tern.kv)
            local m = settings.mode(now)
            if (m == "glitch" or m == "glitch-sync") and now.attach == target.pane then controller.start(fresh, false, target.pane) end
        end)
    elseif (mode == "glitch" or mode == "glitch-sync") and view == "none" then
        controller.start(cx, false, target.pane)
    elseif mode == "native-board" and (act == "attach" or act == "board" or act == "glitch") then
        openBoard(cx, target)
    end
end

tern.on("canvas_action", function(ev: any, cx: any): boolean?
    if ev.owner ~= tern.plugin.id or ev.title ~= TITLE then return nil end
    if ev.act == "openboard" then
        local shown = boardMemo.boardFor(settings.load(tern.kv))
        if shown then cx.board:open(shown.path) end
        return true
    end
    local before = settings.load(tern.kv)
    local after = settings.apply(before, ev.act, ev.value, candidates(cx))
    synced.settingsChanged(before, after)
    settings.save(tern.kv, after, before)
    if settings.mode(after) ~= "glitch-sync" or before.attach ~= after.attach then syncStatus.set(nil); boardMemo.forget() end
    paint(cx, ev.pane)
    changed(cx, before, after, ev.act)
    return true
end)

-- Glitch -> Tern board sync, one way. Reads the plan the TODO view validated, from the view's own hidden node
-- (lib/plan_read), so a session on another machine works like a local one; never reads or writes the canonical plan.
local function syncTick(cx: any)
    local s = settings.load(tern.kv)
    local target = attached(cx, s)
    -- Before any early return (sync turned off elsewhere, a pass still running): derive what is shown from the
    -- settings as they are now, and repaint when what is drawn differs.
    local on = boardMemo.start(s, target)
    local view, panel = "none", nil
    if target then view, panel = viewPanel(cx, target.pane) end
    local read: any = nil
    local want: number? = nil
    if panel and view ~= "none" then
        read = plan_read.plan(cx, panel, KIND, function(text: string): any return tern.json.decode(text) end)
        -- The view's host may be on another machine: it keeps waiting for a plan only while this window says so, every
        -- tick (a lease). Any view asked earlier that is not this one is revoked below.
        if on and view == "match" then want = panel end
    end
    waitCx = cx; waits.sync(want)
    if not on or busy then return end
    local entry: any = if read and read.kind == "entry" then read.entry else nil
    -- Never silent: say what is missing instead of leaving the pane as it was.
    local verdict, detail = boardMemo.decide(s, target, view, panel, read, tern.now(), tern.now() - failedAt < RETRY_MS)
    if verdict == "blocked" then syncStatus.set(detail); return end
    if verdict == "skip" then return end
    local key = detail :: string
    if #plan_view.entities(entry.plan) > board_sync.MAX_SYNC_ENTITIES then
        syncStatus.set(board_sync.TOO_BIG)
        return
    end
    local path = board_sync.boardPath(tern.plugin.data, entry.plan.plan_id)
    local title = board_sync.initialMarkdown(entry.plan):match("^# ([^\n]*)") or "TODO"
    local prepared = pcall(function()
        if not tern.fs.exists(path) then
            tern.fs.mkdir(tern.plugin.data .. "/boards")
            tern.fs.write(path, board_sync.initialMarkdown(entry.plan))
        end
    end)
    if not prepared then syncStatus.set("Could not create the TODO board file."); failedAt = tern.now(); return end
    busy = true
    local gen = synced.generation()
    local function stillOn(): boolean
        local now = settings.load(tern.kv)
        return settings.mode(now) == "glitch-sync" and now.attach == target.pane
    end
    local env = {
        kv = tern.kv, now = os.time, timer = function(ms: number, fn: (any?) -> ()) return tern.timer(ms, fn) end,
        token = function(): string return string.format("%.0f-%.0f", tern.now(), math.random(1, 2147483646)) end,
    }
    -- The board is written by one window at a time (lib/board_claim, granted by the host half).
    board_claim.acquire(env, cx, path, function(fresh: any, token: string, release: () -> ())
        local function owned(): boolean return stillOn() and board_claim.holds(env, path, token) end
        board_sync.apply(fresh, path, entry.plan, function(ok: boolean, problem: string?, count: number)
            release()
            busy = false
            if ok then
                boardMemo.succeeded(target.pane, key, entry.rev, gen, count, tern.now(), title, path)
                syncStatus.set("Board \"" .. title .. "\" synced · " .. tostring(count) .. " change(s)")
            elseif stillOn() then
                failedAt = tern.now(); syncStatus.set(problem)
            end
        end, owned)
    end, function(reason: string)
        busy = false
        if stillOn() then failedAt = tern.now(); syncStatus.set(reason) end
    end)
end
local function schedule()
    tern.timer(SYNC_MS, function(cx: WindowCx?)
        schedule()
        if cx then pcall(syncTick, cx) end
    end)
end

tern.on("window_start", function(cx: WindowCx)
    status_prompt.ensure(cx, tern.plugin.id)
    schedule()
end)

tern.command({ id = "show", title = "TODO: attach to this panel", icon = "list-checks", run = function(cx: WindowCx) controller.start(cx, false) end })
tern.command({ id = "settings", title = "TODO: Open Settings", icon = "list-checks", run = function(cx: WindowCx) openSettings(cx) end })

-- The status segment is TODO's one launcher (it is no longer in the Files pane).
tern.chrome.status(function(_pane: StatusPaneInfo)
    return { { icon = "list-checks", text = "TODO", tone = "muted", command = "plugin." .. tern.plugin.id .. ".settings" } }
end)

require("./updater/window").register({ name = "TODO", dir = "TODO", title_prefix = "TODO: " })
