-- Explicit Config admin observations use native surfaces; no real process or store mutation.
local root=...
assert(type(root)=='string','pass package directory')
local runtime,environment=tern,getfenv()
local checks=0
local function check(value,message)assert(value,message);checks+=1 end
local function copy(value)if type(value)~='table' then return value end local result=if next(value)==nil and runtime.json.encode(value)=='[]' then runtime.json.array() else {} for key,item in pairs(value)do result[key]=copy(item)end return result end
local function fixture(operation,unconsented)
 local modules,callbacks={},{}
 local f={events={},consents={},inspections=0,peer_reads=0,challenge_reads=0}
 local injected=setmetatable({now=function()return f.clock or runtime.now()end},{__index=runtime})
 local function load(name)
  name=name:gsub('^%./','');if modules[name] then return modules[name] end
  local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
  setfenv(chunk,setmetatable({require=load,tern=injected},{__index=environment}));modules[name]=chunk();return modules[name]
 end
 modules.native_cli={inspect=function(window,options,callback)
  check(window=='window-one' and options.timeout_ms==5000,'inspection uses current positional window and existing native deadline')
  f.inspections+=1;table.insert(callbacks,callback)
 end}
 f.window=load('dispatch_window');f.codec=load('wire/codec')
 f.challenge={schema=1,nonce='migration-one',operation=operation or 'inspect',native_window='window-one',native_namespace='desktop-one',native_conn=7,native_since=17,native_session=3,host_pane_id='500',expected={source_schema=1,source_revision=1,source_sha256=string.rep('a',64),source_namespace='spawn-native',candidate_namespace='spawn-native',protocol=1,state='ready',phase='stable',managed_sha256=string.rep('b',64),pending_immutable=0,blockers=0}}
 f.peer={protocol=2,phase='legacy',source_nonce='orch-source',host_pane_id='600',authority_namespace='orch-candidate',authority_revision=12,source_sha256=string.rep('c',64),qualification={proof={source_schema=3,source_revision=12,source_sha256=string.rep('c',64),candidate_namespace='orch-candidate',protocol=1,state='ready',phase='stable',managed_sha256=string.rep('b',64),pending_immutable=0,blockers=0},selection={logical_session_ids=runtime.json.array(),mailbox_handles=runtime.json.array()}}}
 f.host={id=9,state='connected',panes={45,44,47}};f.session={id=3,host=9};f.key='window-one'
 f.recipient={namespace='desktop-one',window_key='window-one',conn=7,since=17}
 local function surface(block,key,role,value)
  return {surface={role='plugin.'..block},main={id='main.'..key,k='text',p={role=role,spans={{t=runtime.json.encode(value)}}}}}
 end
 local cx={hosts={current=function()return f.host end},sessions={current=function()return f.session end},window_key=function()return f.key end,toast=function()end}
 cx.session={
  pane=function(_,pane)return {block=if pane==45 then 'spawn.spawner' elseif f.wrong_program then 'other.plugin' else 'orchplus.orchestrator',tab=if f.parked and pane==44 then nil else 1}end,
  tabs=function()return {{id=1,session=f.session.id}}end,
  panes=function()local list={{pane=45,block='spawn.spawner'},{pane=44,block='orchplus.orchestrator'}};if f.duplicate then table.insert(list,{pane=47,block='orchplus.orchestrator'}) end return list end,
  surface=function(_,pane,options)
   if pane==45 and options.root=='main.spawn-managed-migration' then
    f.challenge_reads+=1
    if f.missing_challenge then return nil end
    local challenge=copy(f.challenge)
    if f.challenge_reads==f.change_challenge_read then challenge.nonce='replacement' end
    return surface('spawn.spawner','spawn-managed-migration','spawn.managed.migration',challenge)
   end
   if options.root=='main.setup-index' then
    return surface('orchplus.orchestrator','setup-index','orchplus.setup',{version=1,host_pane_id=if f.wrong_index then 'other' else '600',source_nonce='orch-source'})
   end
   if options.root=='main.migration-state' then
    f.peer_reads+=1;check(options.max_chars==65536,'compact migration surface uses bounded native read')
    if f.missing_peer then return nil end
    local peer=copy(f.peer)
    if f.peer_reads==f.change_peer_read then peer.authority_revision+=1 end
    local node=surface('orchplus.orchestrator','migration-state','orchplus.migration',peer)
    if f.truncated then node.more=1 end
    if f.wrong_role then node.main.p.role='other' end
    return node
   end
   return nil
  end,
  event=function(_,pane,event)
   if event.act=='managed-migration-consent' then
    check(pane==45,'directed consent returns to the SDK Config source, not its HOST pane ID')
    local consent=f.codec.strict_decode(event.value,8192)
    table.insert(f.consents,consent);f.challenge.window_consent=consent.window_consent;return
   end
   check(pane==45 and event.act=='spawn.migration-result','observation returns only through approved Config admin action')
   table.insert(f.events,event)
   if f.event_error then error('ambiguous host callback')end
  end,
 }
 f.cx=cx
 f.hooks={
  capture=function()
   if f.host.state~='connected' or f.session.host~=f.host.id then return nil end
   return {host=f.host.id,session=f.session.id}
  end,
  member=function(context,origin,pane)
   local info=context.session:pane(pane)
   return info and info.tab~=nil and origin.host==f.host.id and origin.session==f.session.id and table.find(f.host.panes,pane)~=nil
  end,
  ensure=function(context,callback)callback(context,nil)end,
  recipient=function()return f.recipient end,
 }
 f.poll=function()return f.window.observe_migration(cx,45,f.hooks)end
 f.consent=function()
  return f.window.consent_migration(cx,{url='tern-spawn://managed-migration/500/'..f.challenge.operation..'/migration-one',pane=45},f.hooks)
 end
 f.finish=function(result,fresh)
  local callback=table.remove(callbacks,1);assert(callback,'pending native inspection')
  callback(result or {status=0,timed_out=false,stdout=runtime.json.encode({clients={{kind='window',window='window-one',conn=7,since=17}}})},nil,if fresh==false then nil else fresh or cx)
 end
 f.reload=function()modules.dispatch_window=nil;callbacks={};f.window=load('dispatch_window')end
 if not unconsented then f.consent() end
 return f
