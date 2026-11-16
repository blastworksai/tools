--!strict
-- Window controller: select a session; native host resolves its explicit publication.
-- CodexBWAI; MIT.
local binding = require("./selected_binding")
local attach = {}

export type AttachApi = {
    plugin: { id: string },
    now: () -> number,
    timer: (ms: number, callback: (WindowCx?) -> ()) -> any,
    json: { encode: (value: any) -> string },
    -- Called once the view panel exists, so the window can remember which session it serves.
    bind: ((panel: number, target: number) -> ())?,
}
export type Controller = {
    viewFor: (cx: WindowCx, target: number, boundTo: (panel: number) -> number?) -> (string, number?),
    start: (cx: WindowCx, forceManual: boolean, selected: number?) -> (),
}
type Origin = { target: number, tab: number, host: number }

function attach.new(api: AttachApi): Controller
    local KIND = api.plugin.id .. ".list"
    local controller = {} :: Controller
    local function existing(cx: WindowCx, target: number): boolean
        local owner = cx.session:pane(target)
        if not owner then return true end
        for _, pane in cx.session:panes() do
            if pane.tab == owner.tab and pane.block == KIND then return true end
        end
        return false
    end
    -- The TODO view in the target's tab: ("none") no view, ("match", panel) a view for this
    -- session, ("other", panel) a view for another session of the same tab. `boundTo(panel)`
    -- is the session the panel was attached to; unknown counts as another session.
    function controller.viewFor(cx: WindowCx, target: number, boundTo: (panel: number) -> number?): (string, number?)
        local owner = cx.session:pane(target)
        if not owner then return "none", nil end
        for _, pane in cx.session:panes() do
            if pane.tab == owner.tab and pane.block == KIND then
                return (if boundTo(pane.pane) == target then "match" else "other"), pane.pane
            end
        end
        return "none", nil
    end
    local function same(cx: WindowCx, origin: Origin): boolean
        local pane = cx.session:pane(origin.target)
        local host = cx.hosts:current()
        return pane ~= nil and pane.tab == origin.tab and pane.exited == nil and host.id == origin.host and host.state == "connected"
    end
    local function changed(cx: WindowCx)
        cx:toast("error", "The panel or connection changed. Attach again in the intended panel.")
    end
    function controller.start(cx: WindowCx, _forceManual: boolean, selected: number?)
        local target = selected or cx.session:focused()
        if not target then return end
        local pane = cx.session:pane(target)
        local host = cx.hosts:current()
        if not pane or pane.tab == nil or pane.exited ~= nil or host.state ~= "connected" then changed(cx); return end
        if existing(cx, target) then cx:toast("info", "This tab already has a plan view."); return end
        -- Settings holds the focus, but confirmation needs the target focused: bring it forward.
        -- The new block opens with focus = false, so the target keeps it.
        if cx.session:focused() ~= target then cx.layout:focus(target) end
        local origin: Origin = { target = target, tab = pane.tab, host = host.id }
        -- Tern makes the split in the selected host's native namespace. The host
        -- resolves that split; client-side CLI ids cannot address a remote host.
        -- SKILLS-174: the client window key is never sent; it is not host identity.
        local request = tostring(api.now()) .. ":" .. tostring(target)
        local label = (if host.kind == "remote" then "SSH · " else "Local · ") .. (host.address or host.name)
        local panel = cx:new_block(KIND, { api.json.encode({ mode = "selected", label = label, request = request }) }, "beside", { target = target, dir = "right", ratio = 0.3, focus = false })
        if not panel then changed(cx); return end
        if api.bind then api.bind(panel, target) end
        local deadline = api.now() + 2500
        local function confirm(fresh: WindowCx?)
            if not fresh then return end
            local own = fresh.session:pane(panel)
            if not same(fresh, origin) or (own and (own.block ~= KIND or own.tab ~= origin.tab)) then
                if own and own.block == KIND then fresh.layout:close(panel) end
                changed(fresh); return
            end
            local layout = fresh.session:layout(origin.tab)
            if own and layout and fresh.session:focused() == target and binding.windowPair(layout.root, target, panel) then
                fresh.session:event(panel, { ev = "action", id = "main", act = "confirm-selection", value = request })
            elseif api.now() < deadline then api.timer(100, confirm)
            else
                if own and own.block == KIND then fresh.layout:close(panel) end
                changed(fresh)
            end
        end
        api.timer(100, confirm)
    end
    return controller
end
return attach
