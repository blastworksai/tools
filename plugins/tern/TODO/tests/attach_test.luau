-- Native selection bridge: no client process call, agent input or path prompt.
local attach=require("../lib/attach")
local function fixture()
    local f={picks={},blocks={},toasts={},timers={},events={},closed={},panes={{pane=10,tab=20,kind="terminal",program="bash",title="agent",cwd="/work"}}}
    f.host={id=1,name="host",address="user@host",state="connected",kind="remote",panes={10}}
    f.root={pane=10}
    f.floats={}
    local cx={session={},hosts={},layout={}}
    f.focus=10
    function cx.session:focused() return f.focus end
    function cx.session:pane(id) for _,p in f.panes do if p.pane==id then return p end end end
    function cx.session:panes() return f.panes end
    function cx.session:sessions() return {{name="Interactive",tabs={20,21}}} end
    function cx.session:layout(tab)
        return {tab=tab,root=f.root,floats=f.floats,zoomed=false,focus=f.focus}
    end
    function cx.session:event(pane,event)table.insert(f.events,{pane=pane,event=event})end
    function cx.hosts:current() return f.host end
    function cx.hosts:list() return f.hosts or {f.host} end
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
        f.root={split="right",{pane=opts.target},{pane=11},ratio=0.3}
        return 11
    end
    function cx:toast(level,text)table.insert(f.toasts,{level=level,text=text})end
    local api={bind=function(panel,target) f.bound={panel=panel,target=target} end,plugin={id="todo"},json=tern.json,now=function()return 1 end,timer=function(_,fn)table.insert(f.timers,fn)end,process={run=function()error("no client-side native process lookup")end}}
    f.cx=cx;f.controller=attach.new(api)
    return f
end
return {
    {"one-pane tab attaches directly even when another tab has a live pane",function()
        for _,hostKind in {"local","remote"} do
            local f=fixture()
            f.host.kind=hostKind
            table.insert(f.host.panes,12)
            table.insert(f.panes,{pane=12,tab=21,kind="terminal"})
            local origin=f.controller.singlePane(f.cx)
            assert(origin and origin.target==10 and origin.tab==20 and origin.hostKind==hostKind)
            f.controller.start(f.cx,false,origin.target,origin)
            f.timers[1](f.cx)
            local source=tern.json.decode(f.blocks[1].args[1])
            local label=if hostKind=="remote" then "SSH · " else "Local · "
            assert(source.label==label .. f.host.address and f.blocks[1].opts.target==10)
            assert(#f.events==1 and f.events[1].event.act=="confirm-selection")
        end
    end},
    {"two tiled panes or a floating block keep the pane selector",function()
        local f=fixture()
        table.insert(f.panes,{pane=12,tab=20,kind="file"})
        f.root={split="down",{pane=10},{pane=12},ratio=0.5}
        assert(f.controller.singlePane(f.cx)==nil,"an ineligible second pane still occupies a tile")
        f.root={pane=10}
        f.floats={{pane=12,over=10,corner="tr"}}
        assert(f.controller.singlePane(f.cx)==nil,"a floating second pane must preserve selection")
        assert(#f.blocks==0)
    end},
    {"ineligible focused panes cannot open TODO automatically",function()
        local cases={
            parked=function(f) f.panes[1].parked=true end,
            floating=function(f) f.panes[1].floating=true end,
            exited=function(f) f.panes[1].exited=0 end,
            closed=function(f) f.panes={} end,
            hidden=function(f) f.root={pane=12} end,
            nonterminal=function(f) f.panes[1].kind="file" end,
            disconnected=function(f) f.host.state="disconnected" end,
            ambiguous=function(f)
                f.hosts={f.host,{id=2,state="connected",kind="local",panes={10}}}
            end,
        }
        for name,change in cases do
            local f=fixture()
            change(f)
            assert(f.controller.singlePane(f.cx)==nil and #f.blocks==0,name)
        end
    end},
    {"an automatic origin with stale focus, layout, or host fails before opening",function()
        local changes={
            focus=function(f) f.focus=12 end,
            layout=function(f) f.root={split="right",{pane=10},{pane=12},ratio=0.5} end,
            host=function(f) f.host.id=2 end,
        }
        for name,change in changes do
            local f=fixture()
            local origin=f.controller.singlePane(f.cx)
            assert(origin)
            change(f)
            f.controller.start(f.cx,false,origin.target,origin)
            assert(#f.blocks==0 and #f.events==0,name)
            assert(f.toasts[1] and f.toasts[1].level=="error",name)
        end
    end},
    {"a new pane, moved focus, or changed connection cannot confirm an automatic split",function()
        local changes={
            focus=function(f) f.focus=12 end,
            layout=function(f)
                f.root={split="down",f.root,{pane=12},ratio=0.5}
            end,
            host=function(f) f.host.id=2 end,
        }
        for name,change in changes do
            local f=fixture()
            local origin=f.controller.singlePane(f.cx)
            assert(origin)
            f.controller.start(f.cx,false,origin.target,origin)
            assert(#f.blocks==1,name)
            change(f)
            f.timers[1](f.cx)
            assert(#f.events==0 and f.closed[1]==11,name)
        end
    end},
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
        assert(#f.blocks==1,"the existing view must not open a second split")
        assert(f.toasts[#f.toasts].text:find("already has a plan view",1,true))
    end},
}
