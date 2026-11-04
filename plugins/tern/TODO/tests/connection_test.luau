local connection=require("../lib/connection")
local host={id=1,name="Desktop",kind="local",state="connected"}
local function process(argv)
    return {pane=10,child={pid=100,argv=argv},foreground={pid=100,argv=argv}}
end
return {
    {"native execution host wins over connecting desktop identity",function()
        local remote={id=2,name="VM",address="cmdr@vm",kind="remote",state="connected",identity={hops={{host="ODIN",method="ssh-key"}}}}
        local r=connection.detect(remote,{program="codex"},nil)
        assert(r.kind=="host" and r.label=="Remote Tern host cmdr@vm")
        assert(connection.detect(host,{},process({"/usr/bin/codex"})).kind=="host")
        assert(connection.detect(host,{},nil).kind=="manual")
    end},
    {"SSH destination is metadata and unsupported options require another alias",function()
        local r=connection.detect(host,{},process({"/usr/bin/ssh","-tt","-l","agent","work-host","codex --model anything"}))
        assert(r.kind=="ssh" and r.ssh=="agent@work-host" and not r.needs_alias)
        local port=connection.ssh({"ssh","-p2222","work-host"})
        assert(port.label=="work-host:2222" and port.needs_alias)
        assert(connection.ssh({"ssh","seat-codexbwai"}).needs_alias and connection.ssh({"ssh","-i","/private/key","work-host"}).needs_alias)
    end},
    {"opaque transports and malformed SSH never silently become local",function()
        assert(connection.detect(host,{},process({"powershell.exe","-File","launch.ps1"})).kind=="manual")
        assert(connection.detect(host,{},process({"wsl.exe"})).kind=="manual")
        for _,program in {"mosh-client","tailscale","autossh","sshpass","et","kubectl","unknown-agent-wrapper"} do
            assert(connection.detect(host,{},process({program})).kind=="manual",program)
        end
        assert(connection.ssh({"ssh","-oProxyCommand=do-not-execute","-Ex@host"}).kind=="manual")
    end},
}
