-- Window controller: select a session; native host resolves its explicit publication.
-- CodexBWAI; MIT.
local binding = require("./selected_binding")
local attach = {}
function attach.new(api)
    local KIND = api.plugin.id .. ".list"
    local controller = {}
    local function existing(cx, target)
        local owner = cx.session:pane(target)
        if not owner then return true end
        for _, pane in cx.session:panes() do
            if pane.tab == owner.tab and pane.block == KIND then return true end
        end
        return false
    end
    local function same(cx, origin)
        local pane = cx.session:pane(origin.target)
        local host = cx.hosts:current()
        return pane ~= nil and pane.tab == origin.tab and pane.exited == nil and host.id == origin.host and host.state == "connected"
    end
    local function changed(cx)
        cx:toast("error","The panel or connection changed. Attach again in the intended panel.")
    end
    function controller.start(cx, _forceManual, selected)
        local target=selected or cx.session:focused()
        if not target then return end
        local pane=cx.session:pane(target)
        local host=cx.hosts:current()
        if not pane or pane.exited~=nil or host.state~="connected" then changed(cx);return end
        if existing(cx,target) then cx:toast("info","This tab already has a plan view.");return end
        local origin={target=target,tab=pane.tab,host=host.id,window=cx:window_key()}
        -- Tern makes the split in the selected host's native namespace. The host
        -- resolves that split; client-side CLI ids cannot address a remote host.
        local request=tostring(api.now())..":"..tostring(target)
        local label=(if host.kind=="remote" then "SSH · " else "Local · ")..(host.address or host.name)
        local panel=cx:new_block(KIND,{api.json.encode({mode="selected",label=label,window=origin.window,request=request})},"beside",{target=target,dir="right",ratio=0.3,focus=false})
        if not panel then changed(cx);return end
        local deadline=api.now()+2500
        local function confirm(fresh)
            if not fresh then return end
            local own=fresh.session:pane(panel)
            if not same(fresh,origin) or (own and (own.block~=KIND or own.tab~=origin.tab)) then
                if own and own.block==KIND then fresh.layout:close(panel) end
                changed(fresh);return
            end
            local layout=fresh.session:layout(origin.tab)
            if own and layout and fresh.session:focused()==target and binding.windowPair(layout.root,target,panel) then
                fresh.session:event(panel,{ev="action",id="main",act="confirm-selection",value=request})
            elseif api.now()<deadline then api.timer(100,confirm)
            else
                if own and own.block==KIND then fresh.layout:close(panel) end
                changed(fresh)
            end
        end
        api.timer(100,confirm)
    end

    function controller.chooseSession(cx)
        local hosts, sessions, items = {}, {}, {}
        for _, host in cx.hosts:list() do
            if host.state=="connected" then
                for _, id in host.panes do hosts[id]=host end
            end
        end
        for _, session in cx.session:sessions() do
            for _, tab in session.tabs do sessions[tab]=session.name end
        end
        for _, pane in cx.session:panes() do
            local host=hosts[pane.pane]
            -- CLI agents run in terminal panes; do not restrict this to native OMP.
            if host and pane.tab and not pane.parked and pane.exited==nil and (pane.kind=="agent" or pane.kind=="terminal") then
                table.insert(items,{
                    label=(pane.title~="" and pane.title or pane.program or "Terminal") .. " · " .. string.format("%.0f",pane.pane),
                    detail=(host.address or host.name) .. " · " .. (sessions[pane.tab] or "Session") .. " · " .. (pane.program or "Terminal"),
                    target=pane.pane,host=host.id,tab=pane.tab,program=pane.program,cwd=pane.cwd,title=pane.title,
                })
            end
        end
        table.sort(items,function(a,b) return a.label<b.label end)
        if #items==0 then cx:toast("info","No live agent or terminal sessions are available on connected hosts.");return end
        cx:pick({placeholder="Which agent session should TODO attach to?",items=items}):next(function(choice,err,fresh)
            if not fresh or not choice then return end
            local pane=fresh.session:pane(choice.target)
            local host=nil
            for _, candidate in fresh.hosts:list() do
                if candidate.id==choice.host and candidate.state=="connected" then
                    for _, id in candidate.panes do if id==choice.target then host=candidate end end
                end
            end
            if not host or not pane or pane.exited~=nil or pane.parked or pane.tab~=choice.tab or pane.program~=choice.program then
                changed(fresh);return
            end
            fresh.hosts:switch(host.id)
            fresh.layout:focus(choice.target)
            if fresh.hosts:current().id~=host.id then changed(fresh);return end
            controller.start(fresh,false,choice.target)
        end)
    end
    return controller
end
return attach
