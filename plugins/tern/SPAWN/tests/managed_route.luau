-- Pure native-boundary contract fixtures; no process/provider is launched.
local root=...
assert(type(root)=='string','pass the package directory')
local runtime,environment=tern,getfenv()
local checks=0
local function check(ok,message) assert(ok,message);checks+=1 end
local source=runtime.fs.read(root..'/managed_route_window.luau')
local function fixture(backend)
 local f={starts=0,stops=0,closes=0,proofs=0,consents=0,ensures=0,live=false,visible=true,source=1,clock=1000,timers={},events={},published=false}
 f.recipient={namespace='alpha-desktop',window_key='',conn=11,since=100}
 f.route={schema=1,nonce='setup-fixture-route',config_revision=7,window='',native_session=404,source_pane=501,backend=backend or 'native-agent',command="'omp' '--session-dir' '/private/setup-fixture-route-native'",cwd='/fixture/repo',prompt='exact "literal" \\ Ω\nbody',status='running',cleanup_pending=true,native_namespace='alpha-desktop',native_conn=11,native_since=100}
 local fake=setmetatable({json=runtime.json,now=function()return f.clock end,timer=function(_,callback)table.insert(f.timers,callback)end},{__index=runtime})
 local bridge={read_node=function(_,pane,_block,key)
  if key=='spawn-managed-prepare' then return if f.prepare and not f.hide_manifest and f.visible and pane==f.source then runtime.json.encode(f.prepare) else nil end
  if f.published and f.visible and pane==f.source then return runtime.json.encode(f.route) end
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
  local entries={{pane=9,command=f.route.command,cwd=f.display_cwd or f.route.cwd,state='working'}}
  if f.ambiguous then table.insert(entries,{pane=10,command=f.route.command,cwd=f.route.cwd,state='working'}) end
  return entries
 end
 f.cx.agents.stop=function(_,pane)check(pane==9,'only positively owned SDK agent is stopped, never HOST pane 509');f.stops+=1;f.live=false end
 f.cx.layout.new_tab=function(_,options,placement)
  f.starts+=1;f.live=true
  check(options.command==f.route.command and options.cwd==f.route.cwd and placement.focus==false,'terminal diagnostic uses the native layout boundary without focus theft')
  return 9
 end
 f.cx.layout.close=function(_,pane)check(pane==9,'only positively owned SDK terminal is closed, never HOST pane 509');f.closes+=1;f.live=false end
 f.cx.session.pane=function(_,pane)
  if pane==f.source and f.visible then return {pane=pane,block='spawn.spawner',cwd=f.route.cwd} end
  if pane==9 and f.live and not f.hidden then return {pane=9,cwd=f.display_cwd or f.route.cwd} end
  return nil
 end
 f.cx.session.panes=function()return if f.visible then {{pane=f.source}} else {} end
 f.cx.session.event=function(_,pane,event)
  check(pane==f.source and f.visible,'results target the visible SDK source, never URL HOST pane 501')
  if event.act=='managed-prepare-consent' or event.act=='managed-reviewed-prepare' then
   local input=runtime.json.decode(event.value)
   check(input.nonce==f.prepare.nonce and input.config_revision==f.prepare.revision and #input.consents==#f.prepare.entries,'combined approval captures the exact rendered preparation manifest')
   if event.act=='managed-reviewed-prepare' then f.reviewed_reference=input.reviewed end
   f.consents+=1;f.tokens=input.consents;f.prepare.status='preparing'
   for index,entry in ipairs(f.prepare.entries) do check(input.consents[index].nonce==entry.nonce,'each approved record has its own exact nonce') end
   f.route.nonce=f.prepare.entries[1].nonce;f.route.config_revision=f.prepare.entries[1].revision;f.route.record_id=f.prepare.entries[1].record_id;f.route.backend=f.prepare.entries[1].backend;f.route.window_consent=input.consents[1].window_consent
   f.published=not f.defer_publish
   return
  elseif event.act=='managed-prepare-next' then
   local input=runtime.json.decode(event.value)
   local index=(f.nexts or 0)+1;local entry=f.prepare.entries[index]
   check(f.route.status=='passed' and f.route.cleanup_pending==false and not f.live,'next record is not authorized before positive owned cleanup of its predecessor')
   check(input.nonce==entry.nonce and input.window_consent==f.tokens[index].window_consent,'next step echoes only that record native-window approval')
   f.nexts=index
   local following=f.prepare.entries[index+1]
   if following then
    local nextRoute=table.clone(f.route)
    nextRoute.nonce=following.nonce;nextRoute.config_revision=following.revision;nextRoute.record_id=following.record_id;nextRoute.backend=following.backend;nextRoute.window_consent=f.tokens[index+1].window_consent
    nextRoute.command='offline-or-native '..following.nonce;nextRoute.status='running';nextRoute.cleanup_pending=true
    nextRoute.bound_pane=nil;nextRoute.owned_pane=nil;nextRoute.bound_window_pane=nil;nextRoute.discovery_complete=nil;nextRoute.launch_ready=nil
    if f.defer_following then f.published=false end
    f.route=nextRoute
   else f.prepare.status='completed' end
   return
  end
  if event.act=='refresh' then
   if f.delayed_host_discovery and f.live then f.route.owned_pane=509;f.route.bound_pane=509 end
   f.route.discovery_complete=f.route.bound_pane~=nil;return
  end
  local input=runtime.json.decode(event.value)
  table.insert(f.events,{act=event.act,input=input,pane=pane})
  check(input.nonce==f.route.nonce and input.window=='','result preserves exact probe/window fence')
  check(input.native_namespace==f.recipient.namespace and input.native_conn==f.recipient.conn and input.native_since==f.recipient.since,'every callback carries the local desktop recipient tuple')
  if event.act=='managed-route-consent' then
   f.consents+=1
   check(type(input.config_revision)=='number','directed consent carries a numeric requested revision')
   check(type(input.window_consent)=='string' and input.window_consent~='','directed consent supplies a fresh window handshake token')
   f.last_consent_token=input.window_consent
   if f.reject_consent then return end
   f.route.window_consent=input.window_consent
   if not f.defer_publish then f.published=true end
  elseif event.act=='managed-route-preflight' then
   f.route.launch_ready={nonce=f.route.nonce,config_revision=f.route.config_revision,native_namespace=f.route.native_namespace,native_conn=f.route.native_conn,native_since=f.route.native_since}
  elseif event.act=='managed-route-started' then
   check(input.pane==9,'started callback reports SDK identity independently of host discovery')
   if f.delayed_host_discovery and f.route.owned_pane==nil then return end
   f.route.owned_pane=509;f.route.bound_pane=509;f.route.bound_window_pane=9;f.route.discovery_complete=true
  elseif event.act=='managed-route-observed' then f.proofs+=1;f.route.status='observed'
  elseif event.act=='managed-route-finished' then
   if input.cleaned~=true or f.route.bound_pane==nil then
    f.route.status='failed';f.route.error='Uncertain native start remains held';return
   end
   check(not f.live and input.pane==f.route.bound_window_pane,'settlement echoes bound SDK pane after absence, not bound native pane')
   f.route.cleanup_pending=false;f.route.status=if input.error then 'failed' else 'passed'
  else error('Unexpected route event: '..tostring(event.act)) end
 end
 f.hooks={
  ensure=function(cx,callback)
   f.ensures+=1
   if f.defer_ensure then f.ensured=function()callback(cx)end else callback(cx) end
  end,
  recipient=function()return f.recipient end,
  capture=function()return {session=4,host=0}end,
  member=function(_,origin,pane)
   check(origin.session==4 and origin.host==0,'membership uses captured SDK origin, not native host session 404')
   return (f.visible and pane==f.source) or (f.live and (pane==9 or (f.ambiguous and pane==10)))
  end,
  startup=function(_,pane,prompt)check(pane==9 and prompt==f.route.prompt,'startup parser receives SDK pane and exact first-body contract');return true end,
 }
 function f.load()
  local chunk=assert(loadstring(source,'managed_route_window'))
  setfenv(chunk,setmetatable({tern=fake,require=function(name)assert(name=='./dispatch_window');return bridge end},{__index=environment}))
  return chunk()
 end
 function f.link(nonce,host,revision)
  return {pane=f.source,url='tern-spawn://managed-route/'..tostring(host or 501)..'/'..tostring(revision or 7)..'/'..(nonce or f.route.nonce)}
 end
 function f.consent(module) module.consent(f.cx,f.link(),f.hooks) end
 function f.step()
  assert(#f.timers>0,'expected pending native diagnostic callback')
  f.clock+=250;table.remove(f.timers,1)(f.cx)
 end
 function f.until_started()
  local turns=0
  while f.starts==0 and #f.timers>0 do turns+=1;assert(turns<20,'launch did not advance');f.step() end
  check(f.starts==1,'directed consent reaches exactly one native launch')
 end
 function f.drain(limit)
  local turns=0
  while #f.timers>0 do
   turns+=1;assert(turns<=(limit or 400),'diagnostic fixture exceeded bounded callbacks')
   f.step()
  end
 end
 return f
end
local function preparation_fixture(backends)
 local f=fixture(backends[1])
 f.prepare={schema=1,nonce='prepare-fixture',revision=7,status='awaiting_consent',window='',entries={}}
 for index,backend in ipairs(backends) do table.insert(f.prepare.entries,{nonce='record-diagnostic-'..tostring(index),record_id='saved-account-'..tostring(index),label='Account '..tostring(index),backend=backend,revision=6+index}) end
 function f.approve(module)
  module.consent(f.cx,{pane=f.source,url='tern-spawn://managed-prepare/501/7/prepare-fixture'},f.hooks)
 end
 return f
end
do
 local delayed=preparation_fixture({'local-terminal'});delayed.hide_manifest=true
 local module=delayed.load();delayed.approve(module);delayed.approve(module)
 check(delayed.starts==0 and delayed.consents==0,'a native click preceding the published host manifest starts no work before its exact handoff')
 delayed.clock+=5000;delayed.hide_manifest=false;delayed.drain()
 check(delayed.consents==1 and delayed.starts==1 and delayed.proofs==1 and delayed.prepare.status=='completed','delayed exact manifest publication completes the original one-action approval without another click')
 delayed.approve(module)
 check(delayed.consents==1 and delayed.starts==1,'a repeated link cannot replay a completed delayed handoff')
 for _,change in ipairs({'source','recipient','expiry','revision'})do
  local guarded=preparation_fixture({'native-agent'});guarded.hide_manifest=true
  local driver=guarded.load();guarded.approve(driver)
  if change=='source' then guarded.hooks.capture=function()return {session=5,host=0}end
  elseif change=='recipient' then guarded.recipient.conn+=1
  elseif change=='expiry' then guarded.clock+=30001
  else guarded.prepare.revision+=1 end
  guarded.hide_manifest=false;guarded.drain();guarded.approve(driver)
  check(guarded.starts==0 and guarded.consents==0 and guarded.proofs==0,'delayed publication cannot retarget or renew an expired/changed clicked approval: '..change)
 end
 local function first_complete(f)
  local turns=0
  while f.nexts~=1 do turns+=1;assert(turns<40,'first account did not positively settle before the next preparation');f.step() end
 end
 local serial=preparation_fixture({'local-terminal','native-agent'});serial.defer_publish=true;serial.defer_following=true
 local serialModule=serial.load();serial.approve(serialModule)
 serial.clock+=120000;serial.published=true
 first_complete(serial)
 serial.clock+=120000;serial.published=true;serial.drain()
 check(serial.starts==2 and serial.proofs==2 and serial.consents==1 and serial.prepare.status=='completed','serial accounts each get their bounded resource phase even when total preparation exceeds one phase, without replaying or replacing the original account consents')
 local refreshed=preparation_fixture({'local-terminal','native-agent'});refreshed.defer_following=true
 local refreshedModule=refreshed.load();refreshed.approve(refreshedModule)
 first_complete(refreshed)
 local ensure=refreshed.hooks.ensure
 refreshed.hooks.ensure=function(cx,callback)ensure(cx,function(fresh,err)refreshed.recipient.conn+=1;callback(fresh,err)end)end
 refreshed.clock+=60000;refreshed.published=true;refreshed.drain()
 check(refreshed.starts==1 and refreshed.proofs==1 and refreshed.consents==1,'fresh native identity before a later serial entry refuses a changed recipient instead of reusing its original cost consent')
 local slow=preparation_fixture({'native-agent'});slow.defer_publish=true
 local slowModule=slow.load();slow.approve(slowModule);slow.clock+=120000;slow.published=true;slow.until_started()
 slow.clock+=45001;slow.drain()
 check(slow.starts==1 and slow.stops==1 and slow.proofs==0 and slow.route.status=='failed','long resource preparation never extends the actual native diagnostic beyond its independent 45-second observation bound')
end
local batch=preparation_fixture({'local-terminal','native-agent'})
local batchModule=batch.load();batch.approve(batchModule);batch.drain()
check(batch.consents==1 and batch.starts==2 and batch.proofs==2 and batch.closes==1 and batch.stops==1 and batch.nexts==2 and batch.prepare.status=='completed','one native click completes separate offline/native account checks with positive cleanup before each exact next step')
check(batch.tokens[1].window_consent~=batch.tokens[2].window_consent,'batch records never share a native diagnostic consent token')
batch.approve(batchModule);batchModule.reconcile(batch.cx,batch.source,false,batch.hooks);batch.drain()
check(batch.starts==2 and batch.consents==1,'repeated combined approval does not replay completed per-account model turns')
local resourceWait=preparation_fixture({'local-terminal'});resourceWait.defer_publish=true
local resourceModule=resourceWait.load();resourceWait.approve(resourceModule)
resourceWait.clock+=60000;resourceWait.step()
check(resourceWait.starts==0 and resourceWait.consents==1,'bounded resource preparation can outlast the old consent wait without starting a diagnostic')
resourceWait.published=true;resourceWait.drain()
check(resourceWait.starts==1 and resourceWait.proofs==1 and resourceWait.prepare.status=='completed','prepared resources release the same exact once-only diagnostic without another human click')
local edited=preparation_fixture({'native-agent'});edited.defer_publish=true
local editedModule=edited.load();edited.approve(editedModule)
edited.prepare.entries[1].record_id='different-account';edited.published=true;edited.drain()
check(edited.starts==0 and edited.consents==1,'changing a pending account invalidates its paid native approval rather than applying consent to a replacement')
local failedPreparation=preparation_fixture({'native-agent'});failedPreparation.defer_publish=true
local failedModule=failedPreparation.load();failedPreparation.approve(failedModule)
failedPreparation.prepare.status='failed';failedPreparation.drain()
check(failedPreparation.starts==0 and failedPreparation.proofs==0,'resource failure never becomes a model diagnostic or a passed check')
local expiredPreparation=preparation_fixture({'native-agent'});expiredPreparation.defer_publish=true
local expiredModule=expiredPreparation.load();expiredPreparation.approve(expiredModule)
expiredPreparation.clock+=180001;expiredPreparation.drain()
check(expiredPreparation.starts==0,'preparation wait is finite and cannot later release an expired paid model diagnostic')
local interruptedBatch=preparation_fixture({'native-agent','native-agent'})
local beforeReload=interruptedBatch.load();interruptedBatch.approve(beforeReload);interruptedBatch.until_started()
interruptedBatch.timers={}
local afterReload=interruptedBatch.load();interruptedBatch.approve(afterReload);afterReload.reconcile(interruptedBatch.cx,interruptedBatch.source,false,interruptedBatch.hooks);interruptedBatch.drain()
check(interruptedBatch.starts==1 and interruptedBatch.stops==1 and interruptedBatch.nexts==nil and interruptedBatch.proofs==0,'reload only cleans the positively owned interrupted diagnostic; it never reuses batch approval for another account')
do
 local f=fixture('local-terminal');local module=f.load()
 local captured=assert(module.capture_reviewed(f.cx,f.source,501,{
  {id='terminal-account',provider='custom',account_label='Terminal account',backend='local-terminal',enabled=true},
  {id='native-account',provider='omp',account_label='Native account',backend='native-agent',enabled=true},
 },7,false,f.hooks))
 local approved=assert(module.reviewed_payload(captured))
 check(f.starts==0 and f.consents==0 and approved.entries[1].record_id=='terminal-account' and approved.entries[2].record_id=='native-account','capturing one final native decision binds the exact reviewed accounts without starting resources or diagnostics')
 check(approved.entries[1].nonce~=approved.entries[2].nonce and approved.consents[1].window_consent~=approved.consents[2].window_consent,'final approval discloses per-account native cost scope with distinct immutable diagnostic nonces and consent tokens')
 f.prepare=runtime.json.decode(runtime.json.encode(captured.manifest))
 local reference={setup_run_id='guided-fixture',attempt_id='actual-setup-attempt',pending_digest=string.rep('a',64),import_request_id='actual-durable-import'}
 check(module.start_reviewed(f.cx,captured,reference,f.hooks),'a real saved-settings callback can resume its captured final approval')
 f.drain()
 check(f.reviewed_reference.import_request_id==reference.import_request_id and f.tokens[1].window_consent==approved.consents[1].window_consent and f.tokens[2].window_consent==approved.consents[2].window_consent,'preparation reuses the original receipt reference and exact account consents, never newly minted or shared model permission')
 check(f.starts==2 and f.proofs==2 and f.prepare.status=='completed','one combined final decision completes offline and native checks only through each real once-only diagnostic and positive cleanup')
 check(not module.start_reviewed(f.cx,captured,reference,f.hooks) and f.starts==2,'completed final approval cannot replay either account')
 for _,change in ipairs({'recipient','expiry','cancel'})do
  local guarded=fixture('native-agent');local driver=guarded.load()
  local approval=assert(driver.capture_reviewed(guarded.cx,guarded.source,501,{{id='native',provider='omp',account_label='Paid model',backend='native-agent',enabled=true}},7,false,guarded.hooks))
  if change=='recipient' then guarded.recipient.conn+=1 elseif change=='expiry' then guarded.clock+=30001 else driver.cancel_reviewed(approval) end
  check(not driver.start_reviewed(guarded.cx,approval,reference,guarded.hooks) and guarded.starts==0 and guarded.consents==0,'changed recipient, expired approval or explicit cancellation cannot turn a saved receipt into model consent: '..change)
 end
end
for _,backend in ipairs({'native-agent','local-terminal'}) do
 local f=fixture(backend);local module=f.load()
 f.defer_ensure=true
 f.consent(module)
 check(f.ensures==1 and f.consents==0 and f.starts==0,'directed consent waits for local recipient registration')
 f.defer_ensure=false;f.ensured()
 f.consent(module);f.drain()
 check(f.consents==1 and f.starts==1 and f.proofs==1 and f.route.status=='passed' and not f.route.cleanup_pending,'one directed nonce produces one observed/reaped diagnostic: '..backend)
 check(f.events[1].act=='managed-route-consent' and f.events[1].input.config_revision==7 and f.events[1].pane==1,'directed request uses URL revision but targets SDK source')
 check(f.route.bound_pane==509 and f.route.bound_window_pane==9,'native and SDK diagnostic bindings remain distinct')
 check((backend=='native-agent' and f.stops==1 and f.closes==0) or (backend=='local-terminal' and f.closes==1 and f.stops==0),'correct SDK cleanup boundary is used')
 f.consent(module);module.reconcile(f.cx,f.source,false,f.hooks);f.drain()
 check(f.starts==1 and f.proofs==1,'repeated directed link and callbacks cannot replay completed consent')
end
local delayedTerminal=fixture('local-terminal');delayedTerminal.delayed_host_discovery=true
local delayedModule=delayedTerminal.load();delayedTerminal.consent(delayedModule);delayedTerminal.drain()
check(delayedTerminal.starts==1 and delayedTerminal.proofs==1 and delayedTerminal.closes==1 and delayedTerminal.route.status=='passed','late HOST discovery binds the original SDK terminal without retrying launch or leaving cleanup stuck')
for _,backend in ipairs({'native-agent','local-terminal'}) do
 local remote=fixture(backend);remote.display_cwd='\\fixture\\repo'
 remote.consent(remote.load());remote.drain()
 check(remote.starts==1 and remote.proofs==1 and remote.route.status=='passed' and not remote.live,'Windows display separators do not override exact HOST cwd ownership: '..backend)
end
local waiting=fixture();waiting.defer_publish=true
local waitingModule=waiting.load();waiting.consent(waitingModule)
waiting.route.nonce='another-route';waiting.published=true
waiting.step()
check(waiting.starts==0,'pending directed consent does not launch a different published nonce')
waiting.route.nonce='setup-fixture-route';waiting.drain()
check(waiting.starts==1 and waiting.proofs==1,'matching route publication releases the pending directed consent once')
local wrongHost=fixture();local wrongHostModule=wrongHost.load()
wrongHostModule.consent(wrongHost.cx,wrongHost.link(nil,999),wrongHost.hooks);wrongHost.drain()
check(wrongHost.starts==0,'URL host pane must match durable native source identity, not SDK source')
local stale=fixture();local staleModule=stale.load()
staleModule.consent(stale.cx,stale.link(nil,nil,6),stale.hooks);stale.drain()
check(stale.starts==0,'stale directed revision cannot launch the current route')
for _,backend in ipairs({'native-agent','local-terminal'}) do
 for _,field in ipairs({'namespace','conn','since'}) do
  local other=fixture(backend);other.published=true;other.live=true
  other.route.bound_pane=509;other.route.owned_pane=509;other.route.bound_window_pane=9
  other.recipient[field]=if field=='namespace' then 'beta-desktop' else 999
  local foreign=fixture(backend);foreign.recipient[field]=other.recipient[field]
  foreign.consent(foreign.load());foreign.drain()
  check(foreign.starts==0 and foreign.stops==0 and foreign.closes==0 and foreign.route.cleanup_pending,'even directed consent cannot launch a published route belonging to another recipient: '..backend..'/'..field)
  local otherModule=other.load()
  otherModule.reconcile(other.cx,other.source,false,other.hooks);other.drain()
  check(other.starts==0 and other.stops==0 and other.closes==0 and #other.events==0 and other.route.cleanup_pending,'same empty window key cannot authorize foreign desktop launch or cleanup: '..backend..'/'..field)
 end
end
local interrupted=fixture();interrupted.consent(interrupted.load());interrupted.until_started()
interrupted.timers={} -- VM reset loses consent and callbacks, not native cleanup ownership.
local reloaded=interrupted.load();reloaded.reconcile(interrupted.cx,interrupted.source,false,interrupted.hooks);interrupted.drain()
check(interrupted.starts==1 and interrupted.stops==1 and interrupted.proofs==0 and interrupted.route.status=='failed','VM reload cleans positively bound SDK worker without replaying inference or claiming proof')
local closed=fixture();closed.consent(closed.load());closed.until_started()
closed.step() -- Observe the persisted HOST/SDK binding before its Config disappears.
closed.visible=false;closed.drain()
check(closed.stops==1 and closed.route.cleanup_pending,'closing Config reaps its owned SDK agent but preserves host obligation until readback')
closed.visible=true;closed.source=2;closed.load().reconcile(closed.cx,2,false,closed.hooks);closed.drain()
check(closed.starts==1 and not closed.route.cleanup_pending,'replacement SDK Config reconciles native absence without comparing its pane to HOST source')
local unboundClosed=fixture();unboundClosed.consent(unboundClosed.load());unboundClosed.until_started()
unboundClosed.route.owned_pane=nil;unboundClosed.route.bound_pane=nil;unboundClosed.route.bound_window_pane=nil;unboundClosed.visible=false
unboundClosed.drain()
check(unboundClosed.stops==0 and unboundClosed.route.cleanup_pending,'desktop command match alone never authorizes cleanup without HOST binding after source closure')
local ambiguous=fixture();ambiguous.consent(ambiguous.load());ambiguous.until_started()
ambiguous.ambiguous=true;ambiguous.timers={}
ambiguous.load().reconcile(ambiguous.cx,ambiguous.source,false,ambiguous.hooks);ambiguous.drain()
check(ambiguous.stops==0 and ambiguous.route.cleanup_pending,'ambiguous command identity retains a hold without broad cleanup')
local blocked=fixture();blocked.route.cleanup_blocked=true
blocked.consent(blocked.load());blocked.drain()
check(blocked.starts==0 and blocked.route.cleanup_pending,'incarnation-blocked directed consent cannot cause a native effect')
local blockedDuringPreflight=fixture();blockedDuringPreflight.consent(blockedDuringPreflight.load())
blockedDuringPreflight.route.cleanup_blocked=true;blockedDuringPreflight.drain()
check(blockedDuringPreflight.starts==0 and blockedDuringPreflight.route.cleanup_pending,'incarnation block after consent still prevents native effect')
local changed=fixture();changed.consent(changed.load());changed.until_started()
local callbacksBeforeRecipientChange=#changed.events
changed.recipient={namespace='beta-desktop',window_key='',conn=11,since=100};changed.drain()
check(changed.starts==1 and changed.stops==0 and changed.proofs==0 and #changed.events==callbacksBeforeRecipientChange and changed.route.cleanup_pending,'polling loses effect/callback authority when namespace changes with identical connection/time/window')
local uncertain=fixture();uncertain.throw_start=true;uncertain.hidden=true
uncertain.consent(uncertain.load());uncertain.drain()
check(uncertain.starts==1 and uncertain.stops==0 and uncertain.route.cleanup_pending and uncertain.route.bound_pane==nil,'throw-after-possible-effect with empty inventory remains unbound and held')
local beforeBind=fixture();beforeBind.defer_publish=true;beforeBind.consent(beforeBind.load())
beforeBind.timers={};beforeBind.published=true
local beforeBindReload=beforeBind.load()
beforeBindReload.reconcile(beforeBind.cx,beforeBind.source,false,beforeBind.hooks);beforeBind.drain()
check(beforeBind.starts==0 and beforeBind.route.cleanup_pending,'reload loses pending consent; empty inventory cannot launch or fabricate completed cleanup')
local replay=fixture();replay.consent(replay.load())
local consumedToken=replay.route.window_consent
check(replay.starts==0 and replay.published and type(consumedToken)=='string','HOST grants running route before any native launch')
replay.timers={} -- Reload loses local pending consent after HOST consumed its nonce.
replay.reject_consent=true
replay.consent(replay.load());replay.drain()
check(replay.consents==2 and replay.last_consent_token~=consumedToken and replay.route.window_consent==consumedToken,'replayed URL requests a new token but consumed HOST challenge cannot replace its durable echo')
check(replay.starts==0 and replay.proofs==0 and replay.route.cleanup_pending,'old running route cannot satisfy fresh post-reload consent or replay inference')
local discovered=fixture();discovered.throw_start=true
discovered.consent(discovered.load());discovered.drain()
check(discovered.starts==1 and discovered.stops==1 and discovered.route.bound_pane==509 and discovered.route.bound_window_pane==9 and not discovered.route.cleanup_pending,'uncertain launch records distinct native/SDK ownership before stopping discovered worker')
local legacy=fixture();legacy.published=true;legacy.live=true;legacy.route.native_namespace=nil
legacy.route.bound_pane=509;legacy.route.owned_pane=509;legacy.route.bound_window_pane=9
legacy.load().reconcile(legacy.cx,legacy.source,false,legacy.hooks);legacy.drain()
check(legacy.stops==0 and legacy.route.cleanup_pending,'legacy ownership without desktop namespace remains retained, never reset or cleaned by guess')
for _,backend in ipairs({'native-agent','local-terminal'}) do
 local unicode=fixture(backend)
 unicode.route.cwd='/Volumes/nondefault home Ω/Research 雪'
 unicode.route.command="'worker path Ω' '--session-dir' '/private data 雪/owned diagnostic'"
 unicode.consent(unicode.load());unicode.drain()
 check(unicode.starts==1 and unicode.route.status=='passed' and not unicode.route.cleanup_pending,'spaces and Unicode in host cwd/command preserve exact ownership and one-shot cleanup: '..backend)
end
do
 -- Real preparation/prerequisite modules with injected process/filesystem IO.
 -- The selected account owns every helper/provision observation; no CLI runs.
 local calls,descriptor={},nil
 local home='/home/selected';local executable=home..'/.local/bin/omp'
 local fake=setmetatable({
  runtime={os='linux'},plugin={data='/host/private/spawn',dir='/fixture/package'},
  fs={read=function(path)return 'packaged fixture bytes: '..path end},
  timer=function(_,callback)callback()end,now=function()return 1000 end,
  process={run=function(argv,options,done)
   table.insert(calls,table.clone(argv))
   local bytes=''
   if argv[1]=='getent' then
    check(argv[3]=='selected','account lookup uses the embedded literal OS selector')
    bytes='selected:x:1001:1001:Selected:'..home..':/bin/sh\n'
   else
    check(table.concat(argv,'|',1,6)=='sudo|-n|-u|selected|-H|--','all preparation/helper/provision IO executes as the selected account, not the host owner')
    if argv[10]=='spawn-account' then bytes='selected\n'..home..'\n'..executable..'\n'
    elseif argv[#argv]=='--help' then bytes='Usage: omp [options]\n  --help  Show help'
    elseif argv[10]=='spawn-bundle' then bytes=options.stdin
    elseif argv[10]=='spawn-root' then bytes=''
    elseif argv[10]=='spawn-prereq' then bytes='prerequisites-passed\n'
    elseif argv[7]=='cat' then bytes=assert(descriptor)
    elseif argv[8] and argv[8]:match('/mailbox_target%.sh$') then
     check(argv[11]=='provision' and argv[14]=='selected' and argv[17]:match('/mailbox_worker%.sh$'),'provision checks the selected identity and account-owned producer helper')
     descriptor=runtime.base64.decode(options.stdin:gsub('\n$',''));bytes='provisioned\n'
    elseif argv[7]=='sh' and argv[8]=='-c' and #argv==9 then bytes='SPAWN literal argv "quote" \\ Ω'
    else error('Unexpected preparation process: '..table.concat(argv,'|')) end
   end
   done({status=0,timed_out=false,stdout=bytes,stderr=''})
  end},
 },{__index=runtime})
 local modules={native_cli={},terminal_identity={}}
 local function load(name,directory)
  if name:sub(1,2)=='./' then name=(directory or '')..name:sub(3) end
  if modules[name] then return modules[name] end
  local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
  local base=name:match('^(.*[/])') or ''
  setfenv(chunk,setmetatable({tern=fake,require=function(path)return load(path,base)end},{__index=environment}))
  modules[name]=chunk();return modules[name]
 end
 local Setup,Config,Backend,Resolution=load('managed_setup'),load('config'),load('backend'),load('launch_resolution')
 local saved=assert(Config.validate_record({
  id='omp-selected',provider='OMP',account_label='Selected terminal',backend='local-terminal',command='sudo',
  arguments={'-n','-u','selected','-H',executable,'--auto-approve','--profile','work'},task_argument_index=9,
  cwd='/fixture/work',model='model-selector',profile='profile-selector',selector_evidence='reviewed selector',
  mailbox={permitted_root=fake.plugin.data..'/managed',worker_identity='host-owner'},
 }))
 local original=runtime.json.encode(saved)
 local draft=Setup.from_record(saved)
 check(not draft.preparation_error and draft.user=='selected' and draft.backend=='local-terminal' and draft.executable==executable,'saved sudo terminal route adopts the actual OS account without becoming a native agent')
 check(draft.task_argument_index=='4' and draft.arguments==Config.render_arguments({'--auto-approve','--profile','work'}),'removing literal sudo prefix adjusts the task slot while retaining permission and provider arguments')
 local function prepare(input)
  local candidate,probe,problem
  Setup.prepare(input,{host_os='linux',host_shell='sh'},function(value,result,why)candidate=value;probe=result;problem=why end)
  return candidate,probe,problem
 end
 local prepared,probe,problem=prepare(draft)
 check(prepared and probe.passed and not problem and prepared.user=='selected' and prepared.mailbox.worker_identity=='selected','actual prerequisite/provision/readback chain binds the selected account')
 check(prepared.mailbox.permitted_root==home..'/.local/share/tern-spawn/managed' and prepared.mailbox.producer_helper_path:find(prepared.mailbox.permitted_root..'/helper-bundles/',1,true)==1,'only the generated root relocates to the observed home with account-readable producer helpers')
 check(prepared.id==saved.id and prepared.cwd==saved.cwd and prepared.model==saved.model and prepared.profile==saved.profile and prepared.selector_evidence==saved.selector_evidence and runtime.json.encode(saved)==original,'preparation retains stable identity, folder and selectors without mutating old transport declarations')
 local ordinary=assert(Resolution.resolve(prepared,'ordinary','posix'));assert(Resolution.select_user(ordinary,'posix',true))
 check(ordinary.executable=='sudo' and ordinary.arguments[2]=='-i' and ordinary.arguments[6]=='/bin/sh' and ordinary.arguments[9]=='spawn-login' and ordinary.arguments[11]:find("exec '"..executable.."' '--auto-approve'",1,true)~=nil and #ordinary.arguments==11,'ordinary startup wraps the inner executable exactly once, without dropping permission flags')
 local fresh=assert(Backend.build(prepared,{host_os='linux',host_shell='sh'},{fresh=true,prompt='literal task',cwd=saved.cwd,placement='tab'}))
 local words=assert(Config.parse_arguments(fresh.command))
 check(words[1]=='sudo' and words[2]=='-n' and words[3]=='-i' and words[7]=='/bin/sh' and words[10]=='spawn-login' and words[11]:find("exec '"..executable.."'",1,true)~=nil and words[11]:sub(-14)=="'literal task'" and #words==11 and prepared.task_argument_index==4,'managed fresh launch wraps once and inserts the task at the adjusted worker argv slot')
 draft.root='/chosen/private/mailbox'
 local custom=assert(prepare(draft))
 check(custom.mailbox.permitted_root==draft.root and custom.mailbox.producer_helper_path:find(draft.root..'/helper-bundles/',1,true)==1,'an explicit custom root is never replaced by account discovery')
 local native=table.clone(saved);native.backend='native-agent';native.task_argument_index=nil
 native.arguments={'-n','--user=selected','-H','--',executable,'--restore','ordinary-session','--auto-approve'}
 native.fresh_executable='sudo';native.fresh_arguments={'-n','-uselected','-H','--',executable,'--auto-approve','--model','chosen/model'}
 local nativePrepared=assert(prepare(Setup.from_record(native)))
 check(nativePrepared.arguments[1]=='--restore' and nativePrepared.arguments[2]=='ordinary-session' and nativePrepared.fresh_arguments[1]=='--auto-approve' and nativePrepared.fresh_arguments[2]=='--model','ordinary resume flags remain exact and separate from the explicit fresh contract')
 local nativeDefault=table.clone(native);nativeDefault.fresh_executable=nil;nativeDefault.fresh_arguments=nil;nativeDefault.fresh_native_default=true;nativeDefault.model=nil;nativeDefault.profile=nil;nativeDefault.user='selected'
 local defaultPrepared=assert(prepare(Setup.from_record(nativeDefault)))
 check(#defaultPrepared.fresh_arguments==0 and defaultPrepared.arguments[1]=='--restore','selected-account native default never inherits ordinary continuation flags')
 local wrapped=Setup.defaults(saved.cwd);wrapped.backend='local-terminal';wrapped.executable='sudo'
 wrapped.arguments=Config.render_arguments(saved.arguments);wrapped.task_argument_index='9'
 local direct=assert(prepare(wrapped))
 check(direct.user=='selected' and direct.command==executable and direct.task_argument_index==4,'typed literal sudo draft is normalized once before account preparation and slot inference')
 for _,case in ipairs({
  {arguments={'-n','-u','selected','-u','other',executable},reason='ambiguous'},
  {arguments={'-n','-E','-u','selected',executable},reason='explicitly'},
  {arguments={'-n','-u'},reason='explicitly'},
  {arguments={'-n','-u','selected','sudo','-u','other',executable},reason='wrappers'},
  {arguments=saved.arguments,user='other',reason='conflicts'},
  {arguments=saved.arguments,fresh_executable=executable,fresh_arguments={'--auto-approve'},reason='different OS accounts'},
  {arguments=saved.arguments,fresh_executable='sudo',fresh_arguments={'-u','other',executable},reason='different OS accounts'},
  {arguments=saved.arguments,task_argument_index=2,reason='position'},
 }) do
  local invalid=table.clone(saved)
  for key,value in pairs(case) do if key~='reason' then invalid[key]=value end end
  local rejected=Setup.from_record(invalid);local before=#calls
  local value,_,why=prepare(rejected)
  check(value==nil and type(why)=='string' and why:find(case.reason,1,true) and #calls==before,'invalid or inconsistent saved routing refuses before any current-user fallback or resources: '..case.reason)
 end
 local mismatch=table.clone(prepared);mismatch.mailbox=table.clone(prepared.mailbox);mismatch.mailbox.worker_identity='host-owner'
 local before=#calls;local refused
 load('prereq').probe(mismatch,{host_os='linux',host_shell='sh'},function(result)refused=result end)
 check(refused and not refused.passed and refused.observations[1].id=='execution-identity' and #calls==before,'a selected account cannot probe or attest a differently owned mailbox transport')
end
return 'PASS managed_route '..tostring(checks)
