-- Native selection bridge: no client process call, agent input or path prompt.
local attach=require("../lib/attach")
local function fixture()
    local f={picks={},blocks={},toasts={},timers={},events={},closed={},panes={{pane=10,tab=20,kind="terminal",program="bash",title="CodexBWAI",cwd="/work"}}}
    f.host={id=1,name="VM",address="cmdr@vm",state="connected",kind="remote",panes={10}}
    f.root={split="right",{pane=10},{pane=11}}
    local cx={session={},hosts={},layout={}}
    function cx.session:focused() return 10 end
    function cx.session:pane(id) for _,p in f.panes do if p.pane==id then return p end end end
    function cx.session:panes() return f.panes end
    function cx.session:sessions() return {{name="Interactive",tabs={20,21}}} end
    function cx.session:layout() return {root=f.root} end
    function cx.session:event(pane,event)table.insert(f.events,{pane=pane,event=event})end
    function cx.hosts:current() return f.host end
    function cx.hosts:list() return {f.host} end
    function cx.hosts:switch(id) assert(id==f.host.id) end
    function cx.layout:focus(id) f.focused=id end
    function cx.layout:close(id) table.insert(f.closed,id) end
    function cx:window_key() return "window-9" end
    function cx:prompt() error("no operator plan prompt") end
    function cx:run() error("no agent or shell input") end
    function cx:pick(opts) return {next=function(_,cb)table.insert(f.picks,{opts=opts,cb=cb})end} end
    function cx:new_block(kind,args,how,opts)
        table.insert(f.blocks,{kind=kind,args=args,opts=opts})
        table.insert(f.panes,{pane=11,tab=20,block=kind})
        return 11
    end
    function cx:toast(level,text)table.insert(f.toasts,{level=level,text=text})end
    local api={plugin={id="todo"},json=tern.json,now=function()return 1 end,timer=function(_,fn)table.insert(f.timers,fn)end,process={run=function()error("no client-side native process lookup")end}}
    f.cx=cx;f.controller=attach.new(api)
    return f
end
return {
    {"selected native split delegates process resolution to host, with no client process call",function()
        local f=fixture();f.controller.start(f.cx,false)
        local source=tern.json.decode(f.blocks[1].args[1])
        assert(source.mode=="selected" and source.window=="window-9" and source.discover_pid==nil and source.path==nil)
        assert(f.blocks[1].opts.target==10 and f.blocks[1].opts.focus==false)
        f.timers[1](f.cx)
        assert(#f.events==1 and f.events[1].pane==11 and f.events[1].event.value==source.request)
    end},
    {"Files picker chooses agent; changing title/cwd never becomes a source identity",function()
        local f=fixture();f.controller.chooseSession(f.cx)
        assert(#f.picks==1 and #f.blocks==0)
        f.panes[1].title="New label";f.panes[1].cwd="/new"
        f.picks[1].cb(f.picks[1].opts.items[1],nil,f.cx)
        assert(f.focused==10 and #f.blocks==1)
    end},
    {"closed or switched selected target cannot confirm a new TODO block",function()
        local f=fixture();f.controller.chooseSession(f.cx);local choice=f.picks[1].opts.items[1];f.panes={};f.picks[1].cb(choice,nil,f.cx)
        assert(#f.blocks==0)
        local g=fixture();g.controller.start(g.cx,false);g.host.id=2;g.timers[1](g.cx)
        assert(#g.events==0 and g.closed[1]==11)
    end},
}
