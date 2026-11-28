--!strict
-- Window controller: select a session; native host resolves its explicit publication.
-- Blastworks.ai; MIT.
local binding = require("./selected_binding")
local attach = {}
attach.CHANGED = "The panel or connection changed. Attach again in the intended panel."

export type AttachApi = {
    plugin: { id: string },
    now: () -> number,
    timer: (ms: number, callback: (WindowCx?) -> ()) -> any,
    json: { encode: (value: any) -> string },
    -- Called once the view panel exists, so the window can remember which session it serves.
    bind: ((panel: number, target: number) -> ())?,
    -- Called just before the host is asked to resolve the split: tells the view (a plain event, so it works whichever
    -- machine the session runs on) whether to keep waiting for a plan that is not published yet.
    configure: ((cx: WindowCx, panel: number, target: number, direct: boolean?) -> ())?,
    -- Called when the tab already has a plan view and the window selects a session again: the window wakes the view
    -- if it serves that session, so a dormant view looks for the plan at once (the owner never closes it).
    wake: ((cx: WindowCx, panel: number, target: number) -> ())?,
}
export type Controller = {
    viewFor: (cx: WindowCx, target: number, boundTo: (panel: number) -> number?) -> (string, number?),
    singlePane: (cx: WindowCx) -> Origin?,
    sameSingle: (cx: WindowCx, origin: Origin) -> boolean,
    start: (cx: WindowCx, forceManual: boolean, selected: number?, direct: Origin?) -> (),
}
export type Origin = {
    target: number,
    tab: number,
    host: number,
    hostKind: "local" | "remote",
    address: string?,
}

local function leaf(tree: TabTree?, pane: number): boolean
    return tree ~= nil and tree.pane == pane and tree.split == nil and tree[1] == nil and tree[2] == nil
end

local function directLayout(layout: TabLayout?, origin: Origin): boolean
    return layout ~= nil and layout.tab == origin.tab and layout.focus == origin.target
        and layout.zoomed == false and type(layout.floats) == "table" and next(layout.floats) == nil
end

local function visibleAgent(pane: PaneInfo?): boolean
    return pane ~= nil and not pane.parked and not pane.floating and pane.exited == nil and pane.error == nil
        and (pane.kind == "agent" or pane.kind == "terminal")
end

function attach.new(api: AttachApi): Controller
    local KIND = api.plugin.id .. ".list"
    local controller = {} :: Controller
    local function existing(cx: WindowCx, target: number): (boolean, number?)
        local owner = cx.session:pane(target)
        if not owner then return true, nil end
        for _, pane in cx.session:panes() do
            if pane.tab == owner.tab and pane.block == KIND then return true, pane.pane end
        end
        return false, nil
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
    local function same(cx: WindowCx, origin: Origin, direct: boolean?): boolean
        local pane = cx.session:pane(origin.target)
        local host = cx.hosts:current()
        if not pane or pane.tab ~= origin.tab or pane.exited ~= nil or not host
            or host.id ~= origin.host or host.state ~= "connected" then return false end
        if not direct then return true end
        if not visibleAgent(pane) or cx.session:focused() ~= origin.target
            or host.kind ~= origin.hostKind or host.address ~= origin.address then return false end
        if type(host.panes) ~= "table" then return false end
        local member = table.find(host.panes, origin.target)
        if member == nil or table.find(host.panes, origin.target, member + 1) ~= nil then return false end
        local memberships = 0
        for _, candidate in cx.hosts:list() do
            for _, paneId in candidate.panes do
                if paneId == origin.target then
                    if candidate.id ~= origin.host or candidate.state ~= "connected" or candidate.kind ~= origin.hostKind
                        or candidate.address ~= origin.address then return false end
                    memberships += 1
                end
            end
        end
        return memberships == 1
    end
    function controller.sameSingle(cx: WindowCx, origin: Origin): boolean
        if not same(cx, origin, true) then return false end
        local layout = cx.session:layout(origin.tab)
        return layout ~= nil and directLayout(layout, origin) and leaf(layout.root, origin.target)
    end
    function controller.singlePane(cx: WindowCx): Origin?
        local target = cx.session:focused()
        if target == nil then return nil end
        local pane = cx.session:pane(target)
        if not pane or not pane.tab then return nil end
        local host = cx.hosts:current()
        if not host or (host.kind ~= "local" and host.kind ~= "remote") then return nil end
        local origin: Origin = { target = target, tab = pane.tab, host = host.id, hostKind = host.kind, address = host.address }
        return if controller.sameSingle(cx, origin) then origin else nil
    end
    local function changed(cx: WindowCx)
        cx:toast("error", attach.CHANGED)
    end
    function controller.start(cx: WindowCx, _forceManual: boolean, selected: number?, direct: Origin?)
        local target = selected or cx.session:focused()
        if not target then return end
        local pane = cx.session:pane(target)
        local host = cx.hosts:current()
        if not pane or pane.tab == nil or pane.exited ~= nil or not host or host.state ~= "connected" then changed(cx); return end
        local has, view = existing(cx, target)
        if direct and (target ~= direct.target or not controller.sameSingle(cx, direct)) then changed(cx); return end
        if has then
            cx:toast("info", "This tab already has a plan view.")
            if view and api.wake then api.wake(cx, view, target) end
            return
        end
        -- Settings holds the focus, but confirmation needs the target focused: bring it forward.
        -- The new block opens with focus = false, so the target keeps it.
        if not direct and cx.session:focused() ~= target then cx.layout:focus(target) end
        local origin: Origin = direct or { target = target, tab = pane.tab, host = host.id, hostKind = host.kind, address = host.address }
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
            if not same(fresh, origin, direct ~= nil) or (own and (own.block ~= KIND or own.tab ~= origin.tab)) then
                if own and own.block == KIND then fresh.layout:close(panel) end
                changed(fresh); return
            end
            local layout = fresh.session:layout(origin.tab)
            local paired = false
            if direct then
                local root = layout and layout.root
                local stable = directLayout(layout, origin)
                paired = stable and root ~= nil and root.pane == nil and root.split == "right"
                    and leaf(root[1], target) and leaf(root[2], panel)
                if not paired and (own or not stable or not leaf(root, target)) then
                    if own and own.block == KIND then fresh.layout:close(panel) end
                    changed(fresh); return
                end
            elseif layout then
                paired = binding.windowPair(layout.root, target, panel)
            end
            if own and paired and fresh.session:focused() == target then
                if api.configure then api.configure(fresh, panel, target, if direct then true else nil) end
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
