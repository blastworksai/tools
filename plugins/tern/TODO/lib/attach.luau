-- Window controller: detect first, then ask only for the canonical plan path.
-- CodexBWAI; MIT.
local connection = require("./connection")
local planRequest = require("./plan_request")
local attach = {}
function attach.new(api)
    local KIND = api.plugin.id .. ".list"
    local controller = {}
    local queryPlan=planRequest.new(api)
    local function existing(cx, target)
        local owner = cx.session:pane(target)
        if not owner then return true end
        for _, pane in cx.session:panes() do
            if pane.tab == owner.tab and pane.block == KIND then return true end
        end
        return false
    end
    function controller.openSource(cx, target, source, planId)
        if existing(cx,target) then cx:toast("info","This tab already has a plan view.");return end
        cx:new_block(KIND,{api.json.encode(source),planId},"beside",{target=target,dir="right",ratio=0.3,focus=false})
    end
    local function same(cx, origin)
        local pane = cx.session:pane(origin.target)
        local host = cx.hosts:current()
        return pane ~= nil and pane.tab == origin.tab and pane.exited == nil and host.id == origin.host and host.state == "connected"
    end
    local function changed(cx)
        cx:toast("error","The panel or connection changed. Attach again in the intended panel.")
    end
    local function process(cx, origin, callback)
        local candidates = {api.getenv("TERN_EXE") or "tern"}
        if api.runtime.os == "macos" then table.insert(candidates,"/Applications/Tern.app/Contents/MacOS/tern") end
        local function run(index, current)
            if not same(current,origin) then changed(current);return end
            local function finish(result,fresh)
                if not fresh then return end
                if not same(fresh,origin) then changed(fresh);return end
                local ok, value = false, nil
                if type(result.stdout)=="string" and #result.stdout<=65536 then ok, value=pcall(api.json.decode,result.stdout) end
                if result.status==0 and ok and type(value)=="table" and value.pane==origin.target and connection.fingerprint(value) then
                    callback(value,fresh)
                elseif index<#candidates then run(index+1,fresh)
                else callback(nil,fresh) end
            end
            local ok = pcall(function()
                api.process.run({candidates[index],"process",string.format("%.0f",origin.target),"--window",origin.window,"--json"},
                    {timeout_ms=2500},finish)
            end)
            if not ok then
                if index<#candidates then run(index+1,current) else callback(nil,current) end
            end
        end
        run(1,cx)
    end
    function controller.start(cx, _forceManual, selected)
        local target=selected or cx.session:focused()
        if not target then return end
        local pane=cx.session:pane(target)
        local host=cx.hosts:current()
        if not pane or pane.exited~=nil or host.state~="connected" then changed(cx);return end
        if existing(cx,target) then cx:toast("info","This tab already has a plan view.");return end
        local origin={target=target,tab=pane.tab,host=host.id,window=cx:window_key()}
        local function begin(metadata,fresh)
            local route=connection.detect(fresh.hosts:current(),fresh.session:pane(target),metadata)
            if route.kind~="host" or route.needs_alias then
                fresh:toast("error","TODO could not establish a verified file-reading route for this session. Use a native Tern remote connection. "..(route.reason or ""));return
            end
            local fingerprint=connection.fingerprint(metadata)
            queryPlan(fresh,target,function(latest) return same(latest,origin) end,function(latest,reply,error)
                if not latest then return end
                if error then latest:toast("error",error.." The TODO flow has ended.");return end
                if reply.state=="unsupported" then latest:toast("error","This session has a plan without an explicit TODO checkpoint block. The TODO flow has ended.");return end
                if reply.state=="none" then latest:toast("info","This session is not working on a plan. The TODO flow has ended.");return end
                if not same(latest,origin) then changed(latest);return end
                local function bind(now)
                    controller.openSource(now,target,{path=reply.path,ssh=route.ssh,label=route.label},reply.plan_id)
                end
                if fingerprint then
                    process(latest,origin,function(current,last)
                        if connection.fingerprint(current)~=fingerprint then changed(last);return end
                        bind(last)
                    end)
                else bind(latest) end
            end)
        end
        if host.kind=="remote" then begin(nil,cx) else process(cx,origin,begin) end
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
