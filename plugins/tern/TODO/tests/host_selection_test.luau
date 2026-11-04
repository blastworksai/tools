local selection=require("../lib/host_selection")
local function fixture()
    local f={calls=0,timers={},delivered={},active=true,clock=1}
    function f.inventory()
        return {clients={},sessions={{id=1,tabs={{id=2,blocks={{id=10,live=true,focused=true},{id=11,live=true}},splits={Split={axis="Row",a={Leaf=10},b={Leaf=11}}}}}}}}
    end
    local native={}
    function native.inspect(window,opts,cb)
        f.calls+=1
        if f.pending then f.waiting=cb;return end
        local inventory=f.inventory()
        if f.drift and f.calls==3 then inventory.sessions[1].tabs[1].blocks[1].focused=false end
        cb({status=0,stdout=tern.json.encode(inventory)})
    end
    function native.process(window,session,pane,opts,cb)
        assert(window=="" and session==1 and pane==10)
        if f.spawnFails then error("process unavailable") end
        cb({status=0,stdout=tern.json.encode({pane=10,child={pid=88}})})
    end
    f.resolver=selection.new({native=native,decode=tern.json.decode,now=function()return f.clock end,timer=function(ms,fn)table.insert(f.timers,{ms=ms,fn=fn})end})
    function f.run() f.resolver.resolve(11,"",function()return f.active end,function(pid,err)table.insert(f.delivered,{pid=pid,err=err})end)end
    return f
end
return {
    {"host resolves selected sibling and fences membership around its process read",function()
        local f=fixture();f.run();assert(#f.delivered==1 and f.delivered[1].pid==88 and f.calls==3)
        local g=fixture();g.drift=true;g.run();assert(#g.delivered==1 and g.delivered[1].pid==nil)
    end},
    {"async process spawn failure terminates once; deadline cannot deliver again",function()
        local f=fixture();f.spawnFails=true;f.run();assert(#f.delivered==1 and f.delivered[1].err)
        f.timers[1].fn();assert(#f.delivered==1)
    end},
    {"cancelled and timed out native callbacks cannot adopt a later selection",function()
        local f=fixture();f.pending=true;f.run();f.active=false;f.waiting({status=0,stdout=tern.json.encode(f.inventory())});assert(#f.delivered==0)
        local g=fixture();g.pending=true;g.run();g.clock=9001;g.timers[1].fn();g.waiting({status=0,stdout=tern.json.encode(g.inventory())});assert(#g.delivered==1 and g.delivered[1].pid==nil)
    end},
}
