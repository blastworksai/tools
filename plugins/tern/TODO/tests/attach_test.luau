local attach=require("../lib/attach")
local function fixture()
    local f={calls={},picks={},blocks={},toasts={},timers={},asks={},time=1000}
    f.panes={{pane=10,tab=20,kind="agent",program="codex",title="CodexBWAI",cwd="/work"}}
    f.host={id=1,name="VM",address="cmdr@vm",state="connected",kind="remote",panes={10}}
    f.agents={{pane=10,state="idle"}}
    local cx={session={},hosts={},layout={},agents={}}
    function cx.session:focused() return 10 end
    function cx.session:pane(id) for _,p in f.panes do if p.pane==id then return p end end return nil end
    function cx.session:panes() return f.panes end
    function cx.session:sessions() return {{name="Interactive",tabs={20,21}}} end
    function cx.hosts:current() return f.host end
    function cx.hosts:list() return {f.host} end
    function cx.hosts:switch(id) assert(id==f.host.id) end
    function cx.layout:focus(id) f.focused=id end
    function cx:window_key() return "window-9" end
    function cx:prompt() error("TODO must not ask the operator for a plan") end
    function cx:pick(opts) return {next=function(_,cb)table.insert(f.picks,{opts=opts,cb=cb})end} end
    function cx:new_block(kind,args) table.insert(f.blocks,{kind=kind,source=tern.json.decode(args[1]),plan_id=args[2]}) end
    function cx:toast(level,text)table.insert(f.toasts,{level=level,text=text})end
    function cx.agents:list() return f.agents end
    function cx.agents:ask(id,text)table.insert(f.asks,{target=id,text=text})end
    function cx:run(id,text)table.insert(f.asks,{target=id,text=text})end
    function cx.session:read() return f.text end
    local api={plugin={id="todo"},json=tern.json,runtime={os="linux"},getenv=function()return nil end,process={}}
    function api.now() return f.time end
    function api.timer(_,cb)table.insert(f.timers,cb)end
    function api.process.run(argv,opts,cb)table.insert(f.calls,{argv=argv,opts=opts,cb=cb})end
    function f.respond(state)
        local id=f.asks[1].text:match("request_id=([^%. ]+)")
        f.text="TODO_PLAN_REPLY v1 "..tern.json.encode({request_id=id,state=state,path="/plans/current.md",plan_id="plan-abcdef123456"})
        f.agents[1].last_message=f.text
        table.remove(f.timers,1)(cx)
    end
    f.cx=cx;f.controller=attach.new(api)
    return f
end
return {
    {"raw SSH metadata cannot silently reuse an unverified agent-launch key",function()
        local f=fixture();f.host.kind="local";f.controller.start(f.cx,false)
        assert(#f.calls==1)
        local metadata={pane=10,child={pid=100,argv={"ssh","agent-host"}},foreground={pid=100,argv={"ssh","agent-host"}}}
        f.calls[1].cb({status=0,stdout=tern.json.encode(metadata)},f.cx)
        assert(#f.asks==0 and #f.blocks==0 and #f.toasts==1)
        assert(f.toasts[1].text:find("verified file-reading route",1,true))
    end},
    {"a generic terminal without native agent communication receives no input",function()
        local f=fixture();f.agents={};f.panes[1].kind="terminal";f.panes[1].at_prompt=true
        f.controller.start(f.cx,false)
        assert(#f.asks==0 and #f.blocks==0 and #f.toasts==1)
        assert(f.toasts[1].text:find("native agent communication endpoint",1,true))
    end},
    {"native plan query binds the exact reported source and id without operator prompt",function()
        local f=fixture();f.controller.start(f.cx,false)
        assert(#f.asks==1 and #f.blocks==0 and #f.picks==0 and #f.calls==0)
        f.respond("active")
        assert(#f.blocks==1 and f.blocks[1].source.path=="/plans/current.md" and f.blocks[1].plan_id=="plan-abcdef123456")
    end},
    {"no-plan reply exits TODO without opening or closing a pane",function()
        local f=fixture();f.controller.start(f.cx,false);f.respond("none")
        assert(#f.blocks==0 and #f.toasts==1 and f.toasts[1].text:find("not working on a plan",1,true))
        assert(#f.asks==1 and #f.panes==1)
    end},
    {"busy, timeout and changed-session failures never invent a no-plan result",function()
        local f=fixture();f.agents[1].state="working";f.controller.start(f.cx,false)
        assert(#f.asks==0 and #f.blocks==0 and #f.toasts==1)
        local g=fixture();g.controller.start(g.cx,false);g.time=62000;table.remove(g.timers,1)(g.cx)
        assert(#g.blocks==0 and g.toasts[1].text:find("timeout",1,true))
        local h=fixture();h.controller.start(h.cx,false);h.host.id=2;h.respond("active")
        assert(#h.blocks==0 and h.toasts[1].text:find("changed",1,true))
    end},
    {"Files button selects a CLI session across tabs before querying",function()
        local f=fixture()
        table.insert(f.panes,{pane=11,tab=21,kind="terminal",program="claude",title="ClaudeBWAI",cwd="/work",at_prompt=true})
        table.insert(f.panes,{pane=12,tab=30,kind="plugin",block="todo.list"})
        table.insert(f.panes,{pane=13,tab=21,kind="agent",exited=0})
        table.insert(f.agents,{pane=11,state="idle"})
        f.host.panes={10,11,12,13};f.controller.chooseSession(f.cx)
        assert(#f.picks==1 and #f.picks[1].opts.items==2 and #f.asks==0)
        local chosen=nil
        for _,item in f.picks[1].opts.items do if item.target==11 then chosen=item end end
        assert(chosen and chosen.detail:find("Interactive",1,true))
        f.picks[1].cb(chosen,nil,f.cx)
        assert(f.focused==11 and #f.asks==1 and f.asks[1].target==11)
        assert(f.asks[1].text:sub(1,1)=="#")
    end},
    {"session picker rejects disappeared or disconnected targets and supports cancellation",function()
        local f=fixture();f.controller.chooseSession(f.cx)
        local choice=f.picks[1].opts.items[1];f.panes={};f.picks[1].cb(choice,nil,f.cx)
        assert(#f.asks==0 and #f.toasts==1)
        local g=fixture();g.controller.chooseSession(g.cx);g.host.state="reconnecting"
        g.picks[1].cb(g.picks[1].opts.items[1],nil,g.cx);assert(#g.asks==0 and #g.toasts==1)
        local h=fixture();h.controller.chooseSession(h.cx);h.picks[1].cb(nil,nil,h.cx)
        assert(#h.asks==0 and #h.toasts==0)
    end},
}
