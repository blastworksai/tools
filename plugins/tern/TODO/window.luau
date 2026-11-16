-- English-first native connection detection, status entry, settings pane and optional board sync.
-- CodexBWAI; MIT.
local status_prompt = require("./status/status_prompt")
local settings = require("./lib/settings")
local board_sync = require("./lib/board_sync")
local plan_view = require("./lib/plan_view")
local board_claim = require("./lib/board_claim")
local sync_gate = require("./lib/sync_gate")
local KIND = tern.plugin.id .. ".list"
local TITLE = "TODO Settings"
local SYNC_MS, RETRY_MS = 2000, 10000

local controller = require("./lib/attach").new({
    plugin = { id = tern.plugin.id },
    now = function(): number return tern.now() end,
    timer = function(ms: number, callback: (WindowCx?) -> ()) return tern.timer(ms, callback) end,
    bind = function(panel: number, target: number) pcall(tern.kv.set, "target/" .. string.format("%.0f", panel), target) end,
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

local syncStatus: string? = nil
local synced = sync_gate.new()
local failedAt = -RETRY_MS
local busy = false

local function paint(cx: any, pane: number)
    local s = settings.load(tern.kv)
    local before = settings.load(tern.kv)
    local eligible = settings.eligible(s, candidates(cx))
    if s.attach and not settings.isEligible(s, eligible, s.attach) then s.attach = nil; settings.save(tern.kv, s, before) end
    cx.canvas:set(pane, { view = settings.draw(tern.ui, s, eligible, syncStatus) })
end
local function settingsPane(cx: any): number?
    for _, info in cx.canvas:list() do
        if info.owner == tern.plugin.id and info.title == TITLE then return info.pane end
    end
    return nil
end
local function openSettings(cx: any)
    local pane = settingsPane(cx)
    if pane then paint(cx, pane); cx.layout:focus(pane); return end
    local s = settings.load(tern.kv)
    local opened, problem = cx.canvas:open({
        title = TITLE,
        view = settings.draw(tern.ui, s, settings.eligible(s, candidates(cx)), syncStatus),
        about = "TODO settings: which session to attach to, Glitch integration, the board and plan sync. A click changes TODO's own settings only; it never edits a plan.",
        focus = true,
    })
    if not opened then cx:toast("error", "Could not open TODO Settings.", problem) end
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
    local before = settings.load(tern.kv)
    local after = settings.apply(before, ev.act, ev.value, candidates(cx))
    synced.settingsChanged(before, after)
    settings.save(tern.kv, after, before)
    if after.sync == false then syncStatus = nil end
    paint(cx, ev.pane)
    changed(cx, before, after, ev.act)
    return true
end)

-- Glitch -> Tern board sync, one way. Reads the plan the TODO view already validated
-- (published through plugin KV by host.luau); never reads or writes the canonical plan.
local function syncTick(cx: any)
    if busy then return end
    local s = settings.load(tern.kv)
    if settings.mode(s) ~= "glitch-sync" or not s.attach then return end
    local target = attached(cx, s)
    if not target then return end
    local view, panel = viewPanel(cx, target.pane)
    if view == "other" then syncStatus = "This tab's plan view serves another session. Select the session again in TODO Settings."; return end
    if view ~= "match" or not panel then return end
    local entry = tern.kv.get("plan/" .. string.format("%.0f", panel))
    if type(entry) ~= "table" or type(entry.rev) ~= "number" or plan_view.validate(entry.plan) ~= nil then return end
    local key = string.format("%.0f", panel) .. ":" .. entry.plan.plan_id
    if synced.matches(key, entry.rev) or tern.now() - failedAt < RETRY_MS then return end
    local path = board_sync.boardPath(tern.plugin.data, entry.plan.plan_id)
    local prepared = pcall(function()
        if not tern.fs.exists(path) then
            tern.fs.mkdir(tern.plugin.data .. "/boards")
            tern.fs.write(path, board_sync.initialMarkdown(entry.plan))
        end
    end)
    if not prepared then syncStatus = "Could not create the TODO board file."; failedAt = tern.now(); return end
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
                synced.mark(key, entry.rev, gen); syncStatus = "Board synced · " .. tostring(count) .. " change(s)"
            elseif stillOn() then
                failedAt = tern.now(); syncStatus = problem
            end
        end, owned)
    end, function(reason: string)
        busy = false
        if stillOn() then failedAt = tern.now(); syncStatus = reason end
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
