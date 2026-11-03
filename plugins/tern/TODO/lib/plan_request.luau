-- One explicit metadata query through native Tern, never task adoption. CodexBWAI; MIT.
local request = {}
local sequence = 0
local function pathValid(path)
    return type(path)=="string" and #path<=4096 and not path:find("%c") and
        (path:sub(1,1)=="/" or path:match("^%a:[/\\]")~=nil or path:sub(1,2)=="\\\\")
end
function request.reply(text, id, decode)
    if type(text)~="string" or #text>64000 then return nil end
    for line in (text.."\n"):gmatch("([^\r\n]*)[\r\n]") do
        local raw=line:match("^%s*TODO_PLAN_REPLY v1%s+(%b{})%s*$")
        if raw then
            local ok,value=pcall(decode,raw)
            if ok and type(value)=="table" and value.request_id==id then
                if value.state=="none" or value.state=="unsupported" then return {state=value.state} end
                if value.state=="active" and pathValid(value.path) and type(value.plan_id)=="string" and value.plan_id:match("^plan%-%x+$") and #value.plan_id<=80 then
                    return {state="active",path=value.path,plan_id=value.plan_id}
                end
            end
        end
    end
    return nil
end
function request.new(api)
    local pending={}
    return function(cx,target,valid,done)
        if pending[target] then cx:toast("info","TODO is already checking this session.");return end
        local native=nil
        for _,agent in cx.agents:list() do if agent.pane==target then native=agent end end
        local pane=cx.session:pane(target)
        if not native then
            cx:toast("error","Tern does not expose a native agent communication endpoint for this session. The TODO flow has ended.");return
        end
        if not pane or native.state~="idle" then
            cx:toast("info","TODO could not query this session: the agent is not ready. The TODO flow has ended.");return
        end
        sequence+=1
        local id="todo-"..tostring(api.now()).."-"..tostring(sequence)
        local prompt="# TODO_PLAN_QUERY v1 request_id="..id..". Report metadata only for YOUR currently active interactive canonical plan. Do not start, resume, edit or adopt any work; do not infer a plan from directory contents or another pane. Reply with exactly one line beginning TODO_PLAN_REPLY v1 followed by JSON: request_id must equal "..id.."; state must be active, none, or unsupported. For active include the absolute canonical path on your execution host and its existing plan_id from its explicit TODO checkpoint block. If no active plan, use state none. If an active plan has no explicit TODO checkpoint block, use state unsupported. Do not create or modify a plan."
        pending[target]=id
        local function finish(fresh,value,error)
            if pending[target]~=id then return end
            pending[target]=nil
            done(fresh,value,error)
        end
        -- Use Tern's agent protocol; never type a request into an arbitrary shell or draft.
        local ok=pcall(function()
            cx.agents:ask(target,prompt)
        end)
        if not ok then finish(cx,nil,"The native plan query could not be submitted.");return end
        local deadline=api.now()+60000
        local function poll(fresh)
            if not fresh or not valid(fresh) then finish(fresh,nil,"The selected session changed during plan detection.");return end
            local text=nil
            for _,agent in fresh.agents:list() do if agent.pane==target then text=agent.last_message end end
            local value=request.reply(text,id,api.json.decode)
            if value then finish(fresh,value,nil)
            elseif api.now()>=deadline then finish(fresh,nil,"The session did not return a valid plan reply before the timeout.")
            else api.timer(1000,poll) end
        end
        api.timer(1000,poll)
    end
end
return request
