-- Native selection bridge: no client process call, agent input or path prompt.
local attach=require("../lib/attach")
local function fixture()
    local f={picks={},blocks={},toasts={},timers={},events={},closed={},panes={{pane=10,tab=20,kind="terminal",program="bash",title="agent",cwd="/work"}}}
    f.host={id=1,name="host",address="user@host",state="connected",kind="remote",panes={10}}
    f.root={split="right",{pane=10},{pane=11}}
    local cx={session={},hosts={},layout={}}
    f.focus=10
    function cx.session:focused() return f.focus end
    function cx.session:pane(id) for _,p in f.panes do if p.pane==id then return p end end end
    function cx.session:panes() return f.panes end
    function cx.session:sessions() return {{name="Interactive",tabs={20,21}}} end
    function cx.session:layout() return {root=f.root} end
    function cx.session:event(pane,event)table.insert(f.events,{pane=pane,event=event})end
    function cx.hosts:current() return f.host end
    function cx.hosts:list() return {f.host} end
    function cx.hosts:switch(id) assert(id==f.host.id) end
    function cx.layout:focus(id) f.focused=id; f.focus=id end
    function cx.layout:close(id) table.insert(f.closed,id) end
    function cx:window_key() error("attach must never read the client window key") end
    function cx:prompt() error("no operator plan prompt") end
    function cx:run() error("no agent or shell input") end
    function cx:pick(opts) return {next=function(_,cb)table.insert(f.picks,{opts=opts,cb=cb})end} end
    function cx:new_block(kind,args,how,opts)
        table.insert(f.blocks,{kind=kind,args=args,opts=opts})
        table.insert(f.panes,{pane=11,tab=20,block=kind})
        return 11
    end
    function cx:toast(level,text)table.insert(f.toasts,{level=level,text=text})end
    local api={bind=function(panel,target) f.bound={panel=panel,target=target} end,plugin={id="todo"},json=tern.json,now=function()return 1 end,timer=function(_,fn)table.insert(f.timers,fn)end,process={run=function()error("no client-side native process lookup")end}}
    f.cx=cx;f.controller=attach.new(api)
    return f
end
return {
    {"selected native split delegates process resolution to host, with no client process call",function()
        local f=fixture();f.controller.start(f.cx,false)
        local source=tern.json.decode(f.blocks[1].args[1])
        assert(source.mode=="selected" and source.window==nil and next(source)~=nil and source.discover_pid==nil and source.path==nil)
        assert(f.blocks[1].opts.target==10 and f.blocks[1].opts.focus==false)
        f.timers[1](f.cx)
        assert(#f.events==1 and f.events[1].pane==11 and f.events[1].event.value==source.request)
    end},
    {"closed or switched selected target cannot confirm a new TODO block",function()
        local g=fixture();g.controller.start(g.cx,false);g.host.id=2;g.timers[1](g.cx)
        assert(#g.events==0 and g.closed[1]==11)
    end},
    {"attaching from Settings (focused) brings the target forward so the block confirms",function()
        local f=fixture();f.focus=30;f.controller.start(f.cx,false,10)
        assert(f.focused==10,"target was not focused")
        f.timers[1](f.cx)
        assert(#f.events==1 and f.events[1].pane==11,"confirmation never fired from Settings")
        assert(f.bound and f.bound.panel==11 and f.bound.target==10)
    end},
    {"the view is told by event, just before the host resolves the split, whether to wait for a plan",function()
        local f=fixture()
        local order={}
        local api={bind=function() table.insert(order,"bind") end,configure=function(cx,panel,target) table.insert(order,"configure:"..panel..":"..target) end,
            plugin={id="todo"},json=tern.json,now=function()return 1 end,timer=function(_,fn)table.insert(f.timers,fn)end}
        local controller=attach.new(api)
        local original=f.cx.session.event
        function f.cx.session:event(pane,event) table.insert(order,"event:"..event.act); original(self,pane,event) end
        controller.start(f.cx,false,10);f.timers[1](f.cx)
        assert(table.concat(order,",")=="bind,configure:11:10,event:confirm-selection",table.concat(order,","))
    end},
    {"viewFor tells a view of this session from a view of another session in the same tab",function()
        local f=fixture()
        assert(f.controller.viewFor(f.cx,10,function() return nil end)=="none")
        f.controller.start(f.cx,false,10)
        local kind,panel=f.controller.viewFor(f.cx,10,function(p) return if p==11 then 10 else nil end)
        assert(kind=="match" and panel==11)
        kind,panel=f.controller.viewFor(f.cx,10,function(p) return 99 end)
        assert(kind=="other" and panel==11)
        assert(f.controller.viewFor(f.cx,10,function() return nil end)=="other","an unrecorded view is not trusted")
    end},
    {"selecting the session a view already serves wakes that view instead of only toasting",function()
        local f=fixture()
        local woke={}
        local api={wake=function(cx,panel,target) table.insert(woke,panel..":"..target) end,plugin={id="todo"},json=tern.json,now=function()return 1 end,timer=function(_,fn)table.insert(f.timers,fn)end}
        local controller=attach.new(api)
        controller.start(f.cx,false,10)
        assert(#woke==0,"a fresh attach is not a wake")
        controller.start(f.cx,false,10)
        assert(#woke==1 and woke[1]=="11:10",table.concat(woke,","))
        assert(f.toasts[#f.toasts].text:find("already has a plan view",1,true))
    end},
}
