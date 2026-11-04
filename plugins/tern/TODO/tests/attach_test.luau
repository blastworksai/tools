-- Native selection/process routing only; no provider messages or operator plan prompt.
local attach=require("../lib/attach")
local function fixture()
    local f={calls={},picks={},blocks={},toasts={},panes={{pane=10,tab=20,kind="terminal",program="bash",title="CodexBWAI",cwd="/work"}}}
    f.host={id=1,name="VM",address="cmdr@vm",state="connected",kind="remote",panes={10}}
    local cx={session={},hosts={},layout={}}
    function cx.session:focused() return 10 end
    function cx.session:pane(id) for _,p in f.panes do if p.pane==id then return p end end end
    function cx.session:panes() return f.panes end
    function cx.session:sessions() return {{name="Interactive",tabs={20,21}}} end
    function cx.hosts:current() return f.host end
    function cx.hosts:list() return {f.host} end
    function cx.hosts:switch(id) assert(id==f.host.id) end
    function cx.layout:focus(id) f.focused=id end
    function cx:window_key() return "window-9" end
    function cx:prompt() error("no operator plan prompt") end
    function cx:run() error("no agent or shell input") end
    function cx:pick(opts) return {next=function(_,cb)table.insert(f.picks,{opts=opts,cb=cb})end} end
    function cx:new_block(kind,args,how,opts) table.insert(f.blocks,{kind=kind,args=args,opts=opts}) end
    function cx:toast(level,text)table.insert(f.toasts,{level=level,text=text})end
    local api={plugin={id="todo"},json=tern.json,runtime={os="linux"},getenv=function()return nil end,process={}}
    function api.process.run(argv,opts,cb)table.insert(f.calls,{argv=argv,cb=cb})end
    function f.reply(pane,pid) f.calls[#f.calls].cb({status=0,stdout=tern.json.encode({pane=pane,child={pid=pid}})},cx) end
    f.cx=cx;f.controller=attach.new(api)
    return f
end
return {
    {"selected native execution host resolves publication there, never on client or agent input",function()
        local f=fixture();f.controller.start(f.cx,false)
        assert(f.calls[1].argv[2]=="process" and f.calls[1].argv[5]=="window-9")
        f.reply(10,123)
        local source=tern.json.decode(f.blocks[1].args[1])
        assert(source.discover_pid==123 and source.path==nil and source.label=="SSH · cmdr@vm")
        assert(f.blocks[1].opts.target==10)
    end},
    {"Files button chooses the session before reading native metadata; changing labels is safe",function()
        local f=fixture();f.controller.chooseSession(f.cx)
        assert(#f.picks==1 and #f.calls==0 and #f.blocks==0)
        f.panes[1].title="New label";f.panes[1].cwd="/new"
        f.picks[1].cb(f.picks[1].opts.items[1],nil,f.cx);f.reply(10,123)
        assert(f.focused==10 and #f.blocks==1)
    end},
    {"closed or switched targets and mismatched native replies never open a TODO pane",function()
        local f=fixture();f.controller.chooseSession(f.cx);local choice=f.picks[1].opts.items[1];f.panes={};f.picks[1].cb(choice,nil,f.cx)
        assert(#f.calls==0 and #f.blocks==0)
        local g=fixture();g.controller.start(g.cx,false);g.host.id=2;g.reply(10,123)
        assert(#g.blocks==0)
        local h=fixture();h.controller.start(h.cx,false);h.reply(11,123)
        assert(#h.blocks==0)
    end},
}
