-- Pure native-boundary contract fixtures; no process/provider is launched.
local root=...
assert(type(root)=='string','pass the package directory')
local runtime,environment=tern,getfenv()
local checks=0
local function check(ok,message) assert(ok,message);checks+=1 end
local source=runtime.fs.read(root..'/managed_route_window.luau')
local function fixture(backend)
 local f={starts=0,stops=0,closes=0,proofs=0,live=false,visible=true,source=1,clock=1000,timers={}}
 f.route={schema=1,nonce='setup-fixture-route',config_revision=7,window='',native_session=4,source_pane=1,backend=backend or 'native-agent',command="'omp' '--session-dir' '/private/setup-fixture-route-native'",cwd='/fixture/repo',prompt='exact "literal" \\ Ω\nbody',status='running',cleanup_pending=true}
 f.route.native_conn=1;f.route.native_since=100
 local fake={json=runtime.json,now=function()return f.clock end,timer=function(_,callback)table.insert(f.timers,callback)end}
 local bridge={read_node=function(_,pane)
  if f.visible and pane==f.source then return runtime.json.encode(f.route) end
  return nil
 end}
 f.cx={window_key=function()return '' end,toast=function()end,agents={},layout={},session={}}
 f.cx.agents.start=function(_,options)
  f.starts+=1;f.live=true
  if f.throw_start then error('Native start threw after a possible effect') end
  check(options.command==f.route.command and options.cwd==f.route.cwd and options.prompt==f.route.prompt,'native start preserves exact selected command/cwd/startup body')
  return 9
 end
 f.cx.agents.list=function()
  if not f.live or f.hidden or f.route.backend~='native-agent' then return {} end
  local entries={{pane=9,command=f.route.command,cwd=f.route.cwd,state='working'}}
  if f.ambiguous then table.insert(entries,{pane=10,command=f.route.command,cwd=f.route.cwd,state='working'}) end
  return entries
 end
 f.cx.agents.stop=function(_,pane)check(pane==9,'only positively owned agent is stopped');f.stops+=1;f.live=false end
 f.cx.layout.new_tab=function(_,options,placement)
  f.starts+=1;f.live=true
  check(options.command==f.route.command and options.cwd==f.route.cwd and placement.focus==false,'terminal diagnostic uses the actual native layout boundary without focus theft')
  return 9
 end
 f.cx.layout.close=function(_,pane)check(pane==9,'only positively owned terminal is closed');f.closes+=1;f.live=false end
 f.cx.session.pane=function(_,pane)
  if pane==f.source and f.visible then return {pane=pane,block='spawn.spawner',cwd=f.route.cwd} end
  if pane==9 and f.live and not f.hidden then return {pane=9,cwd=f.route.cwd} end
  return nil
 end
 f.cx.session.panes=function()return if f.visible then {{pane=f.source}} else {} end
 f.cx.session.event=function(_,pane,event)
  check(pane==f.source and f.visible,'results stay with the visible source Config')
  if event.act=='refresh' then f.route.discovery_complete=f.route.bound_pane~=nil;return end
  local input=runtime.json.decode(event.value)
  check(input.nonce==f.route.nonce and input.window=='','result preserves exact probe/native window fence')
  if event.act=='managed-route-preflight' then
   f.route.launch_ready={nonce=f.route.nonce,config_revision=f.route.config_revision,native_conn=f.route.native_conn,native_since=f.route.native_since}
  elseif event.act=='managed-route-started' then f.route.owned_pane=9;f.route.bound_pane=9;f.route.discovery_complete=true
  elseif event.act=='managed-route-observed' then f.proofs+=1;f.route.status='observed'
  elseif event.act=='managed-route-finished' then
   if input.cleaned~=true or f.route.bound_pane==nil then
    f.route.status='failed';f.route.error='Uncertain native start remains held';return
   end
   check(not f.live and input.pane==f.route.bound_pane,'host receives settlement only after positive bound-pane absence')
   f.route.cleanup_pending=false;f.route.status=if input.error then 'failed' else 'passed'
  else error('Unexpected route event') end
 end
 f.hooks={capture=function()return {session=4,host=0}end,member=function(_,_,pane)return (f.visible and pane==f.source) or (f.live and (pane==9 or (f.ambiguous and pane==10)))end,startup=function(_,pane,prompt)check(pane==9 and prompt==f.route.prompt,'native startup parser receives exact first-body contract');return true end}
 function f.load()
  local chunk=assert(loadstring(source,'managed_route_window'))
  setfenv(chunk,setmetatable({tern=fake,require=function(name)assert(name=='./dispatch_window');return bridge end},{__index=environment}))
  return chunk()
 end
 function f.step()
  assert(#f.timers>0,'expected pending native diagnostic callback')
  f.clock+=250;table.remove(f.timers,1)(f.cx)
 end
 function f.drain(limit)
  local turns=0
  while #f.timers>0 do
   turns+=1;assert(turns<=(limit or 400),'diagnostic fixture exceeded bounded callbacks')
   f.clock+=250;table.remove(f.timers,1)(f.cx)
  end
 end
 return f
end
for _,backend in ipairs({'native-agent','local-terminal'}) do
 local f=fixture(backend);local module=f.load()
 module.start(f.cx,1,6,f.hooks)
 check(f.starts==0,'stale expected revision never starts a native diagnostic')
 module.start(f.cx,1,7,f.hooks);module.start(f.cx,1,7,f.hooks);f.drain()
 check(f.starts==1 and f.proofs==1 and f.route.status=='passed' and not f.route.cleanup_pending,'one consent produces one observed and reaped native diagnostic: '..backend)
 check((backend=='native-agent' and f.stops==1 and f.closes==0) or (backend=='local-terminal' and f.closes==1 and f.stops==0),'correct native cleanup boundary is used')
end
local interrupted=fixture();interrupted.load().start(interrupted.cx,1,7,interrupted.hooks)
interrupted.step()
interrupted.timers={} -- VM reset discards local callbacks, not the authority obligation or native agent.
interrupted.load().reconcile(interrupted.cx,1,false,interrupted.hooks);interrupted.drain()
check(interrupted.starts==1 and interrupted.stops==1 and interrupted.proofs==0 and interrupted.route.status=='failed','VM reload discovers exact owned command and cleans up without replaying inference or claiming proof')
local closed=fixture();closed.load().start(closed.cx,1,7,closed.hooks)
closed.step()
closed.visible=false;closed.drain()
check(closed.stops==1 and closed.route.cleanup_pending,'closing Config still reaps its owned agent but preserves host cleanup obligation until readback')
closed.visible=true;closed.source=2;closed.load().reconcile(closed.cx,2,false,closed.hooks);closed.drain()
check(closed.starts==1 and not closed.route.cleanup_pending,'a replacement Config reconciles native absence without relaunch')
local ambiguous=fixture();ambiguous.load().start(ambiguous.cx,1,7,ambiguous.hooks)
ambiguous.step()
ambiguous.ambiguous=true;ambiguous.timers={}
ambiguous.load().reconcile(ambiguous.cx,1,false,ambiguous.hooks);ambiguous.drain()
check(ambiguous.stops==0 and ambiguous.route.cleanup_pending,'ambiguous command identity is a retained hold, never a broad kill or fabricated cleanup')
local blocked=fixture();blocked.route.cleanup_blocked=true
blocked.load().start(blocked.cx,1,7,blocked.hooks)
check(blocked.starts==0 and #blocked.timers==0,'late incarnation-blocked intent is refused before any native call')
local blockedDuringPreflight=fixture();blockedDuringPreflight.load().start(blockedDuringPreflight.cx,1,7,blockedDuringPreflight.hooks)
blockedDuringPreflight.route.cleanup_blocked=true;blockedDuringPreflight.drain()
check(blockedDuringPreflight.starts==0 and blockedDuringPreflight.route.cleanup_pending,'incarnation block arriving after consent/preflight still prevents the native effect')
local late=fixture();late.load().start(late.cx,1,7,late.hooks)
late.route.launch_ready.native_conn=2;late.drain()
check(late.starts==0 and late.route.cleanup_pending,'fresh preflight incarnation mismatch cannot launch or settle unbound ownership')
local uncertain=fixture();uncertain.throw_start=true;uncertain.hidden=true
uncertain.load().start(uncertain.cx,1,7,uncertain.hooks);uncertain.drain()
check(uncertain.starts==1 and uncertain.stops==0 and uncertain.route.cleanup_pending and uncertain.route.bound_pane==nil,'throw-after-possible-effect with empty visible inventory remains unbound and held')
local beforeBind=fixture();beforeBind.load().start(beforeBind.cx,1,7,beforeBind.hooks)
beforeBind.timers={}
beforeBind.load().reconcile(beforeBind.cx,1,false,beforeBind.hooks);beforeBind.drain()
check(beforeBind.starts==0 and beforeBind.route.cleanup_pending,'interruption before binding cannot turn empty inventory into completed cleanup')
local discovered=fixture();discovered.throw_start=true
discovered.load().start(discovered.cx,1,7,discovered.hooks);discovered.drain()
check(discovered.starts==1 and discovered.stops==1 and discovered.route.bound_pane==9 and not discovered.route.cleanup_pending,'uncertain start is positively bound before its discovered owned agent is stopped')
return 'PASS managed_route '..tostring(checks)
