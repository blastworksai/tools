local attach=require("../lib/attach")
local function fixture(remote)
    local f={calls={},prompts={},picks={},blocks={},toasts={}}
    local pane={pane=10,tab=20,kind="agent",program="codex"}
    local host={id=1,name="VM",address="cmdr@vm",state="connected",kind=if remote then "remote" else "local"}
    local cx={session={},hosts={}}
    function cx.session:focused() return 10 end
    function cx.session:pane(id) return if id==10 then pane else nil end
    function cx.session:panes() return {pane} end
    function cx.hosts:current() return host end
    function cx:window_key() return "window-9" end
    function cx:prompt(opts) return {next=function(_,cb)table.insert(f.prompts,{opts=opts,cb=cb})end} end
    function cx:pick(opts) return {next=function(_,cb)table.insert(f.picks,{opts=opts,cb=cb})end} end
    function cx:new_block(kind,args) table.insert(f.blocks,{kind=kind,source=tern.json.decode(args[1])}) end
    function cx:toast(level,text)table.insert(f.toasts,{level=level,text=text})end
    local api={plugin={id="todo"},json=tern.json,runtime={os="linux"},getenv=function()return nil end,process={}}
    function api.process.run(argv,opts,cb)table.insert(f.calls,{argv=argv,opts=opts,cb=cb})end
    function f.reply(index,argv,pid)
        local p={pane=10,child={pid=pid,argv=argv},foreground={pid=pid,argv=argv}}
        f.calls[index].cb({status=0,stdout=tern.json.encode(p)},cx)
    end
    f.cx=cx;f.host=host;f.controller=attach.new(api)
    return f
end
return {
    {"native remote attachment skips source chooser and never starts SSH",function()
        local f=fixture(true);f.controller.start(f.cx,false)
        assert(#f.calls==0 and #f.picks==0 and #f.prompts==1)
        f.prompts[1].cb("/plans/current.md",nil,f.cx)
        assert(#f.blocks==1 and f.blocks[1].source.path=="/plans/current.md" and f.blocks[1].source.ssh==nil)
        assert(f.blocks[1].source.label=="Remote Tern host cmdr@vm")
    end},
    {"ordinary SSH metadata is prefilled without executing its remote command",function()
        local f=fixture(false);f.controller.start(f.cx,false)
        assert(f.calls[1].argv[2]=="process" and f.calls[1].argv[3]=="10" and f.calls[1].argv[5]=="window-9")
        local argv={"ssh","agent@work-host","do-not-replay-this-command"};f.reply(1,argv,100)
        assert(#f.picks==1 and f.picks[1].opts.placeholder=="Detected SSH agent@work-host")
        f.picks[1].cb(f.picks[1].opts.items[1],nil,f.cx);f.prompts[1].cb("/plans/active.md",nil,f.cx);f.reply(2,argv,100)
        assert(#f.blocks==1 and f.blocks[1].source.ssh=="agent@work-host" and #f.calls==2)
    end},
    {"connection changes during path entry cannot bind the old route",function()
        local f=fixture(false);f.controller.start(f.cx,false);f.reply(1,{"codex"},100)
        f.prompts[1].cb("/plans/active.md",nil,f.cx);f.reply(2,{"ssh","new-host"},101)
        assert(#f.blocks==0 and #f.toasts==1)
        local g=fixture(true);g.controller.start(g.cx,false);g.host.id=2;g.prompts[1].cb("/plans/active.md",nil,g.cx)
        assert(#g.blocks==0 and #g.toasts==1)
    end},
}
