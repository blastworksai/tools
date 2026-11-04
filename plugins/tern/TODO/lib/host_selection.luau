-- Resolve only through the owning host's native split and process inventory.
-- CodexBWAI; MIT. Native CLI transport is shared with the estate's SPAWN design.
local Native=require("./native_cli")
local binding=require("./selected_binding")
local selection={}
function selection.new(api)
local resolver={}
function resolver.resolve(panel,window,alive,callback)
    local deadline=api.now()+8000
    local finished,active,deliver=false,alive,callback
    alive=function() return not finished and active() end
    callback=function(pid,err)
        if finished or not active() then return end
        finished=true;deliver(pid,err)
    end
    api.timer(8000,function() if alive() then callback(nil,"Native session inspection timed out.") end end)
    local function inspect(key,done)
        if not alive() then return end
        local remaining=math.floor(deadline-api.now())
        if remaining<=0 then callback(nil,"Native session inspection timed out.");return end
        local started=pcall(function() api.native.inspect(key,{timeout_ms=math.min(remaining,2500)},function(result,err)
            if not alive() then return end
            if err or not result or result.status~=0 then done(nil,err or "Could not inspect the selected execution host.");return end
            local ok,value=pcall(api.decode,result.stdout or "")
            done(if ok then value else nil,if ok then nil else "Invalid native host inventory.")
        end) end)
        if not started then callback(nil,"Could not start native host inspection.") end
    end
    local function locate(done)
        inspect(window,function(first,err)
            if not first then done(nil,err);return end
            local keys,seen={window},{[window]=true}
            for _,client in first.clients or {} do
                local key=client.window
                if type(key)=="string" and #key<=256 and not key:find("%c") and not seen[key] then
                    seen[key]=true;table.insert(keys,key)
                end
            end
            if #keys>8 then done(nil,"Too many native windows to identify this attach safely.");return end
            local matches={}
            local function accept(inventory,key)
                local found,why=binding.resolve(inventory,panel)
                if found then found.window=key;table.insert(matches,found)
                elseif why~="pending" then return why end
                return nil
            end
            local problem=accept(first,window)
            if problem then done(nil,problem);return end
            local function nextKey(index)
                if index>#keys then
                    if #matches==1 then done(matches[1])
                    elseif #matches==0 then done(nil,"pending")
                    else done(nil,"The TODO panel belongs to multiple native windows.") end
                    return
                end
                inspect(keys[index],function(inventory,why)
                    if not inventory then done(nil,why);return end
                    local bad=accept(inventory,keys[index])
                    if bad then done(nil,bad) else nextKey(index+1) end
                end)
            end
            nextKey(2)
        end)
    end
    local function start()
        locate(function(first,err)
            if not first then
                if err=="pending" and api.now()<deadline then api.timer(100,start)
                else callback(nil,err) end
                return
            end
            locate(function(second,why)
                if not binding.same(first,second) or first.window~=(second and second.window) then callback(nil,why or "The selected native split changed.");return end
                local started=pcall(function() api.native.process(first.window,first.session,first.target,{timeout_ms=math.max(1,math.min(2500,deadline-api.now()))},function(result,problem)
                    if not alive() then return end
                    local ok,value=pcall(api.decode,if result then result.stdout or "" else "")
                    if problem or not result or result.status~=0 or not ok or type(value)~="table" or value.pane~=first.target or type(value.child)~="table" or type(value.child.pid)~="number" or value.child.pid<=0 or value.child.pid%1~=0 then
                        callback(nil,problem or "Could not identify the selected native process.");return
                    end
                    locate(function(last,changed)
                        if not binding.same(first,last) or first.window~=(last and last.window) then callback(nil,changed or "The selected native split changed.")
                        else callback(value.child.pid) end
                    end)
                end) end)
                if not started then callback(nil,"Could not start the native process inspection.") end
            end)
        end)
    end
    start()
end
return resolver
end
function selection.resolve(...)
    return selection.new({native=Native,now=tern.now,timer=tern.timer,decode=tern.json.decode}).resolve(...)
end
return selection