end
for _,operation in ipairs({'inspect','prepare','finish'})do
 local f=fixture(operation);f.poll();f.poll()
 check(f.inspections==1 and #f.events==0,'one pending inspect per explicit '..operation..' challenge')
 f.finish();f.poll()
 check(#f.events==1 and f.inspections==1 and f.peer_reads==2,'fresh exact peer produces one synchronous '..operation..' observation')
 local value=f.codec.strict_decode(f.events[1].value,65536)
 check(value.intent_id=='migration-one' and value.operation==operation and value.native_window.window_key=='window-one' and value.native_window.conn==7 and value.native_window.since==17 and value.native_window.native_session==nil and value.native_session==nil and value.native_namespace=='desktop-one' and value.window_consent==f.consents[1].window_consent,'callback preserves desktop incarnation and directed consent without echoing HOST native session')
 check(value.local_source.source_sha256==f.challenge.expected.source_sha256 and value.local_source.source_revision==f.challenge.expected.source_revision,'callback preserves exact captured local StoreProof rather than refreshing it')
 check(value.peer_qualification.host_pane_id=='600' and value.peer_qualification.source_nonce=='orch-source' and value.peer_qualification.qualification.proof.source_revision==12,'callback exposes independently read ORCH source proof without fabricated owner')
end
for _,problem in ipairs({'duplicate','parked','missing_peer','truncated','wrong_role','wrong_program','wrong_index'})do
 local f=fixture();f.poll();f[problem]=true;f.finish()
 check(#f.events==0,'fresh native migration observation refuses '..problem)
end
for _,problem in ipairs({'conn','since','kind','window'})do
 local f=fixture();f.poll()
 local client={kind='window',window='window-one',conn=7,since=17};client[problem]=if problem=='conn' or problem=='since' then 99 else 'other'
 f.finish({status=0,timed_out=false,stdout=runtime.json.encode({clients={client}})})
 check(#f.events==0,'native incarnation requires exact '..problem)
end
for _,bad in ipairs({{status=0,truncated=true,stdout='{}'},{status=0,timed_out=true,stdout='{}'},{status=1,stdout='{}'},{status=0,stdout='{"clients":[],"complete":false}'}})do
 local f=fixture();f.poll();f.finish(bad);check(#f.events==0,'failed or incomplete native inspection never authorizes admin mutation')
end
local stale=fixture();stale.poll();stale.change_peer_read=2;stale.finish();check(#stale.events==0,'peer revision changed between fresh reads refuses callback')
local replaced=fixture();replaced.poll();replaced.challenge.nonce='replacement';replaced.finish();check(#replaced.events==0,'replaced Config challenge cannot borrow an earlier inspect callback')
local changed=fixture();changed.poll();changed.key='another-window';changed.finish();check(#changed.events==0,'window changed during inspect refuses callback')
local moved=fixture();moved.poll();moved.host.panes={44};moved.finish();check(#moved.events==0,'Config membership is rechecked after native await')
local disconnected=fixture();disconnected.poll();disconnected.host.state='disconnected';disconnected.finish();check(#disconnected.events==0,'disconnected native host cannot submit migration evidence')
local unavailable=fixture();unavailable.poll();unavailable.finish(nil,false);check(#unavailable.events==0,'missing fresh callback context refuses observation')
local throwing=fixture();throwing.poll();throwing.event_error=true;pcall(throwing.finish);throwing.event_error=false;throwing.poll();check(#throwing.events==1 and throwing.inspections==1,'ambiguous host event is not replayed by window polling')
throwing.missing_challenge=true;throwing.poll();throwing.missing_challenge=false;throwing.poll()
check(#throwing.events==1 and throwing.inspections==1,'temporarily unreadable challenge never clears an ambiguous submitted callback')
throwing.challenge.expected.source_revision+=1;throwing.poll()
check(#throwing.events==1 and throwing.inspections==1,'a changed publication cannot replay a submitted one-shot consent')
local reloaded=fixture();reloaded.poll();reloaded.reload();reloaded.poll()
check(reloaded.inspections==1 and #reloaded.consents==1 and #reloaded.events==0,'reload before a native callback cannot adopt or replay the published challenge')
local staleToken=fixture();staleToken.challenge.window_consent='stale-window-token';staleToken.finish();staleToken.poll()
check(staleToken.inspections==1 and #staleToken.events==0,'token replaced during a native await cannot submit or reauthorize the earlier observation')
local drifted=fixture();drifted.session.id=999;drifted.finish()
check(#drifted.events==0,'SDK session scope remains exact even though HOST native session is never compared')
local namespace=fixture();namespace.recipient.namespace='foreign-desktop';namespace.finish();namespace.poll()
check(namespace.inspections==1 and #namespace.events==0,'equal native key and conn/since cannot survive a desktop namespace change')
local expired=fixture();expired.clock=runtime.now()+31000;expired.finish();expired.poll()
check(expired.inspections==1 and #expired.events==0,'directed migration consent expires without an admin callback')
local waiting=fixture(nil,true);waiting.hooks.ensure=function(_,callback)waiting.ready=callback end
waiting.consent();waiting.session.id=999;waiting.ready(waiting.cx,nil)
check(#waiting.consents==0 and waiting.inspections==0,'changed SDK origin during observer initialization never sends consent')
local forged=fixture(nil,true);forged.host.panes={44}
forged.consent()
check(#forged.consents==0 and forged.inspections==0,'directed link cannot select a Config outside the captured SDK host/session')
local published=fixture();published.peer.compatibility={kind='current'};published.peer.result={code='observed'};published.poll();published.finish()
local forwarded=published.codec.strict_decode(published.events[1].value,65536).peer_qualification
check(forwarded.compatibility.kind=='current' and forwarded.result.code=='observed','callback preserves optional published metadata without treating it as migration authority')
local extra=fixture();extra.peer.unrecognized=true;extra.poll();extra.finish();check(#extra.events==0,'unrecognized published projection fields are refused rather than silently curated')
local mismatch=fixture();mismatch.peer.source_sha256=string.rep('d',64);mismatch.poll();mismatch.finish();check(#mismatch.events==0,'source metadata must correlate exact qualified source proof')
local duplicate=fixture();duplicate.poll();duplicate.finish({status=0,stdout=runtime.json.encode({clients={{kind='window',window='window-one',conn=7,since=17},{kind='window',window='window-one',conn=7,since=17}}})});check(#duplicate.events==0,'ambiguous complete native inventory never picks a window incarnation')
local full=fixture()
for i=1,64 do table.insert(full.peer.qualification.selection.logical_session_ids,string.format('s%03d',i)..string.rep('x',92)) end
for i=1,256 do table.insert(full.peer.qualification.selection.mailbox_handles,string.format('m%03d',i)..string.rep('x',92)) end
full.poll();full.finish()
local selected=full.codec.strict_decode(full.events[1].value,65536).peer_qualification.qualification
check(#selected.selection.logical_session_ids==64 and #selected.selection.mailbox_handles==256 and selected.projection==nil,'maximum compact native selection travels without a full managed inventory')
local legacy=fixture();legacy.peer.qualification.projection={schema=1,sessions=runtime.json.array(),workers=runtime.json.array()};legacy.poll();legacy.finish()
check(#legacy.events==0,'full inventory qualification is not accepted as a second native mutation schema')
for _,bad in ipairs({'object','duplicate','unsorted','extra','oversized'}) do
 local f=fixture();local selection=f.peer.qualification.selection
 if bad=='object' then selection.logical_session_ids={}
 elseif bad=='duplicate' then table.insert(selection.mailbox_handles,'same');table.insert(selection.mailbox_handles,'same')
 elseif bad=='unsorted' then table.insert(selection.logical_session_ids,'z');table.insert(selection.logical_session_ids,'a')
 elseif bad=='extra' then selection.projection={}
 else for i=1,65 do table.insert(selection.logical_session_ids,string.format('session-%03d',i)) end end
 f.poll();f.finish();check(#f.events==0,'canonical compact migration selection refuses '..bad)
end
for _,bad in ipairs({'extra','missing_namespace','invalid_state'}) do
 local f=fixture();local proof=f.peer.qualification.proof
 if bad=='extra' then proof.unrecognized=true elseif bad=='missing_namespace' then proof.source_schema=4 else proof.state='unchecked' end
 f.poll();f.finish();check(#f.events==0,'canonical ORCH StoreProof wrapper refuses '..bad)
end
return 'PASS window_migration '..tostring(checks)
