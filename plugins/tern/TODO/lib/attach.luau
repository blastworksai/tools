-- Window controller: detect first, then ask only for the canonical plan path.
-- CodexBWAI; MIT.
local connection = require("./connection")
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
    function controller.openSource(cx, target, source)
        if existing(cx,target) then cx:toast("info","This tab already has a plan view.");return end
        cx:new_block(KIND,{api.json.encode(source)},"beside",{target=target,dir="right",ratio=0.3,focus=false})
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
    local function pathPrompt(cx, origin, source, detectedProcess)
        local snapshot = connection.fingerprint(detectedProcess)
        cx:prompt({placeholder="Absolute plan path — " .. (source.label or "selected source")}):next(function(path,err,fresh)
            if not fresh or not path or path=="" then return end
            if not same(fresh,origin) then changed(fresh);return end
            local function bind(latest)
                source.path=path
                controller.openSource(latest,origin.target,source)
            end
            if snapshot then
                process(fresh,origin,function(now,latest)
                    if connection.fingerprint(now)~=snapshot then changed(latest);return end
                    bind(latest)
                end)
            else bind(fresh) end
        end)
    end
    local function sshPrompt(cx, origin, detail)
        cx:prompt({placeholder="Reviewed file-reading SSH alias — " .. (detail or "not a forced agent launcher")}):next(function(destination,err,fresh)
            if not fresh or not destination or destination=="" then return end
            if not same(fresh,origin) then changed(fresh);return end
            pathPrompt(fresh,origin,{ssh=destination,label="SSH " .. destination},nil)
        end)
    end
    local function manual(cx, origin, reason)
        cx:pick({placeholder=reason or "Choose the plan's file location",items={
            {label="Local to this session host",mode="host"},
            {label="SSH file source",mode="ssh",detail="Ordinary file commands, not agent-launch keys"},
        }}):next(function(choice,err,fresh)
            if not fresh or not choice then return end
            if not same(fresh,origin) then changed(fresh);return end
            if choice.mode=="host" then pathPrompt(fresh,origin,{label="Session host"},nil)
            else sshPrompt(fresh,origin,nil) end
        end)
    end
    local function detected(cx, origin, route, metadata)
        if route.kind=="host" then
            pathPrompt(cx,origin,{label=route.label},metadata)
        elseif route.kind=="ssh" then
            if route.needs_alias then sshPrompt(cx,origin,route.label .. ". " .. route.reason);return end
            -- Knowing an agent's SSH destination does not prove its key permits file reads.
            cx:pick({placeholder="Detected SSH " .. route.label,items={
                {label="Use detected SSH " .. route.ssh,mode="detected",detail="Confirm ordinary file commands; forced agent-launch keys cannot be reused"},
                {label="Use another SSH file source",mode="other"},
            }}):next(function(choice,err,fresh)
                if not fresh or not choice then return end
                if not same(fresh,origin) then changed(fresh);return end
                if choice.mode=="detected" then pathPrompt(fresh,origin,{ssh=route.ssh,label="SSH " .. route.label},metadata)
                else sshPrompt(fresh,origin,route.label) end
            end)
        else
            manual(cx,origin,route.reason .. (if route.detected then " (" .. route.detected .. ")" else ""))
        end
    end
    function controller.start(cx, forceManual)
        local target = cx.session:focused()
        if not target then return end
        local pane = cx.session:pane(target)
        local host = cx.hosts:current()
        if not pane or pane.exited~=nil or host.state~="connected" then cx:toast("error","Choose a live panel on a connected host.");return end
        if existing(cx,target) then cx:toast("info","This tab already has a plan view.");return end
        local origin={target=target,tab=pane.tab,host=host.id,window=cx:window_key()}
        if forceManual then manual(cx,origin,nil);return end
        if host.kind=="remote" then detected(cx,origin,connection.detect(host,pane,nil),nil);return end
        process(cx,origin,function(metadata,fresh)
            detected(fresh,origin,connection.detect(fresh.hosts:current(),fresh.session:pane(target),metadata),metadata)
        end)
    end
    return controller
end
return attach
