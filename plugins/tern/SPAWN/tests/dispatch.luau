-- Native Luau fixture runner. Durable KV, config authority, and transport effects
-- are injected; the real public codec, backend and dispatch transitions run.
local root,section=...
assert(type(root)=='string','pass package directory')
assert(section==nil or type(section)=='string','section must be a dispatch section name')
local runtime,environment=tern,getfenv()
local checks=0
local function check(v,m)assert(v,m);checks+=1 end
local function copy(v)if type(v)~='table'then return v end local n={} for k,x in pairs(v)do n[k]=copy(x)end return n end
local function fixture(seed,actual_mailbox)
 local saved=copy(seed or {});local modules={};local effects={reserves=0,observations=0,imports=0}
 local transport={files={},modes={},writes=0}
 local record={id='worker',provider='omp',account_label='Configured display',backend='native-agent',command='omp',arguments={},cwd='/work',placement='tab',enabled=true,include_all=true,duplicate_policy='skip',fresh_native_default=true,mailbox={permitted_root='/mail',helper_path='/tools/helper',worker_identity='fixture',verified=true,evidence_ref='fixture-only',wake='native-ask-v1',producer={read=true,write=true,hash=true,journal=true,poll=false},capabilities={'report-files-v1','native-ask-v1'}}}
 record.mailbox.producer_helper_path='/tools/worker-helper'
 local snapshot={ready=true,namespace='host',host_key='host:test',config_revision=0,records={record},host_os='linux',host_shell='/bin/sh'}
 local binding={authority_id='host:1',managed_authority_id='host:1',session_key='host/session/1',host_key='host:test',native_session=1}
 local mailbox_binding=nil
 local authority={snapshot=function()return copy(snapshot)end,managed_reserve=function(_,_,id,observer)effects.reserves+=1;return {id='attempt-1',record_id=id,observer_id=observer}end,managed_observe=function()effects.observations+=1;return true end,managed_retire=function(...)effects.retire_args={...};effects.retirements=(effects.retirements or 0)+1;return not effects.fail_retire,'injected retirement storage failure' end,managed_import=function()effects.imports+=1;return {imported=1}end}
 authority.managed_snapshot=authority.snapshot
 local mailbox={empty=function()return {version=1,generations={}}end,validate=function(r)if type(r)~='table' or r.version~=1 then return nil,{status='rejected',error={code='journal_corrupt'}} end return r end,recover=copy,get=function()return {binding=copy(mailbox_binding),record_id='worker',record_revision=0,phase='provisioned',capabilities=copy(record.mailbox.capabilities)}end,location=function()return {root='/mail/private',helper='/tools/helper',producer_helper='/tools/worker-helper',wake=effects.wake_route or 'native-ask-v1'}end}
 mailbox.prepare=function(registry,_,_,context)
  effects.prepares=(effects.prepares or 0)+1
  if not effects.allow_mailbox then return nil,nil,{status='full',resource='fixture',current=1,limit=1} end
  if effects.retained_outcome then return nil,nil,copy(effects.retained_outcome) end
  return {id=context.operation_id,binding={}},copy(registry)
 end
 mailbox.execute=function(operation,callback)
  effects.transports=(effects.transports or 0)+1
  effects.operation=copy(operation)
  effects.callback=callback
  callback(if effects.target_full then {status='full',resource='target',current=1,limit=1} else copy(effects.outcome or {status='provisioned',payload={handle='mailbox'}}))
 end
 mailbox.settle=function(registry,_,outcome)return copy(registry),outcome end
 local injected=setmetatable({now=function()return effects.now or 1700000000.25 end,kv={get=function(k)return copy(saved[k])end,set=function(k,v)if effects.fail_write then error('injected failure')end saved[k]=copy(v)end}},{__index=runtime})
 injected.on=function()end
 if actual_mailbox then
  injected.timer=function()return {cancel=function()end}end
  injected.process={run=function(argv,options,callback)
   local mode,path=argv[5],argv[6];table.insert(transport.modes,mode)
   local stdout='storage_error\n'
   if mode=='provision'then stdout='provisioned\n'
   elseif transport.locked then stdout='admission_full\ncapacity_admission\n1\n1\n'
   elseif mode=='publish' and not transport.fail_publish then
    transport.files[path]=runtime.base64.decode(options.stdin:gsub('\n$',''));transport.writes+=1;stdout='published\n'
   elseif mode=='reconcile'then
    local bytes=runtime.base64.decode(options.stdin:gsub('\n$',''))
    stdout=if transport.files[path]==bytes then 'already_published\n' else 'missing\n'
   end
   callback({status=0,timed_out=false,stdout=stdout,stderr=''})
  end}
 end
 local function load(name)
  name=name:gsub('^%./','')
  if name=='authority'then return authority elseif name=='mailbox' and not actual_mailbox then return mailbox end
  if name=='host_executor' then return {install=function()end,attach=function()end} end
  if modules[name]then return modules[name]end
  local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
  setfenv(chunk,setmetatable({tern=injected,require=load},{__index=environment}))
  modules[name]=chunk();return modules[name]
 end
 local p,c,d=load('bridge_protocol'),load('codec'),load('dispatch')
 local raw=d
 local driver=setmetatable({},{__index=raw})
 driver.request=function(r,b,s,changed)
  -- Mirrors host.luau: read-only catalog/status/owner_status go straight to request, never staged.
  if r.op=='catalog' or r.op=='status' or r.op=='owner_status' then return raw.request(r,b,s,changed) end
  local body=raw.stage(r,b,s,77)
  local projection=raw.execution(r,77)
  if body.status=='pending' and projection and projection.kind=='authorize' then
   effects.grants=(effects.grants or 0)+1
   return raw.authorize(r,projection.nonce,77,changed,{executor=r.origin_binding.window_epoch,epoch=1,grant_id='fixture-'..tostring(effects.grants)},'fixture-window')
  end
  return body
 end
 driver.wake_claim=function(r,executor,operation,result,claim)
  local entry=saved['dispatch-v1'] and saved['dispatch-v1'].requests[r.origin_binding.logical_session_id..'/'..r.request_id]
  return raw.wake_claim(r,executor,operation,result,claim or entry and entry.orch_claim)
 end
 d=driver
 local origin={logical_session_id='session',owner_id='owner',owner_generation=1,host_pane_id='12',alias_nonce='alias',window_key='',window_epoch='epoch',native_session_id='3',window_host_id='7'}
 local function req(op,id,extra)
  local r={schema=1,origin='orchplus',op=op,request_id=id,action_id='action-'..id,controller_pane='44',controller_generation=1,origin_binding=copy(origin)}
  for k,v in pairs(extra or {})do r[k]=v end return r
 end
 local function launch(id,extra)
  local text="literal ' $HOME ; 雪\nsecond line"
  local e={worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',assignment_sha256=c.sha256(text)}
  for k,v in pairs(extra or {})do e[k]=v end
  mailbox_binding={logical_session_id='session',worker_id=e.worker_id,worker_generation=1,launch_request_id=id,work_id='work',enrolment_token=e.enrolment_token}
  return req('launch',id,{record_id='worker',record_revision=0,work_id='work',prompt=text,cwd='/work',placement='tab',fresh=true,mailbox_handle='mailbox',enrolment=e})
 end
 local host_definition
 local function host()
  if not host_definition then
   local definitions={}
   injected.block={define=function(name,definition)definitions[name]=definition end}
   injected.pane={list=function()return {{pane=12,program='orchplus.orchestrator'}}end}
   authority.binding=function()return copy(binding)end
   modules.native_cli={inspect=function(window,_,callback)
    effects.inspected=effects.inspected or {};table.insert(effects.inspected,if window==nil then '<host>' else window)
    local inventory=if effects.inspect then effects.inspect(window) else {clients={{kind='window',window='fixture'}},sessions={{id=1,tabs={{blocks={{id=77},{id=12}}}}}}}
    -- defer_inspect holds each answer until the test releases it, like a slow native inspection.
    local function reply()callback({status=0,timed_out=false,stdout=runtime.json.encode(inventory)},nil)end
    if effects.defer_inspect then effects.deferred=reply;return end
    reply()
   end}
   load('host');host_definition=definitions.dispatch
  end
  return host_definition
 end
 local function host_event(r,operation,result)
  local definition=host()
  local cx={pane=77,save=function()end,render=function()end}
  local state=definition.init(cx,{},nil)
  local entry=saved['dispatch-v1'].requests[r.origin_binding.logical_session_id..'/'..r.request_id]
  definition.event(state,{ev='action',act='spawn.'..operation,value=runtime.json.encode({request_json=runtime.json.encode(r),executor_id='window-a',result=result,orch_claim=entry and entry.orch_claim})},cx)
  return state.body
 end
 -- A plain bridge request (catalog/status/staged ops) through the host dispatch block's membership fence.
 local function host_request(r)
  local definition=host()
  local cx={pane=77,save=function()end,render=function()end}
  local state=definition.init(cx,{},nil)
  definition.event(state,{ev='action',act=r.op,value=runtime.json.encode(r)},cx)
  return state.body
 end
 return {p=p,c=c,d=d,raw=raw,req=req,launch=launch,binding=binding,effects=effects,snapshot=snapshot,saved=saved,origin=origin,authority=authority,transport=transport,host_event=host_event,host_request=host_request,host=host,image=function()return copy(saved)end}
end
local sections={}
local pane={pane_id='55',window_epoch='epoch',window_key='',native_session_id='3',window_host_id='7'}
local templates=fixture()
local provision=templates.req('mailbox_provision','provision',{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',record_id='worker',record_revision=0,capability='report-files-v1'})
local wake_request=templates.req('mailbox_publish_reply','wake',{
 logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',
 handle='mailbox',expected_generation=1,message_id='message',reply_seq=1,action_revision=1,reply_sha256=templates.c.sha256('reply'),part='manifest',object_b64='e30=',object_sha256=templates.c.sha256('{}'),
})
local sourceclaim={executor=provision.origin_binding.window_epoch,epoch=1,grant_id='source-grant'}
sections.launch=function()
local f=fixture()
local r=f.req('catalog','catalog')
check(f.p.decode(runtime.json.encode(r))~=nil,'strict catalog accepts exact common fields')
local bad=copy(r);bad.command='raw-command';check(f.p.decode(runtime.json.encode(bad))==nil,'runtime raw command rejected')
check(f.p.decode('{"schema":1,"schema":1}')==nil,'duplicate keys rejected before native JSON normalization')
check(f.p.decode('{"schema":null}')==nil,'null rejected')
local wire=f.p.encode(f.p.body(r,'catalog',{revision=0,records={}}))
check(f.p.unframe(wire).request_id=='catalog','exact body bytes/hash roundtrip')
check(f.p.unframe(wire..'x')==nil,'trailing bytes rejected')
local cat=f.d.request(r,f.binding,1,function()end)
check(cat.status=='catalog' and cat.payload.records[1].eligible,'configured catalog retained without inventing verified identity')
f.snapshot.config_revision=1
check(f.d.request(r,f.binding,1,function()end).payload.revision==0,'same catalog request replays immutable revision')
f.snapshot.config_revision=0
local l=f.launch('launch')
check(f.p.decode(runtime.json.encode(l))~=nil,'initial launch has no fabricated handover')
local outcome=f.d.request(l,f.binding,1,function()end)
check(outcome.status=='resolved' and f.effects.reserves==1,'one canonical reservation after live authorization, before native execution claim: '..runtime.json.encode(outcome))
check(f.d.request(l,f.binding,1,function()end).status=='resolved' and f.effects.reserves==1,'duplicate launch never reserves twice')
local changed=copy(l);changed.prompt='changed'
check(f.d.request(changed,f.binding,1,function()end).error.code=='content_conflict','changed request ID reuse rejects')
local projection=f.d.execution(l,77)
check(projection.launch.prompt:sub(-#l.prompt)==l.prompt,'original assignment bytes unchanged inside separate transport preface')
check(f.d.execution(f.req('status','pending-status',{target_request_id='launch'}),77).request.request_id=='launch','status polling preserves private pending launch projection')
check(f.d.claim(l,'executor-a','claim').status=='claimed','exclusive first claim persisted')
check(f.d.claim(l,'executor-b','claim').status=='claimed' and f.d.execution(l,77).claim.executor_id=='executor-a','second executor cannot steal claim')
check(f.d.claim(l,'executor-b','begin').status=='rejected','foreign begin rejects')
check(f.d.claim(l,'executor-a','begin').status=='launching','execution intent durable before native effect')
check(f.d.claim(l,'executor-a','result',{status='submitted',pane_binding=pane}).status=='awaiting_acceptance','native pane is not semantic acceptance')
local accept=f.req('accept','accept',{target_request_id='launch',target_action_id='action-launch',pane_binding=pane,worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('exact accepted report')})
check(f.d.request(accept,f.binding,1,function()end).status=='accepted','initial acceptance without handover succeeds')
check(f.d.request(accept,f.binding,1,function()end).status=='accepted','acceptance exact replay retained')
local wrong=copy(accept);wrong.request_id='wrong-accept';wrong.enrolment_token='bbbbbbbbbbbbbbbb'
check(f.d.request(wrong,f.binding,1,function()end).status=='rejected','wrong acceptance token rejected')
local status=f.req('status','status',{target_request_id='launch'})
check(f.d.request(status,f.binding,1,function()end).payload.outcome.status=='accepted','status addressed by retained launch request')
local probe=f.req('owner_status','owner-probe')
check(f.p.decode(runtime.json.encode(probe))~=nil,'read-only owner_status is a closed public request')
local before_probe=runtime.json.encode(f.saved['dispatch-v1'])
check(f.d.request(probe,f.binding,1,function()end).payload.owner=='current','owner_status reports the exact current controller binding')
local reloaded_probe=copy(probe);reloaded_probe.request_id='owner-reloaded';reloaded_probe.origin_binding.window_epoch='window-after-reload'
check(f.d.request(reloaded_probe,f.binding,1,function()end).payload.owner=='previous_incarnation','a reloaded window of the same owner learns SPAWN still binds its earlier incarnation')
local foreign_probe=copy(probe);foreign_probe.request_id='owner-foreign';foreign_probe.origin_binding.owner_id='other'
check(f.d.request(foreign_probe,f.binding,1,function()end).payload.owner=='other_owner','a different owner is named without exposing the binding')
check(runtime.json.encode(f.saved['dispatch-v1'])==before_probe and f.d.request(reloaded_probe,f.binding,1,function()end).payload.owner=='previous_incarnation','owner_status reserves, fences and records nothing')
local other=copy(r);other.request_id='other';other.origin_binding.owner_id='other'
check(f.d.request(other,f.binding,1,function()end).error.code=='binding_mismatch','occupied controller refuses other owner')
local stale=f.req('catalog','stale',{cursor={revision=99,index=1}})
check(f.d.request(stale,f.binding,1,function()end).status=='rejected','revision-bound cursor rejects stale config')
local owners=f.d.recovery_view(f.binding)
check(f.d.recover_owner(f.binding,'session',owners[1].revision,false),'operator first fences old owner')
check(f.d.request(reloaded_probe,f.binding,1,function()end).payload.owner=='fenced','owner_status shows a fenced but unconfirmed SPAWN recovery')
check(f.d.request(f.req('catalog','fenced'),f.binding,1,function()end).status=='rejected','fenced controller cannot dispatch')
owners=f.d.recovery_view(f.binding)
check(f.d.recover_owner(f.binding,'session',owners[1].revision,true),'explicit exact-revision recovery records attestation')
check(f.d.request(probe,f.binding,1,function()end).payload.owner=='retired' and f.d.request(reloaded_probe,f.binding,1,function()end).payload.owner=='none',
 'after confirmed SPAWN recovery the old binding is retired and the reloaded window finds no owner to recover')
check(f.d.request(f.req('catalog','retired'),f.binding,1,function()end).status=='rejected','retired origin cannot reactivate')
local retired_launch=f.launch('retired-launch')
check(f.raw.stage(retired_launch,f.binding,1,77).status=='rejected' and f.raw.execution(retired_launch,77)==nil and f.effects.reserves==1,'retired binding cannot stage a fresh authorization or reserve another launch')
check(f.d.request(f.req('status','retired-status',{target_request_id='launch'}),f.binding,1,function()end).payload.outcome.status=='accepted','retired binding may inspect its retained outcome without reactivation')
check(f.saved['dispatch-v1'].owners.session==nil,'read-only retired status cannot recreate the owner slot')
local reload=fixture()
local pending=reload.launch('pending')
reload.d.request(pending,reload.binding,1,function()end);reload.d.claim(pending,'executor','claim')
local restored=fixture(reload.image())
check(restored.d.request(restored.req('status','query',{target_request_id='pending'}),restored.binding,1,function()end).payload.outcome.status=='uncertain','host reload keeps possible launch uncertain')
local failure=fixture();failure.d.request(failure.req('catalog','init'),failure.binding,1,function()end)
failure.effects.fail_write=true
check(failure.d.request(failure.launch('write-fail'),failure.binding,1,function()end).error.code=='storage_error' and failure.effects.reserves==0,'failed intent commit reserves and launches nothing')
local corrupt=fixture();corrupt.d.request(corrupt.req('catalog','init'),corrupt.binding,1,function()end)
local corrupt_image=corrupt.image();corrupt_image['dispatch-v1'].mailboxes.version=2
local corrupt_body=fixture(corrupt_image).d.request(corrupt.req('catalog','corrupt-catalog'),corrupt.binding,1,function()end)
check(corrupt_body.error~=nil and corrupt_body.error.code=='storage_error' and type(corrupt_body.error.message)=='string' and corrupt_body.error.message:find('journal_corrupt',1,true)~=nil and not corrupt_body.error.message:find('table:',1,true),'corrupt mailbox journal reports a bounded string storage_error: '..runtime.json.encode(corrupt_body))
local rollover=fixture();local successor=rollover.launch('successor',{handover_id='handover',handover_token='handover-token-1234'})
check(rollover.p.decode(runtime.json.encode(successor))~=nil,'paired rollover enrolment valid')
successor.enrolment.handover_token=nil;check(rollover.p.decode(runtime.json.encode(successor))==nil,'unpaired rollover rejects')
local unknown=copy(r);unknown.origin_binding.extra='forbidden'
check(f.p.decode(runtime.json.encode(unknown))==nil,'origin binding is closed')
check(f.p.decode(string.rep(' ',8193))==nil,'outer request overflow rejected')
local immutable={a='quote \"',b={1,2}};local reordered={b={1,2},a='quote \"'}
check(f.p.fingerprint(immutable)==f.p.fingerprint(reordered),'compacted fingerprints ignore map iteration order')
end
sections.migration=function()
local migration=fixture();local records='[]'
local preview={schema=1,origin='spawn-migration',op='import_config',request_id='migration',source_client='client',target_host='host:test',source_revision=1,source_sha256=migration.c.sha256(records),records_json=records}
local gate=migration.d.open_import(migration.binding,runtime.json.encode(preview));check(type(gate)=='string','only owner action opens migration gate')
local request=copy(preview);request.migration_gate_id=gate
check(migration.d.import_config(request).status=='imported' and migration.effects.imports==1,'gated migration imports without launching')
check(migration.d.import_config(request).status=='imported' and migration.effects.imports==1,'consumed migration replay does not overwrite config')
local gate2=migration.d.open_import(migration.binding,runtime.json.encode(preview));check(migration.d.cancel_import(gate2),'owner cancels unconsumed gate')
request.migration_gate_id=gate2;check(migration.d.import_config(request).status=='rejected','cancelled import gate rejects')
-- The authority receipt and dispatch intent are separate durable stores. Interrupt
-- each side of the authority commit, then reload only from their persisted images.
local function migration_fixture(seed,receipts,interruption)
 local f=fixture(seed)
 local original_snapshot=f.authority.managed_snapshot
 f.authority.managed_snapshot=function(binding)
  if interruption=='before-import' then error('injected migration interruption') end
  return original_snapshot(binding)
 end
 f.authority.managed_import=function(binding,revision,id,source)
  receipts.calls+=1
  check(f.p.equal(binding,f.binding),'migration recovery retains authority binding')
  check(revision==f.snapshot.config_revision,'unattempted migration uses current authority revision')
  if interruption=='before-commit' then error('injected migration interruption') end
  local prior=receipts.imports[id]
  if prior then
   if f.p.equal(prior,source) then return {imported=0,replayed=true} end
   return nil,'content_conflict'
  end
  receipts.imports[id]=copy(source);receipts.commits+=1
  if interruption=='after-commit' then error('injected migration interruption') end
  if interruption=='outcome-save' then f.effects.fail_write=true end
  return {imported=1}
 end
 return f
end
for _,interruption in ipairs({'before-import','before-commit','after-commit','outcome-save'}) do
 local receipts={imports={},calls=0,commits=0}
 local interrupted=migration_fixture(nil,receipts,interruption)
 local exact=copy(preview)
 exact.migration_gate_id=interrupted.d.open_import(interrupted.binding,runtime.json.encode(preview))
 local ok,outcome=pcall(interrupted.d.import_config,exact)
 if interruption=='outcome-save' then
  check(ok and outcome.status=='uncertain','failed outcome save reports uncertain migration')
 else
  check(not ok and tostring(outcome):find('injected migration interruption',1,true)~=nil,'migration interrupted at '..interruption)
 end
 check(interrupted.saved['dispatch-v1'].gates[exact.migration_gate_id].outcome.status=='uncertain','durable consumed intent survives '..interruption)
 local committed=interruption=='after-commit' or interruption=='outcome-save'
 check(receipts.commits==(if committed then 1 else 0),'authority commit boundary preserved at '..interruption)
 local recovered=migration_fixture(interrupted.image(),receipts)
 recovered.snapshot.config_revision=3
 local calls=receipts.calls
 for field,value in pairs({request_id='changed',source_client='other-client',target_host='host:other',source_revision=2,records_json='[ ]',migration_gate_id='missing-gate'}) do
  local changed=copy(exact);changed[field]=value
  if field=='records_json' then changed.source_sha256=recovered.c.sha256(changed.records_json) end
  check(recovered.d.import_config(changed).status=='rejected' and receipts.calls==calls,'uncertain migration rejects changed '..field)
 end
 local reconciled=recovered.d.import_config(exact)
 check(reconciled.status==(if committed then 'already_imported' else 'imported'),'exact replay reconciles '..interruption)
 check(receipts.commits==1 and receipts.calls==calls+1,'migration completes exactly one authority commit after '..interruption)
 check(receipts.imports['bridge-'..exact.request_id]~=nil,'migration preserves the authority receipt key')
 check(recovered.d.import_config(exact).status==reconciled.status and receipts.calls==calls+1,'resolved replay does not re-enter authority')
 local reloaded=migration_fixture(recovered.image(),receipts)
 check(reloaded.d.import_config(exact).status==reconciled.status and receipts.calls==calls+1,'reconciled outcome survives another reload')
end
local gated=fixture()
local gate3=gated.d.open_import(gated.binding,runtime.json.encode(preview))
local after_restart=fixture(gated.image())
local expired=copy(preview);expired.migration_gate_id=gate3
check(after_restart.d.import_config(expired).status=='rejected','host reload invalidates unconsumed migration gate')
end
local function launched_fixture(accepted,terminal)
 local f=fixture()
 if terminal then
  local record=f.snapshot.records[1]
  record.backend='local-terminal';record.fresh_native_default=nil
  record.fresh_executable='/tools/worker';record.fresh_arguments={'--task'};record.task_argument_index=2
  record.mailbox.wake='worker-poll-v1';record.mailbox.producer.poll=true
  record.mailbox.capabilities={'report-files-v1','worker-poll-v1','argv-v1'}
  f.effects.wake_route='worker-poll-v1'
 end
 local launch=f.launch('launch')
 f.d.request(launch,f.binding,1,function()end)
 f.d.claim(launch,'executor-a','claim');f.d.claim(launch,'executor-a','begin')
 f.d.claim(launch,'executor-a','result',{status='submitted',pane_binding=pane})
 if accepted then
  local acceptance=f.req('accept','accept',{target_request_id='launch',target_action_id=launch.action_id,pane_binding=pane,worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('accepted')})
  f.d.request(acceptance,f.binding,1,function()end)
 end
 f.effects.allow_mailbox=true;f.effects.outcome={status='published'}
 return f
end
local function queue_wake(f,publication,id)
 local outcome=f.d.request(publication,f.binding,1,function()end)
 if outcome.status=='pending' then outcome=f.d.request(publication,f.binding,1,function()end) end
 local payload=assert(outcome.payload,'publication outcome must be read back before requesting its wake')
 assert(f.p.id(payload.wake_target_request_id) and f.p.id(payload.wake_target_action_id),'publication must identify its canonical notification')
 local wake=f.req('native_wake',id or 'notify-'..publication.request_id,{target_request_id=payload.wake_target_request_id,target_action_id=payload.wake_target_action_id})
 f.d.request(wake,f.binding,1,function()end)
 return wake
end
sections.publication=function()
local wakef=launched_fixture(true)
-- The injected transport settles an actual dispatch publication.
local notify=queue_wake(wakef,wake_request)
check(wakef.raw.execution(wake_request,77)==nil,'durable publication does not expose native execution')
check(wakef.d.wake_claim(notify,'window-a','wakeclaim').status=='claimed','separate wake claim committed independently from publication')
check(wakef.d.wake_claim(notify,'window-b','wakebegin').status=='rejected','foreign wake executor rejected')
check(wakef.d.wake_claim(notify,'window-a','wakebegin').status=='launching','wake intent precedes ask')
check(wakef.d.wake_claim(notify,'window-a','wakeresult',{status='uncertain'}).status=='uncertain','lost ask remains uncertain, not receipt')
check(wakef.d.wake_claim(notify,'window-b','wakeclaim').status=='uncertain','uncertain wake cannot be claimed twice')
local compacted=fixture();compacted.d.request(compacted.req('catalog','init-fence'),compacted.binding,1,function()end)
compacted.saved['dispatch-v1'].request_fences['session/wake']=compacted.p.fingerprint(wake_request)
check(compacted.d.request(wake_request,compacted.binding,1,function()end).status=='already_compacted','settled write replay never recreates files')
local altered=copy(wake_request);altered.reply_seq=2
check(compacted.d.request(altered,compacted.binding,1,function()end).error.code=='content_conflict','compacted request identity cannot be reused for a new slot')
local capacity=fixture()
local refused=capacity.d.request(provision,capacity.binding,1,function()end)
check(refused.status=='full' and refused.payload.retryable and refused.payload.effect_started==false and not capacity.effects.transports,'pre-effect capacity refusal explicitly authorizes same-request recheck')
capacity.effects.allow_mailbox=true
capacity.d.request(provision,capacity.binding,1,function()end)
check(capacity.effects.prepares==2 and capacity.effects.transports==1,'same immutable request rechecks only definitively unexecuted full')
check(capacity.d.request(provision,capacity.binding,1,function()end).status=='provisioned' and capacity.effects.transports==1,'completed recheck returns durable outcome without repeating effect')
local targetfull=fixture();targetfull.effects.allow_mailbox=true;targetfull.effects.target_full=true
targetfull.d.request(provision,targetfull.binding,1,function()end)
local retainedfull=targetfull.d.request(provision,targetfull.binding,1,function()end)
check(retainedfull.status=='full' and retainedfull.payload.retryable==nil and targetfull.effects.transports==1,'post-execution full never invents retry authorization')
local waked=launched_fixture(true)
local submitted=queue_wake(waked,wake_request)
waked.d.wake_claim(submitted,'window-a','wakeclaim');waked.d.wake_claim(submitted,'window-a','wakebegin')
waked.d.wake_claim(submitted,'window-a','wakeresult',{status='submitted'})
check(waked.d.request(wake_request,waked.binding,1,function()end).payload.wake_status=='submitted','original publication replay exposes durable queued-ask settlement')
end
local function ack_request(f,seq)
 local ack={version=1,logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',event_id=f.c.sha256('mailbox:report:'..tostring(seq)),seq=seq,event_sha256=f.c.sha256('event-'..tostring(seq)),committed_revision=seq+1,disposition='accepted',receipt_chain_sha256=f.c.sha256('chain-'..tostring(seq))}
 local bytes=runtime.json.encode(ack)
 return f.req('mailbox_publish_ack','ack-'..tostring(seq),{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,receipt_revision=seq+1,ack_b64=runtime.base64.encode(bytes),ack_sha256=f.c.sha256(bytes)})
end
sections.ack_lifecycle=function()
for _,accepted in ipairs({false,true})do
 local ackf=launched_fixture(accepted);local publication=ack_request(ackf,if accepted then 2 else 1)
 ackf.d.request(publication,ackf.binding,1,function()end)
 local published=ackf.d.request(publication,ackf.binding,1,function()end)
 check(published.payload.wake_status=='awaiting_window' and published.payload.wake_effect_started==false and ackf.raw.execution(publication,77)==nil,'ACK publication is durable while native wake has not started')
 local notify=queue_wake(ackf,publication)
 local projected=ackf.raw.execution(notify,77)
 check(projected and projected.kind=='wake' and projected.phase=='resolved','ACK1 before accept and ACK2 after accept admit a separate notification')
 local original=copy(projected.orch_claim);local grants=ackf.effects.grants
 local query=ackf.req('status','ack-status',{target_request_id=notify.request_id})
 check(ackf.p.equal(ackf.raw.execution(query,77).orch_claim,original),'status projects only the original distinct notification claim')
 local changed=copy(notify);changed.target_action_id='wrong'
 check(ackf.d.wake_claim(changed,'window-a','wakeclaim').status=='rejected','changed notification binding cannot claim wake')
 check(ackf.host_event(notify,'wakeclaim').status=='claimed','host durably claims the separate native wake')
 ackf.effects.callback({status='already_published'})
 check(ackf.raw.execution(notify,77).phase=='claimed','duplicate publication outcome cannot reset a claimed wake')
 check(ackf.host_event(notify,'wakebegin').status=='launching','host durably begins the native wake')
 local reboot=fixture(ackf.image())
 check(reboot.d.request(publication,reboot.binding,1,function()end).payload.wake_status=='uncertain' and reboot.raw.execution(notify,77)==nil,'host reload preserves possible ACK wake as uncertain')
 check(reboot.d.wake_claim(notify,'window-a','wakeresult',{status='submitted'},original).status=='rejected','late prior VM wake callback is rejected')
 local result=if accepted then 'submitted' else 'uncertain'
 ackf.host_event(notify,'wakeresult',{status=result})
 ackf.effects.callback({status='published'})
 ackf.d.wake_claim(notify,'window-a','wakeresult',{status=if accepted then 'uncertain' else 'submitted'})
 check(ackf.d.request(publication,ackf.binding,1,function()end).payload.wake_status==result and ackf.raw.execution(notify,77)==nil,'duplicate publication and wake outcomes preserve settled ACK notification')
 check(ackf.effects.grants==grants and ackf.effects.transports==1,'native notification never republishes immutable ACK bytes')
end
end
sections.wake_binding=function()
local earlyreply=launched_fixture(false)
earlyreply.d.request(wake_request,earlyreply.binding,1,function()end)
check(earlyreply.raw.execution(wake_request,77)==nil,'unaccepted reply manifest cannot schedule an ACK-only acceptance exception')
for _,field in ipairs({'worker_id','worker_generation','enrolment_token','work_id','handle','expected_generation','controller_pane','controller_generation'})do
 local wrongf=launched_fixture(false);local publication=ack_request(wrongf,1)
 publication[field]=if type(publication[field])=='number' then publication[field]+1 else publication[field]..'-wrong'
 wrongf.d.request(publication,wrongf.binding,1,function()end)
 check(wrongf.raw.execution(publication,77)==nil,'ACK wake refuses changed launched binding: '..field)
end
local moved=launched_fixture(false);local moved_ack=ack_request(moved,1)
moved.d.request(moved_ack,moved.binding,1,function()end)
moved.saved['dispatch-v1'].requests['session/launch'].pane_binding.pane_id='66'
local moved_notify=moved.req('native_wake','moved-notify',{target_request_id=moved_ack.request_id,target_action_id=moved_ack.action_id})
check(moved.d.request(moved_notify,moved.binding,1,function()end).status=='rejected','pane reassociation cannot move an existing ACK wake without explicit attachment')
local poll=launched_fixture(true,true)
local poll_ack=ack_request(poll,2);poll.d.request(poll_ack,poll.binding,1,function()end);poll.d.request(wake_request,poll.binding,1,function()end)
check(poll.raw.execution(poll_ack,77)==nil and poll.raw.execution(wake_request,77)==nil and poll.d.request(poll_ack,poll.binding,1,function()end).payload==nil,'polling route never schedules native ACK or reply wake')
local retained=launched_fixture(false);retained.effects.retained_outcome={status='already_published'}
local retained_ack=ack_request(retained,1);retained.d.request(retained_ack,retained.binding,1,function()end)
check(retained.d.request(retained_ack,retained.binding,1,function()end).payload.wake_effect_started==false and retained.raw.execution(retained_ack,77)==nil and not retained.effects.transports,'already-published preparation retains unstarted ACK notification without a transport effect')
end
sections.authorization=function()
local staged=fixture();staged.effects.allow_mailbox=true
check(staged.raw.request(provision,staged.binding,1,function()end).status=='rejected' and not staged.effects.transports,'public request alone cannot authorize mailbox effects')
check(staged.raw.stage(provision,staged.binding,1,77).status=='pending' and not staged.effects.transports,'host membership only stages awaiting-window request')
check(staged.saved['dispatch-v1'].requests['session/provision'].authorization.deadline%1~=0,'authorization preserves native fractional monotonic milliseconds')
local challenge=staged.raw.execution(provision,77)
check(staged.raw.execution(provision,78)==nil,'another bridge cannot project the requested nonce')
local inspecting=staged.req('status','inspect-provision',{target_request_id=provision.request_id})
check(staged.raw.execution(inspecting,78)==nil and staged.raw.execution(inspecting,77).nonce==challenge.nonce,'status views preserve the authorization bridge boundary')
local before_duplicate=staged.image()
check(staged.raw.stage(provision,staged.binding,1,78).status=='pending' and staged.p.equal(before_duplicate,staged.image()),'duplicate public submission cannot rotate an unexpired nonce onto another bridge')
check(staged.raw.execution(provision,77).nonce==challenge.nonce,'origin bridge retains its exact live challenge')
check(challenge.kind=='authorize' and staged.raw.authorize(provision,'wrong',77,function()end,sourceclaim,'observer').status=='rejected','copied request cannot invent nonce')
check(staged.raw.authorize(provision,challenge.nonce,78,function()end,sourceclaim,'observer').status=='rejected','challenge bound to verified bridge')
local foreignclaim=copy(sourceclaim);foreignclaim.executor='other-epoch'
check(staged.raw.authorize(provision,challenge.nonce,77,function()end,foreignclaim,'observer').status=='rejected','challenge bound to exact origin executor')
staged.raw.authorize(provision,challenge.nonce,77,function()end,sourceclaim,'observer')
check(staged.effects.transports==1 and staged.p.equal(staged.saved['dispatch-v1'].requests['session/provision'].orch_claim,sourceclaim),'fresh nonce consumes exact claim before one transport effect')
check(staged.raw.authorize(provision,challenge.nonce,77,function()end,sourceclaim,'observer').status=='rejected' and staged.effects.transports==1,'nonce replay cannot execute twice')
local interrupted=fixture();interrupted.raw.stage(provision,interrupted.binding,1,77)
local oldchallenge=interrupted.raw.execution(provision,77)
local renewed=fixture(interrupted.image())
check(renewed.raw.authorize(provision,oldchallenge.nonce,77,function()end,sourceclaim,'observer').status=='rejected' and not renewed.effects.transports,'reload invalidates unconsumed window nonce')
renewed.raw.stage(provision,renewed.binding,1,77)
check(renewed.raw.execution(provision,77).nonce~=oldchallenge.nonce,'exact unexecuted request obtains fresh post-reload observation')
local expired=fixture();expired.raw.stage(provision,expired.binding,1,77)
local expired_challenge=expired.raw.execution(provision,77)
expired.effects.now=1700030001.25
local before_expiry=expired.image()
local expiry=expired.raw.authorize(provision,expired_challenge.nonce,77,function()end,sourceclaim,'observer')
check(expiry.status=='rejected' and expiry.error.message=='SPAWN authorization challenge expired before host consumption','expired authorization names its exact refusal without weakening freshness')
check(expired.raw.execution(provision,77)==nil and expired.p.equal(before_expiry,expired.image()) and not expired.effects.transports,'expiry exposes no executable nonce and starts no effect or retry')
local partial=fixture();partial.snapshot.records[1].mailbox.producer=nil;partial.snapshot.records[1].mailbox.capabilities=nil
local partialcat=partial.d.request(partial.req('catalog','partial'),partial.binding,1,function()end)
check(partialcat.status=='catalog' and not partialcat.payload.records[1].eligible,'partial mailbox config is ineligible, not a catalog exception')
end
-- An unconsumed challenge past its deadline or from an earlier host VM can never be consumed, so
-- status reports definitive pre-effect evidence instead of pending forever; re-staging the exact
-- request still obtains a fresh nonce.
sections.expired_authorization=function()
local function published(f)
 local outcome=f.d.request(wake_request,f.binding,1,function()end)
 if outcome.status=='pending' then outcome=f.d.request(wake_request,f.binding,1,function()end) end
 local payload=assert(outcome.payload,'publication outcome must identify its canonical notification')
 return f.req('native_wake','expiring-wake',{target_request_id=payload.wake_target_request_id,target_action_id=payload.wake_target_action_id})
end
local function outcome_of(f,wake)
 local body=f.d.request(f.req('status','inspect-'..wake.request_id,{target_request_id=wake.request_id}),f.binding,1,function()end)
 assert(body.status=='found','status must find the staged wake')
 return body.payload.outcome
end
local function pre_effect(body,r)
 return body.status=='full' and body.request_id==r.request_id and body.action_id==r.action_id and body.payload.resource=='window_authorization'
  and body.payload.current==1 and body.payload.limit==1 and body.payload.retryable==true and body.payload.effect_started==false
end
local f=launched_fixture(true);local wake=published(f)
check(f.raw.stage(wake,f.binding,1,77).status=='pending','host membership stages the wake behind a window challenge')
local first=f.raw.execution(wake,77)
check(first and first.kind=='authorize','the live challenge is projected to its bridge')
local live=outcome_of(f,wake)
check(live.status=='pending' and live.payload.authorization_required==true,'a still-live challenge reports pending')
f.effects.now=1700000000.25+30000
check(outcome_of(f,wake).status=='pending' and f.raw.execution(wake,77)~=nil,'a challenge at its exact deadline is still live')
f.effects.now=1700030001.25
local before=f.image()
local expired=outcome_of(f,wake)
check(pre_effect(expired,wake) and f.raw.execution(wake,77)==nil,'an expired unconsumed challenge reports definitive pre-effect full, never pending')
check(f.p.equal(before,f.image()),'expired-challenge status is a read-only projection')
check(f.raw.authorize(wake,first.nonce,77,function()end,sourceclaim,'fixture-window').status=='rejected','the expired nonce still cannot be consumed')
check(f.raw.stage(wake,f.binding,1,77).status=='pending','the identical request is staged again after expiry')
local second=f.raw.execution(wake,77)
check(second and second.nonce~=first.nonce and outcome_of(f,wake).status=='pending','re-staging issues a fresh live nonce that reports pending')
local resolved=f.raw.authorize(wake,second.nonce,77,function()end,{executor=wake.origin_binding.window_epoch,epoch=1,grant_id='expired-recheck-grant'},'fixture-window')
check(resolved.status=='resolved' and resolved.payload.wake_status=='awaiting_window' and outcome_of(f,wake).payload.wake_status=='awaiting_window','the freshly authorized wake resolves awaiting_window')
local g=launched_fixture(true);local rebooted_wake=published(g)
g.raw.stage(rebooted_wake,g.binding,1,77)
local rebooted=fixture(g.image()) -- A new host VM boot with the same registry and clock.
check(rebooted.raw.execution(rebooted_wake,77)==nil and pre_effect(outcome_of(rebooted,rebooted_wake),rebooted_wake),'a challenge from an earlier host VM reports definitive pre-effect full')
local capacity=fixture()
check(capacity.d.request(provision,capacity.binding,1,function()end).status=='full','fixture retains a pre-effect capacity refusal')
capacity.raw.stage(provision,capacity.binding,1,77)
capacity.effects.now=1700030001.25
local retained=outcome_of(capacity,provision)
check(retained.status=='full' and retained.payload.retryable==true and retained.payload.effect_started==false and retained.payload.resource~='window_authorization',
 'an expired recheck challenge reports its retained pre-effect base body')
end
sections.recovery=function()
local snapshotfail=fixture();snapshotfail.effects.allow_mailbox=true
snapshotfail.raw.stage(provision,snapshotfail.binding,1,77)
local failedgrant=snapshotfail.raw.execution(provision,77)
local snapshots=snapshotfail.authority.managed_snapshot
snapshotfail.authority.managed_snapshot=function()return nil,'injected snapshot unavailable'end
check(snapshotfail.raw.authorize(provision,failedgrant.nonce,77,function()end,sourceclaim,'observer').status=='rejected','snapshot failure is retained before nonce consumption')
check(snapshotfail.saved['dispatch-v1'].requests['session/provision'].authorization.phase=='requested' and not snapshotfail.effects.transports,'pre-effect prerequisite failure never consumes grant or starts operation')
snapshotfail.authority.managed_snapshot=snapshots
snapshotfail.raw.stage(provision,snapshotfail.binding,1,77)
local replacement=snapshotfail.raw.execution(provision,77)
check(replacement.nonce~=failedgrant.nonce,'exact recovery replay receives a fresh observation challenge')
snapshotfail.raw.authorize(provision,replacement.nonce,77,function()end,sourceclaim,'observer')
check(snapshotfail.effects.transports==1,'recovered snapshot permits one newly authorized effect')
local fencedwake=fixture();fencedwake.d.request(fencedwake.launch('wake-owner'),fencedwake.binding,1,function()end)
fencedwake.saved['dispatch-v1'].requests['session/wake']={request=copy(wake_request),body=fencedwake.p.body(wake_request,'published',{wake_status='launching'}),wake={phase='launching',pane_binding=copy(pane),claim={executor_id='window-a',boot='previous-boot'}}}
local inspection=fencedwake.d.recovery_view(fencedwake.binding);local saw_wake=false
for _,item in ipairs(inspection[1].outcomes)do if item.request_id=='wake' and item.wake.phase=='launching'then saw_wake=true end end
check(saw_wake,'recovery inspection includes native wake claims')
check(fencedwake.d.recover_owner(fencedwake.binding,'session',inspection[1].revision,false),'operator fence includes native wake executor')
check(fencedwake.saved['dispatch-v1'].requests['session/wake'].wake.phase=='uncertain' and fencedwake.saved['dispatch-v1'].requests['session/wake'].body.payload.wake_status=='uncertain','owner fencing retains possible native wake as uncertainty')
for _,boundary in ipairs({'snapshot','owner-fence'})do
 local retained=fixture();retained.d.request(retained.launch('owner'),retained.binding,1,function()end)
 local prior=retained.p.body(provision,'uncertain',nil,{code='target_unavailable',message='Original publication may have happened'})
 retained.saved['dispatch-v1'].requests['session/provision']={request=copy(provision),body=copy(prior),operation='original-operation'}
 retained.raw.stage(provision,retained.binding,1,77)
 if boundary=='snapshot'then
  local grant=retained.raw.execution(provision,77)
  retained.authority.managed_snapshot=function()return nil,'unavailable'end
  check(retained.p.equal(retained.raw.authorize(provision,grant.nonce,77,function()end,sourceclaim,'observer'),prior),'failed replay prerequisite restores exact prior uncertain outcome')
 else
  local view=retained.d.recovery_view(retained.binding)
  retained.d.recover_owner(retained.binding,'session',view[1].revision,false)
 end
 check(retained.p.equal(retained.saved['dispatch-v1'].requests['session/provision'].body,prior),'revoking requested replay never turns previous uncertainty into rejection')
end
local stagedread=fixture();stagedread.effects.allow_mailbox=true
local oldread=copy(provision);oldread.op='mailbox_read';oldread.request_id='unobserved-read';oldread.action_id='unobserved-action'
oldread.record_id=nil;oldread.record_revision=nil;oldread.capability=nil;oldread.handle='mailbox';oldread.expected_generation=1;oldread.selector={stream='ack',slot=1}
stagedread.raw.stage(oldread,stagedread.binding,1,77)
local currentread=copy(oldread);currentread.request_id='observed-read';currentread.action_id='observed-action'
stagedread.d.request(currentread,stagedread.binding,1,function()end)
check(stagedread.effects.transports==1,'unobserved public read challenge cannot occupy the authorized transport read slot')
end
sections.duplex=function()
-- Real dispatch + mailbox + adapter; only the target subprocess boundary is
-- injected. Helper fixtures separately exercise the actual shared lock.
for _,old_uncertainty in ipairs({false,true})do
 local duplex=fixture(nil,true)
 duplex.d.request(provision,duplex.binding,1,function()end)
 local opened=duplex.d.request(provision,duplex.binding,1,function()end)
 check(opened.status=='provisioned','real transport provision fixture establishes mailbox')
 local handle=opened.payload.handle
 local launch=duplex.launch('launch');launch.mailbox_handle=handle
 duplex.d.request(launch,duplex.binding,1,function()end)
 duplex.d.claim(launch,'executor-a','claim');duplex.d.claim(launch,'executor-a','begin')
 check(duplex.d.claim(launch,'executor-a','result',{status='submitted',pane_binding=pane}).status=='awaiting_acceptance','real provisioned native binding precedes ACK1')
 local ack={version=1,event_id=duplex.c.sha256(handle..':report:1'),seq=1,event_sha256=duplex.c.sha256('event'),committed_revision=2,disposition='accepted',receipt_chain_sha256=duplex.c.sha256('chain')}
 for _,name in ipairs({'logical_session_id','worker_id','worker_generation','launch_request_id','work_id'})do ack[name]=provision[name]end
 local bytes=runtime.json.encode(ack)
 local publication=copy(provision);publication.op='mailbox_publish_ack';publication.request_id='ack';publication.action_id='ack-action'
 publication.record_id=nil;publication.record_revision=nil;publication.capability=nil
 publication.handle=handle;publication.expected_generation=1;publication.receipt_revision=2;publication.ack_b64=runtime.base64.encode(bytes);publication.ack_sha256=duplex.c.sha256(bytes)
 if old_uncertainty then
  duplex.transport.fail_publish=true
  duplex.d.request(publication,duplex.binding,1,function()end)
  check(duplex.saved['dispatch-v1'].requests['session/ack'].body.status=='uncertain','earlier ambiguous publication remains retained')
 end
 duplex.transport.locked=true
 duplex.d.request(publication,duplex.binding,1,function()end)
 local blocked=duplex.saved['dispatch-v1'].requests['session/ack']
 if old_uncertainty then
  check(blocked.body.status=='uncertain' and blocked.operation~=nil,'admission refusal during readback cannot authorize a new write')
 else
  check(blocked.body.status=='full' and blocked.body.payload.retryable and blocked.body.payload.effect_started==false and blocked.operation==nil,'exited pre-effect admission refusal releases only its operation claim')
  local previous=copy(blocked.orch_claim)
  duplex.raw.stage(publication,duplex.binding,1,77)
  local retryGrant=duplex.raw.execution(publication,77)
  check(duplex.raw.authorize(publication,retryGrant.nonce,77,function()end,previous,'fixture-window').status=='rejected','same old ORCH+ grant cannot authorize capacity retry')
 end
 duplex.transport.locked=false;duplex.transport.fail_publish=false
 duplex.d.request(publication,duplex.binding,1,function()end)
 local settled=duplex.saved['dispatch-v1'].requests['session/ack'].body
 if old_uncertainty then
  local modes=duplex.transport.modes
  check(settled.status=='published' and duplex.transport.writes==1 and duplex.transport.files['acks/1.json']==bytes and modes[#modes-1]=='reconcile' and modes[#modes]=='publish',
   'older uncertain publication is read back first and republished once with the same bytes only after proving absence')
  duplex.d.request(publication,duplex.binding,1,function()end)
  check(duplex.transport.writes==1 and duplex.saved['dispatch-v1'].requests['session/ack'].body.status=='published','settled readback publication is never written again')
  local fresh=copy(publication);fresh.request_id='ack-readback';fresh.action_id='ack-readback-action'
  check(duplex.d.request(fresh,duplex.binding,1,function()end).status=='published' and duplex.transport.writes==1,'a new request for the same immutable bytes returns the settled publication without another write')
 else
  check(settled.status=='published' and duplex.transport.writes==1 and duplex.transport.files['acks/1.json']==bytes,'same immutable bridge request publishes once after contention clears')
  check(settled.payload.wake_status=='awaiting_window' and duplex.raw.execution(publication,77)==nil,'real ACK settlement retains receipt wake without occupying execution before semantic accept')
  local notification=queue_wake(duplex,publication)
  duplex.d.wake_claim(notification,'window-a','wakeclaim');duplex.d.wake_claim(notification,'window-a','wakebegin')
  check(duplex.d.wake_claim(notification,'window-a','wakeresult',{status='submitted'}).status=='submitted','separately granted receipt wake completes before semantic accept')
  local acceptance=duplex.req('accept','accept',{target_request_id='launch',target_action_id=launch.action_id,pane_binding=pane,worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=ack.event_id,seq=1,event_sha256=ack.event_sha256})
  check(duplex.d.request(acceptance,duplex.binding,1,function()end).status=='accepted','semantic acceptance remains a separate exact launch operation')
  ack.seq=2;ack.event_id=duplex.c.sha256(handle..':report:2');ack.event_sha256=duplex.c.sha256('reply_ack');ack.committed_revision=3;ack.receipt_chain_sha256=duplex.c.sha256('chain2')
  local bytes2=runtime.json.encode(ack);local ack2=copy(publication)
  ack2.request_id='ack2';ack2.action_id='ack2-action';ack2.receipt_revision=3;ack2.ack_b64=runtime.base64.encode(bytes2);ack2.ack_sha256=duplex.c.sha256(bytes2)
  duplex.d.request(ack2,duplex.binding,1,function()end)
  check(duplex.transport.writes==2 and duplex.transport.files['acks/2.json']==bytes2 and duplex.raw.execution(ack2,77)==nil,'real ACK2 publishes without coupling publication to native execution')
  local notification2=queue_wake(duplex,ack2)
  check(duplex.raw.execution(notification2,77).phase=='resolved','accepted native worker receives a separately granted receipt wake')
 end
end
end
local function retirement_fixture(control)
 local f=fixture()
 if control~=false then table.insert(f.snapshot.records[1].mailbox.capabilities,'coordinator-control-v1') end
 local launch=f.launch('launch');f.d.request(launch,f.binding,1,function()end)
 f.d.claim(launch,'executor','claim');f.d.claim(launch,'executor','begin')
 f.d.claim(launch,'executor','result',{status='submitted',pane_binding=pane})
 local accept=f.req('accept','accept',{target_request_id='launch',target_action_id='action-launch',pane_binding=pane,worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('accepted')})
 f.d.request(accept,f.binding,1,function()end)
 local stop=f.req('stop','stop',{target_request_id='launch',target_action_id='action-launch',pane_binding=copy(pane),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work'})
 return f,stop
end
sections.retirement_binding=function()
 local f,stop=retirement_fixture()
 check(f.p.decode(runtime.json.encode(stop))~=nil,'closed exact stop request accepted')
 local extra=copy(stop);extra.command='kill';check(f.p.decode(runtime.json.encode(extra))==nil,'stop has no arbitrary command escape')
 for _,field in ipairs({'target_request_id','target_action_id','worker_id','enrolment_token','work_id'})do
  local bad=copy(stop);bad.request_id='bad-'..field;bad[field]='wrong-binding-value'
  check(f.d.request(bad,f.binding,1,function()end).status=='rejected','stop rejects wrong '..field)
 end
 local bad=copy(stop);bad.request_id='bad-generation';bad.worker_generation=2
 check(f.d.request(bad,f.binding,1,function()end).status=='rejected','stop rejects successor worker generation')
 bad=copy(stop);bad.request_id='bad-pane';bad.pane_binding.pane_id='56'
 check(f.d.request(bad,f.binding,1,function()end).status=='rejected','stop cannot select another native pane')
 check(f.raw.request(stop,f.binding,1,function()end).status=='rejected','stop requires fresh exact ORCH+ authorization')
 check(f.d.request(stop,f.binding,1,function()end).status=='resolved','authorized accepted binding resolves stop')
 check(f.d.stop_claim(stop,'window-a','claim').status=='claimed','stop exclusive claim persisted')
 check(f.d.stop_claim(stop,'window-b','begin').status=='rejected','another executor cannot begin stop')
 check(f.d.stop_claim(stop,'window-a','begin').status=='launching','stop intent committed before native effect')
 local wrong={status='stopped',pane_binding=copy(pane),observation='absent'};wrong.pane_binding.pane_id='56'
 check(f.d.stop_claim(stop,'window-a','result',wrong).status=='rejected','native outcome must bind exact issued pane')
 local lost=fixture(f.image())
 check(lost.d.request(stop,lost.binding,1,function()end).status=='uncertain','lost stop completion remains occupied after reload')
 check(lost.raw.execution(stop,77)==nil,'lost stop cannot be executed again')
 check(lost.d.stop_claim(stop,'window-a','result',{status='stopped',pane_binding=pane,observation='absent'}).status=='rejected','late result cannot cross host execution incarnation')
 local second=copy(stop);second.request_id='second-stop';second.action_id='second-stop-action'
 check(lost.d.request(second,lost.binding,1,function()end).status=='rejected','new request cannot repeat ambiguous stop')
 local old,legacy=retirement_fixture(false)
 check(old.d.request(legacy,old.binding,1,function()end).status=='resolved','ordinary accepted worker can stop without inventing coordinator capability')
 f.effects.fail_write=true
 check(f.d.stop_claim(stop,'window-a','result',{status='stopped',pane_binding=pane,observation='absent'}).error.code=='storage_error' and f.effects.retirements==nil,'failed stopped evidence commit cannot settle reservation')
end
sections.retirement_settlement=function()
 local f,stop=retirement_fixture()
 f.d.request(stop,f.binding,1,function()end)
 f.host_event(stop,'claim');f.host_event(stop,'begin')
 local stopped=f.host_event(stop,'result',{status='stopped',pane_binding=pane,observation='absent'})
 check(stopped.status=='stopped' and f.p.equal(stopped.payload,{pane_binding=pane,observation='absent'}),'host routes exact native stopped outcome')
 check(f.effects.retirements==nil,'native stop alone does not release launch reservation')
 check(f.p.equal(f.d.request(stop,f.binding,1,function()end),stopped),'duplicate stop replays immutable outcome')
 local retire=f.req('mailbox_retire','retire',{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,mode='retire',settlement_revision=5,report_floor=3,report_chain_sha256=f.c.sha256('settled'),reply_floor=1,grant_id='retirement-grant'})
 f.effects.allow_mailbox=true;f.effects.outcome={status='uncertain'}
 f.d.request(retire,f.binding,1,function()end)
 check(f.effects.operation.retire_producer==true,'matching committed stop alone grants private producer cleanup')
 check(f.effects.retirements==nil,'uncertain mailbox retirement retains reservation')
 f.effects.outcome={status='retired'};f.effects.fail_retire=true
 f.d.request(retire,f.binding,1,function()end)
 check(f.saved['dispatch-v1'].requests['session/retire'].body.status=='uncertain' and f.effects.retirements==1,'reservation commit failure preserves durable retired evidence and occupancy')
 local attempts=f.effects.transports;f.effects.fail_retire=false
 check(f.d.request(retire,f.binding,1,function()end).status=='retired' and f.effects.transports==attempts,'reservation reconciliation never repeats mailbox retirement')
 local args=f.effects.retire_args
 check(args[2]=='attempt-1' and args[3]=='managed-'..f.c.sha256('session/launch') and args[4]=='worker' and args[5]==55,'only exact launch attempt observer record and pane are settled')
 check(f.d.request(retire,f.binding,1,function()end).status=='retired' and f.effects.retirements==2,'settled retirement replays without another reservation mutation')
 local restored=fixture(f.image())
 check(restored.d.request(stop,restored.binding,1,function()end).status=='stopped','native stop evidence survives restoration unchanged')
end
sections.retirement_producer=function()
 local f,stop=retirement_fixture(false)
 local retire=f.req('mailbox_retire','ordinary-retire',{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,mode='retire',settlement_revision=5,report_floor=3,report_chain_sha256=f.c.sha256('settled'),reply_floor=1,grant_id='retirement-grant'})
 local injected=copy(retire);injected.retire_producer=true
 check(f.p.decode(runtime.json.encode(injected))==nil,'public mailbox retirement cannot request private producer cleanup')
 f.effects.allow_mailbox=true;f.effects.outcome={status='incomplete'}
 check(f.d.request(retire,f.binding,1,function()end).status=='rejected' and f.effects.operation==nil,'ordinary managed retirement requires exact native stop before any cleanup')
 f.d.request(stop,f.binding,1,function()end);f.d.stop_claim(stop,'executor','claim');f.d.stop_claim(stop,'executor','begin')
 local premature=copy(retire);premature.request_id='premature';premature.action_id='premature-action'
 local calls=f.effects.transports
 check(f.d.request(premature,f.binding,1,function()end).status=='rejected' and f.effects.transports==calls,'in-flight native stop cannot authorize producer deletion')
 f.d.stop_claim(stop,'executor','result',{status='stopped',pane_binding=pane,observation='exited'})
 local authorized=copy(retire);authorized.request_id='authorized';authorized.action_id='authorized-action'
 f.effects.outcome={status='retired'};f.d.request(authorized,f.binding,1,function()end)
 check(f.effects.operation.retire_producer==true and f.effects.retirements==1,'committed exact stop grants producer cleanup before reservation settlement')
end
sections.coordinator_launch=function()
 local f=fixture()
 local launch=f.launch('coordinator',{coordinator_owner_id='coordinator-owner',coordinator_generation=2})
 check(f.p.decode(runtime.json.encode(launch))~=nil,'paired coordinator enrolment accepted')
 local partial=copy(launch);partial.enrolment.coordinator_generation=nil
 check(f.p.decode(runtime.json.encode(partial))==nil,'partial coordinator enrolment refused')
 partial=copy(launch);partial.enrolment.coordinator_generation=0
 check(f.p.decode(runtime.json.encode(partial))==nil,'coordinator generation must be positive')
 check(f.d.request(launch,f.binding,1,function()end).error.code=='unsupported_capability' and f.effects.reserves==0,'old ordinary-only record cannot reserve coordinator launch')
 local configured=fixture()
 table.insert(configured.snapshot.records[1].mailbox.capabilities,'coordinator-control-v1')
 local ordinary=configured.launch('ordinary')
 check(configured.d.request(ordinary,configured.binding,1,function()end).status=='resolved','capable record still supports ordinary launch')
 check(not configured.d.execution(ordinary,77).launch.prompt:find('COORDINATOR TRANSPORT ROLE',1,true),'ordinary task does not infer coordinator role or wait for activation')
 local coordinator=configured.launch('coordinator',{coordinator_owner_id='coordinator-owner',coordinator_generation=2})
 check(configured.d.request(coordinator,configured.binding,1,function()end).status=='resolved','explicit coordinator role launches on approved capable record')
 local projection=configured.d.execution(coordinator,77)
 check(projection.launch.prompt:find('COORDINATOR TRANSPORT ROLE',1,true)~=nil and projection.launch.prompt:find('do not perform coordinator work yet',1,true)~=nil,'explicit coordinator preface fences work until typed activation')
 check(projection.launch.prompt:sub(-#coordinator.prompt)==coordinator.prompt and configured.c.sha256(coordinator.prompt)==coordinator.enrolment.assignment_sha256,'coordinator transport preface preserves original assignment bytes and digest')
 check(projection.request.enrolment.coordinator_owner_id=='coordinator-owner' and projection.request.enrolment.coordinator_generation==2,'issued launch retains exact reserved coordinator identity')
end
sections.wake_capacity=function()
 local f=fixture();local publications={}
 for i=1,5 do
  local launch=f.launch('launch-'..i,{worker_id='worker-'..i});launch.mailbox_handle='mailbox-'..i
  check(f.d.request(launch,f.binding,1,function()end).status=='resolved','worker launch reserved')
  f.d.claim(launch,'executor','claim');f.d.claim(launch,'executor','begin')
  local selected=copy(pane);selected.pane_id=tostring(55+i)
  f.d.claim(launch,'executor','result',{status='submitted',pane_binding=selected})
  local p=ack_request(f,1);p.request_id='ack-worker-'..i;p.action_id='action-'..p.request_id
  p.worker_id='worker-'..i;p.launch_request_id=launch.request_id;p.handle=launch.mailbox_handle
  f.effects.allow_mailbox=true;f.effects.outcome={status='published'}
  f.d.request(p,f.binding,1,function()end);publications[i]=p
  check(f.d.request(p,f.binding,1,function()end).payload.wake_effect_started==false,'waiting ACK retains a durable unstarted obligation')
 end
 local read=f.req('mailbox_read','independent-read',{logical_session_id='session',worker_id='worker-5',worker_generation=1,launch_request_id='launch-5',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox-5',expected_generation=1,selector={stream='watermark'}})
 f.effects.outcome={status='missing'}
 f.d.request(read,f.binding,1,function()end)
 check(f.d.request(read,f.binding,1,function()end).status=='missing','four waiting workers do not block independent transport progress')
 local wakes={}
 for i=1,4 do
  wakes[i]=queue_wake(f,publications[i])
  check(f.raw.execution(wakes[i],77).kind=='wake','bounded separate notification reserves an execution slot')
 end
 local blocked=queue_wake(f,publications[5])
 check(f.d.request(blocked,f.binding,1,function()end).status=='full','fifth executing notification is refused at four-host limit')
 local blocked_read=copy(read);blocked_read.request_id='blocked-read';blocked_read.action_id='action-blocked-read'
 check(f.d.request(blocked_read,f.binding,1,function()end).status=='full','started notification reservations share the transport host budget')
 local old=copy(f.saved['dispatch-v1'].requests['session/'..wakes[1].request_id].orch_claim)
 local deferred=f.d.wake_claim(wakes[1],'window-a','wakedefer',nil,old)
 check(deferred.status=='full' and deferred.payload.effect_started==false,'busy native refusal releases only a proven unstarted notification')
 check(f.d.request(blocked_read,f.binding,1,function()end).status=='pending','freed execution slot admits independent transport')
 f.d.request(wakes[1],f.binding,1,function()end)
 check(f.d.wake_claim(wakes[1],'window-a','wakeclaim',nil,old).status=='rejected','late old grant cannot claim the safely deferred operation')
 f.d.wake_claim(wakes[1],'window-a','wakeclaim');f.d.wake_claim(wakes[1],'window-a','wakebegin');f.d.wake_claim(wakes[1],'window-a','wakeresult',{status='submitted'})
 local duplicate=copy(publications[1]);duplicate.request_id='duplicate-ack';duplicate.action_id='duplicate-action'
 f.effects.outcome={status='already_published'};f.d.request(duplicate,f.binding,1,function()end)
 local outcome=f.d.request(duplicate,f.binding,1,function()end)
 check(outcome.payload.wake_status=='submitted' and outcome.payload.wake_target_request_id==publications[1].request_id,'publication retry under a distinct ID preserves once-only canonical notification')
 local restored=fixture(f.image())
 check(restored.d.request(duplicate,restored.binding,1,function()end).payload.wake_status=='submitted','once-only notification survives reload')
end
local function attachment_request(f,id)
 local r=f.req('attach_worker',id,{target_request_id='launch',target_action_id='action-launch',previous_origin_binding=copy(f.origin),previous_pane_binding=copy(pane),pane_binding=copy(pane),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',attestation='old_executors_stopped_or_retired'})
 r.origin_binding.window_epoch='new-epoch';r.origin_binding.window_key='new-window';r.origin_binding.alias_nonce='new-alias';r.controller_pane='88'
 r.pane_binding.window_epoch='new-epoch';r.pane_binding.window_key='new-window';r.pane_binding.pane_id='99'
 return r
end
sections.attachment=function()
 local f=launched_fixture(true);local publication=ack_request(f,2)
 f.d.request(publication,f.binding,1,function()end)
 local r=attachment_request(f,'attach')
 check(f.p.decode(runtime.json.encode(r))~=nil,'explicit attachment uses a closed operation schema')
 local missing=copy(r);missing.attestation=nil
 check(f.p.decode(runtime.json.encode(missing))==nil,'attachment cannot omit owner executor attestation')
 local query=f.req('status','new-window-status',{target_request_id='launch'});query.origin_binding=copy(r.origin_binding);query.controller_pane=r.controller_pane
 local before=f.image();local status=f.d.request(query,f.binding,1,function()end)
 check(status.status=='found' and f.p.equal(status.payload.outcome.origin_binding,f.origin) and f.p.equal(before,f.image()),'new-window status reads original outcome without attaching or mutating')
 check(f.raw.execution(query,77)==nil,'pre-attachment inspection cannot execute an old claim')
 local original=copy(f.saved['dispatch-v1'].requests['session/launch'].request)
 local result=f.d.request(r,f.binding,1,function()end)
 check(result.status=='attached' and f.p.equal(result.payload.pane_binding,r.pane_binding),'owner-selected exact current pane attaches explicitly')
 check(f.p.equal(f.saved['dispatch-v1'].requests['session/launch'].request,original) and f.p.equal(f.saved['dispatch-v1'].requests['session/launch'].pane_binding,pane),'attachment preserves immutable launch bytes and original pane evidence')
 check(f.d.claim(original,'executor-a','result',{status='submitted',pane_binding=pane}).status=='rejected','old native result rejected after owner route attachment')
 local oldquery=f.req('status','old-status',{target_request_id='launch'})
 check(f.d.request(oldquery,f.binding,1,function()end).status=='found' and f.raw.execution(oldquery,77)==nil,'old immutable outcome stays read-only after attachment')
 local notify=f.req('native_wake','attached-wake',{target_request_id=publication.request_id,target_action_id=publication.action_id});notify.origin_binding=copy(r.origin_binding);notify.controller_pane=r.controller_pane
 check(f.d.request(notify,f.binding,1,function()end).status=='resolved' and f.p.equal(f.raw.execution(notify,77).pane_binding,r.pane_binding),'existing unstarted ACK notification uses only the explicitly attached route')
 f.d.wake_claim(notify,'new-window','wakeclaim');f.d.wake_claim(notify,'new-window','wakebegin');f.d.wake_claim(notify,'new-window','wakeresult',{status='submitted'})
 local stop=f.req('stop','attached-stop',{target_request_id='launch',target_action_id='action-launch',pane_binding=copy(r.pane_binding),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work'})
 stop.origin_binding=copy(r.origin_binding);stop.controller_pane=r.controller_pane
 check(f.d.request(stop,f.binding,1,function()end).status=='resolved','ordinary attached worker retains exact stop path')
end
sections.attachment_recovery=function()
 local f=launched_fixture(true)
 local safe=f.launch('safe-launch',{worker_id='safe-worker'});safe.mailbox_handle='safe-mailbox'
 f.d.request(safe,f.binding,1,function()end);f.d.claim(safe,'safe-executor','claim');f.d.claim(safe,'safe-executor','begin')
 local safe_pane=copy(pane);safe_pane.pane_id='65'
 f.d.claim(safe,'safe-executor','result',{status='submitted',pane_binding=safe_pane})
 local notify=queue_wake(f,ack_request(f,2))
 f.d.wake_claim(notify,'old-executor','wakeclaim');f.d.wake_claim(notify,'old-executor','wakebegin')
 local r=attachment_request(f,'blocked-attach')
 check(f.d.request(r,f.binding,1,function()end).status=='rejected','active old wake prevents attachment')
 local owners=f.d.recovery_view(f.binding)
 check(f.d.recover_owner(f.binding,'session',owners[1].revision,false),'explicit Config recovery fences old executors')
 owners=f.d.recovery_view(f.binding)
 check(f.d.recover_owner(f.binding,'session',owners[1].revision,true),'exact-revision attestation retires executor authority, not outcome')
 r.request_id='recovered-attach';r.action_id='action-recovered-attach'
 check(f.d.request(r,f.binding,1,function()end).status=='attached','explicitly retired executor records do not prohibit attachment forever')
 check(f.saved['dispatch-v1'].requests['session/'..notify.request_id].body.status=='uncertain','attachment does not pretend the original native wake succeeded')
 check(f.d.wake_claim(notify,'old-executor','wakeresult',{status='submitted'}).status=='rejected','retired old executor cannot deliver a late outcome')
 local read=f.req('mailbox_read','held-generation',{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,selector={stream='watermark'}})
 read.origin_binding=copy(r.origin_binding);read.controller_pane=r.controller_pane
 check(f.d.request(read,f.binding,1,function()end).status=='full','unknown earlier wake continues to hold its exact generation after attachment')
 local attach_safe=attachment_request(f,'attach-safe');attach_safe.target_request_id=safe.request_id;attach_safe.target_action_id=safe.action_id;attach_safe.worker_id='safe-worker';attach_safe.previous_pane_binding=safe_pane;attach_safe.pane_binding.pane_id='109'
 check(f.d.request(attach_safe,f.binding,1,function()end).status=='attached','unrelated safe worker attaches while retired uncertain generation stays held')
 local safe_read=copy(read);safe_read.request_id='safe-read';safe_read.action_id='action-safe-read';safe_read.worker_id='safe-worker';safe_read.launch_request_id=safe.request_id;safe_read.handle='safe-mailbox'
 f.effects.outcome={status='missing'};f.d.request(safe_read,f.binding,1,function()end)
 check(f.d.request(safe_read,f.binding,1,function()end).status=='missing','retired unknown wake does not occupy unrelated worker execution capacity')
end
sections.wake_retention=function()
 local f=launched_fixture(true)
 for seq=1,32 do
  local publication=ack_request(f,seq)
  f.d.request(publication,f.binding,1,function()end)
 end
 local over=ack_request(f,33);local calls=f.effects.transports
 local refused=f.d.request(over,f.binding,1,function()end)
 check(refused.status=='full' and refused.payload.resource=='wake_obligations' and refused.payload.effect_started==false and f.effects.transports==calls,'32 waiting obligations impose pre-effect backpressure without dropping an ACK wake')
 local compact=f.req('mailbox_retire','compact-waiting',{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,mode='compact',settlement_revision=40,report_floor=32,report_chain_sha256=f.c.sha256('settled'),reply_floor=0,grant_id='compact-grant'})
 f.effects.outcome={status='compacted'};f.d.request(compact,f.binding,1,function()end)
 local pending=0
 for _,entry in pairs(f.saved['dispatch-v1'].requests) do if entry.wake then pending+=1 end end
 check(pending==32,'settled transport compaction cannot silently remove pending native notifications')
 local first=ack_request(f,1);local wake=queue_wake(f,first)
 local original=copy(f.saved['dispatch-v1'].requests['session/'..wake.request_id].orch_claim)
 f.d.wake_claim(wake,'executor','wakeclaim');f.d.wake_claim(wake,'executor','wakebegin')
 local deferred=f.d.wake_claim(wake,'executor','wakedefer')
 check(deferred.status=='full' and deferred.payload.effect_started==false,'exact executor can release a begun but never-asked wake')
 f.d.request(wake,f.binding,1,function()end)
 check(f.d.wake_claim(wake,'executor','wakeresult',{status='submitted'},original).status=='rejected','late outcome for retired pre-effect grant cannot settle replacement grant')
 local reloaded=fixture(f.image())
 check(reloaded.raw.execution(wake,77)==nil,'reload fences even reserved notification before native claim')
 local query=reloaded.req('status','reserved-status',{target_request_id=wake.request_id})
 local result=reloaded.d.request(query,reloaded.binding,1,function()end).payload.outcome
 check(result.status=='full' and result.payload.effect_started==false,'durable never-claimed reservation gives conclusive pre-effect refusal after reload')
 check(reloaded.d.wake_claim(wake,'executor','wakeclaim',nil,original).status=='rejected','late old claim cannot regain the fenced unstarted reservation')
end
sections.authority_rotation=function()
 local f=fixture();local r=f.launch('rotation-launch')
 check(f.d.request(r,f.binding,1,function()end).status=='resolved','managed launch admitted before ordinary transport rotation')
 local current=copy(f.binding);current.authority_id='host:2'
 local catalog=f.d.request(f.req('catalog','rotated-catalog'),current,1,function()end)
 check(catalog.status=='catalog','ordinary transport rotation does not occupy managed controller anew')
 check(catalog.payload.namespace=='host' and catalog.payload.host_key=='host:test' and catalog.payload.config_revision==catalog.payload.revision,'catalog exports exact version-three roster join')
 check(#f.d.recovery_view(current)==1,'recovery view follows stable managed authority across rotation')
 f.d.claim(r,'window-a','claim')
 check(f.d.claim(r,'window-a','begin').status=='launching','original exact grant can begin against stable managed scope')
 check(f.d.claim(r,'window-a','result',{status='submitted',pane_binding=pane}).status=='awaiting_acceptance','original result identity survives transport rotation')
 local moved=f.req('catalog','moved-catalog');moved.origin_binding.window_epoch='replacement'
 check(f.d.request(moved,current,1,function()end).status=='rejected','transport rotation never authorizes a replacement execution origin')
 local rows=f.d.recovery_view(current)
 check(f.d.recover_owner(current,'session',rows[1].revision,false),'stable identity retains explicit owner recovery')
 check(f.d.claim(r,'window-a','result',{status='submitted',pane_binding=pane}).status=='rejected','recovery fences delayed native callbacks even after transport rotation')
end
sections.host_local=function()
 local function terminal(f,backend)
  local record=f.snapshot.records[1]
  record.backend=backend;record.fresh_native_default=nil;record.fresh_executable='worker';record.fresh_arguments={};record.task_argument_index=1
  record.mailbox.wake='worker-poll-v1';record.mailbox.producer.poll=true
  record.mailbox.capabilities={'report-files-v1','worker-poll-v1','argv-v1'}
  return record
 end
 local ssh=fixture();local record=terminal(ssh,'ssh-command')
 record.host='target';record.target_os='linux';record.target_shell='sh'
 local catalog=ssh.d.request(ssh.req('catalog','ssh-catalog'),ssh.binding,1,function()end)
 local row=catalog.payload.records[1]
 check(not row.eligible and table.concat(row.unsupported,'; '):find('run ORCH+ on target host',1,true)~=nil,'SSH catalog explains the same-host ORCH+ remedy')
 ssh.effects.allow_mailbox=true
 local refused=ssh.d.request(provision,ssh.binding,1,function()end)
 check(refused.error.code=='unsupported_capability' and not ssh.effects.prepares and not ssh.effects.transports,'direct authorized SSH provision stops before transport preparation')
 refused=ssh.d.request(ssh.launch('ssh-launch'),ssh.binding,1,function()end)
 check(refused.error.code=='unsupported_capability' and ssh.effects.reserves==0,'direct authorized SSH launch stops before reservation')
 for _,backend in ipairs({'native-agent','local-terminal'})do
  for _,host in ipairs({'host:local','host:attached-target'})do
   local f=fixture();f.snapshot.host_key=host;f.binding.host_key=host
   local selected=if backend=='local-terminal' then terminal(f,backend) else f.snapshot.records[1]
   selected.host=host:sub(6)
   -- Client hints deliberately disagree: only execution-host OS/shell decide.
   f.snapshot.os='windows';f.snapshot.shell='cmd.exe'
   local c=f.d.request(f.req('catalog','same-host-catalog'),f.binding,1,function()end)
   check(c.payload.records[1].eligible,backend..' remains eligible on '..host)
   f.effects.allow_mailbox=true
   check(f.d.request(provision,f.binding,1,function()end).status=='pending' and f.effects.transports==1,'same-host provisioning reaches transport on '..host)
   local launch=f.launch('same-host-launch')
   check(f.d.request(launch,f.binding,1,function()end).status=='resolved' and f.effects.reserves==1,'same-host launch reserves on '..host)
   f.d.claim(launch,'same-host-executor','claim')
   check(f.d.claim(launch,'same-host-executor','begin').status=='launching','same-host launch begins on '..host)
  end
 end
 for _,revision_changed in ipairs({false,true})do
  local f=fixture();local launch=f.launch('selection-changed')
  check(f.d.request(launch,f.binding,1,function()end).status=='resolved','initial same-host selection resolves')
  f.d.claim(launch,'stale-executor','claim')
  terminal(f,'ssh-command').host='target'
  if revision_changed then f.snapshot.config_revision+=1 end
  refused=f.d.claim(launch,'stale-executor','begin')
  check(refused.status=='rejected' and refused.error.code==(if revision_changed then 'binding_mismatch' else 'unsupported_capability'),'changed selection cannot begin a managed SSH effect')
 end
 local staged=fixture();staged.effects.allow_mailbox=true
 staged.raw.stage(provision,staged.binding,1,77)
 local grant=staged.raw.execution(provision,77)
 terminal(staged,'ssh-command').host='target'
 refused=staged.raw.authorize(provision,grant.nonce,77,function()end,sourceclaim,'fixture-window')
 check(refused.error.code=='unsupported_capability' and not staged.effects.transports,'configuration change between staging and authorization cannot provision SSH')
 for _,phase in ipairs({'resolved','claimed','launching','uncertain','awaiting_acceptance'})do
  local f=fixture();local launch=f.launch('legacy-ssh')
  f.d.request(launch,f.binding,1,function()end)
  if phase=='claimed' or phase=='launching' or phase=='awaiting_acceptance' then f.d.claim(launch,'legacy-executor','claim') end
  if phase=='launching' or phase=='awaiting_acceptance' then f.d.claim(launch,'legacy-executor','begin') end
  if phase=='awaiting_acceptance' then f.d.claim(launch,'legacy-executor','result',{status='submitted',pane_binding=pane}) end
  local entry=f.saved['dispatch-v1'].requests['session/legacy-ssh']
  entry.launch.backend='ssh-command';entry.launch_sha256=f.p.fingerprint(entry.launch);entry.body.status=phase
  local before=copy(entry)
  check(f.d.execution(launch,77)==nil,'retained SSH '..phase..' never exposes executable projection')
  check(f.d.claim(launch,'legacy-executor','claim').status=='rejected' and f.d.claim(launch,'legacy-executor','begin').status=='rejected','bypassed retained SSH '..phase..' cannot start')
  local status=f.d.request(f.req('status','legacy-status',{target_request_id='legacy-ssh'}),f.binding,1,function()end)
  check(status.payload.outcome.status==phase and f.p.equal(before,f.saved['dispatch-v1'].requests['session/legacy-ssh']),'retained SSH '..phase..' remains exact and inspectable')
  if phase=='claimed' or phase=='launching' or phase=='uncertain' then
   local restored=fixture(f.image())
   local retained=restored.d.request(restored.req('status','reload-legacy',{target_request_id='legacy-ssh'}),restored.binding,1,function()end)
   check(retained.payload.outcome.status=='uncertain' and restored.saved['dispatch-v1'].requests['session/legacy-ssh'].launch.backend=='ssh-command','reload preserves unknown SSH occupancy without replay or conversion')
  end
  if phase=='launching' then
   check(f.d.claim(launch,'legacy-executor','result',{status='uncertain',message='Retained executor outcome unknown'}).status=='uncertain','existing SSH executor may report its exact unknown result without starting again')
  end
 end
end
-- ORCH+ CP4 worker rollover: a fresh successor launch binds the immutable handover pair,
-- and semantic acceptance requires exactly that pair.
sections.rollover_accept=function()
local f=fixture()
local token='handover-token-1234'
local l=f.launch('successor',{handover_id='handover-1',handover_token=token})
check(f.d.request(l,f.binding,1,function()end).status=='resolved','rollover successor uses the ordinary fresh launch reservation')
local projection=f.d.execution(l,77)
check(projection.launch.prompt:find('handover-1',1,true)~=nil and projection.launch.prompt:find(token,1,true)~=nil,'successor preface carries the issued handover pair')
check(projection.launch.prompt:sub(-#l.prompt)==l.prompt,'checkpoint assignment bytes stay unchanged after the preface')
check(f.d.claim(l,'executor-a','claim').status=='claimed','successor launch claimed once')
check(f.d.claim(l,'executor-a','begin').status=='launching','successor launch intent durable before native effect')
check(f.d.claim(l,'executor-a','result',{status='submitted',pane_binding=pane}).status=='awaiting_acceptance','successor pane is not handover acceptance')
local base={target_request_id='successor',target_action_id='action-successor',pane_binding=pane,worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('accepted successor')}
check(f.d.request(f.req('accept','accept-missing',copy(base)),f.binding,1,function()end).status=='rejected','rollover acceptance without the handover pair is rejected')
local wrong=copy(base);wrong.handover_id='handover-1';wrong.handover_token='wrong-token-123456'
check(f.d.request(f.req('accept','accept-wrong',wrong),f.binding,1,function()end).status=='rejected','wrong handover token is rejected')
local exact=copy(base);exact.handover_id='handover-1';exact.handover_token=token
check(f.d.request(f.req('accept','accept-exact',exact),f.binding,1,function()end).status=='accepted','exact handover pair records semantic acceptance')
check(f.d.request(f.req('accept','accept-exact',exact),f.binding,1,function()end).status=='accepted','exact rollover acceptance replays')
end
-- ORCH+ explicit verified attach: the shared preface delivered once by native ask to an exact
-- owner-attested existing agent pane; same claim/at-most-once/uncertainty rules as launch.
sections.adopt=function()
local function adopt_request(f,id,binding)
 local l=f.launch(id) -- provisions the fixture mailbox binding for this request ID
 return f.req('adopt',id,{record_id=l.record_id,record_revision=l.record_revision,work_id=l.work_id,prompt=l.prompt,mailbox_handle=l.mailbox_handle,enrolment=l.enrolment,pane_binding=binding or copy(pane),attestation='operator_verified_exact_agent_pane'})
end
local f=fixture()
local r=adopt_request(f,'adopt')
check(f.p.decode(runtime.json.encode(r))~=nil,'adopt is a closed public request')
local bad=copy(r);bad.attestation='trusted';check(f.p.decode(runtime.json.encode(bad))==nil,'adopt requires the exact operator attestation')
bad=copy(r);bad.enrolment.handover_id='handover';bad.enrolment.handover_token='handover-token-1234';check(f.p.decode(runtime.json.encode(bad))==nil,'adoption never carries a handover pair')
bad=copy(r);bad.cwd='/work';check(f.p.decode(runtime.json.encode(bad))==nil,'adopt carries no launch command fields')
bad=copy(r);bad.pane_binding=nil;check(f.p.decode(runtime.json.encode(bad))==nil,'adopt requires the exact pane binding')
check(f.d.request(r,f.binding,1,function()end).status=='resolved' and f.effects.reserves==0,'adoption resolves without reserving or starting a managed launch')
local projection=f.d.execution(r,77)
check(projection.kind=='adopt' and projection.launch==nil and projection.prompt:find('report-files-v1',1,true)~=nil and projection.prompt:sub(-#r.prompt)==r.prompt,'adopt projection carries the shared transport preface and exact assignment bytes, never a launch command')
check(f.d.claim(r,'executor-a','claim').status=='claimed','adopt claimed once')
check(f.d.claim(r,'executor-b','claim').status=='claimed' and f.d.execution(r,77).claim.executor_id=='executor-a','another executor cannot steal the adopt claim')
check(f.d.claim(r,'executor-b','begin').status=='rejected','foreign begin rejects')
check(f.d.claim(r,'executor-a','begin').status=='launching','adopt intent durable before the native ask')
local delivered=f.d.claim(r,'executor-a','result',{status='submitted',pane_binding=copy(pane)})
check(delivered.status=='awaiting_acceptance' and f.p.equal(delivered.payload.pane_binding,pane),'delivered adoption records the exact attested pane as the launch pane binding')
check(f.d.claim(r,'executor-a','result',{status='submitted',pane_binding=copy(pane)}).status=='awaiting_acceptance' and f.effects.reserves==0,'duplicate result never repeats or reserves')
local accept=f.req('accept','adopt-accept',{target_request_id='adopt',target_action_id='action-adopt',pane_binding=copy(pane),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('accepted adopted')})
check(f.d.request(accept,f.binding,1,function()end).status=='accepted','an adopted worker accepts exactly like a launched one')
check(f.d.request(adopt_request(f,'adopt-2'),f.binding,1,function()end).error.code=='binding_mismatch','an already bound pane is never adopted twice')
local elsewhere=copy(pane);elsewhere.window_epoch='other-window';elsewhere.pane_id='56'
check(f.d.request(adopt_request(f,'adopt-3',elsewhere),f.binding,1,function()end).error.code=='binding_mismatch','a pane outside the exact window, session and host is refused')
local g=fixture();local l=g.launch('launch');g.d.request(l,g.binding,1,function()end)
g.d.claim(l,'x','claim');g.d.claim(l,'x','begin');g.d.claim(l,'x','result',{status='submitted',pane_binding=copy(pane)})
check(g.d.request(adopt_request(g,'adopt-launched'),g.binding,1,function()end).error.code=='binding_mismatch','a launched worker pane cannot be adopted')
local h=fixture();local hr=adopt_request(h,'adopt');h.d.request(hr,h.binding,1,function()end);h.d.claim(hr,'x','claim');h.d.claim(hr,'x','begin')
local refused=h.d.claim(hr,'x','result',{status='refused',message='Target pane is not an idle native agent; nothing was sent'})
check(refused.status=='rejected' and refused.error.code=='target_unavailable','busy or non-agent refusal is a pre-effect rejection')
check(h.d.claim(hr,'x','claim').status=='rejected' and h.d.execution(hr,77)==nil,'a refused adoption never becomes executable again')
check(h.d.request(adopt_request(h,'adopt-retry'),h.binding,1,function()end).status=='resolved','a refused pane can only be attached again by a new explicit request')
local launch_refusal=fixture();local lr=launch_refusal.launch('launch');launch_refusal.d.request(lr,launch_refusal.binding,1,function()end)
launch_refusal.d.claim(lr,'x','claim');launch_refusal.d.claim(lr,'x','begin')
check(launch_refusal.d.claim(lr,'x','result',{status='refused'}).status=='rejected' and launch_refusal.d.claim(lr,'x','result',{status='refused'}).error.code=='invalid_schema','a fresh launch cannot claim a pre-effect refusal')
local u=fixture();local ur=adopt_request(u,'adopt');u.d.request(ur,u.binding,1,function()end);u.d.claim(ur,'x','claim');u.d.claim(ur,'x','begin')
check(u.d.claim(ur,'x','result',{status='uncertain',message='Native ask threw'}).status=='uncertain','an ambiguous native ask is retained uncertainty')
check(u.d.claim(ur,'x','claim').status=='uncertain' and u.d.claim(ur,'x','result',{status='submitted',pane_binding=copy(pane)}).status=='uncertain' and u.d.execution(ur,77)==nil,'an uncertain adoption is never claimed, completed or executed again')
check(u.d.request(adopt_request(u,'adopt-again'),u.binding,1,function()end).error.code=='binding_mismatch','an uncertain adoption keeps the pane bound')
local m=fixture();local mr=adopt_request(m,'pending-adopt');m.d.request(mr,m.binding,1,function()end);m.d.claim(mr,'x','claim')
local restored=fixture(m.image())
check(restored.d.request(restored.req('status','adopt-query',{target_request_id='pending-adopt'}),restored.binding,1,function()end).payload.outcome.status=='uncertain','host reload keeps a claimed adoption uncertain')
end
-- Live macOS defect: owner recovery revoked a staged, never-authorized accept of a launch still
-- awaiting acceptance. The revocation is a distinct pre-effect outcome, the launch is unchanged,
-- the old controller stays fenced, and after explicit attachment the same immutable acceptance
-- is accepted on the attached route.
sections.accept_recovery=function()
 local f=launched_fixture(false)
 local old_accept=f.req('accept','old-accept',{target_request_id='launch',target_action_id='action-launch',pane_binding=copy(pane),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('accepted')})
 f.raw.stage(old_accept,f.binding,1,77)
 local owners=f.d.recovery_view(f.binding)
 check(f.d.recover_owner(f.binding,'session',owners[1].revision,false),'operator fences the old owner')
 local revoked=f.saved['dispatch-v1'].requests['session/old-accept'].body
 check(revoked.status=='rejected' and revoked.error.code=='authorization_revoked' and f.saved['dispatch-v1'].requests['session/launch'].body.status=='awaiting_acceptance',
  'recovery revokes the never-consumed accept authorization with a distinct pre-effect code; the launch is unchanged')
 owners=f.d.recovery_view(f.binding)
 check(f.d.recover_owner(f.binding,'session',owners[1].revision,true),'exact-revision owner recovery is confirmed')
 local stale=copy(old_accept);stale.request_id='old-accept-2';stale.action_id='action-old-accept-2'
 check(f.d.request(stale,f.binding,1,function()end).status=='rejected' and f.saved['dispatch-v1'].requests['session/launch'].body.status=='awaiting_acceptance',
  'the recovered old controller can never accept')
 local attach=attachment_request(f,'attach')
 check(f.d.request(attach,f.binding,1,function()end).status=='attached','explicit attested attachment rebinds the launch route')
 local fresh=copy(old_accept);fresh.request_id='new-accept';fresh.action_id='action-new-accept'
 fresh.origin_binding=copy(attach.origin_binding);fresh.controller_pane=attach.controller_pane;fresh.pane_binding=copy(attach.pane_binding)
 check(f.d.request(fresh,f.binding,1,function()end).status=='accepted' and f.saved['dispatch-v1'].requests['session/launch'].body.status=='accepted',
  'the same immutable acceptance is accepted on the attached route')
 local changed=copy(fresh);changed.request_id='changed-accept';changed.action_id='action-changed-accept';changed.event_sha256=f.c.sha256('different')
 check(f.d.request(changed,f.binding,1,function()end).error.code=='content_conflict','a different ACCEPTED event can never be accepted')
end
-- Live defect: a window attached through `tern remote serve` lists on the host daemon as
-- kind "remote" (window key ""), so every bridge request from it failed the membership fence.
sections.remote_membership=function()
 local held={{id=1,tabs={{blocks={{id=77},{id=12}}}}}}
 local remote=fixture()
 remote.effects.inspect=function(window)
  if window==nil then return {clients={{conn=1,window='',kind='remote',since=1},{conn=2,window='',kind='cli',since=2}},sessions={}} end
  check(window=='','only the remote window key is inspected')
  return {sessions=copy(held)}
 end
 local body=remote.host_request(remote.req('catalog','remote-catalog'))
 check(body.status=='catalog','a remote-attached window holding the bridge pane verifies host membership: '..runtime.json.encode(body))
 check(#remote.effects.inspected==3 and remote.effects.inspected[2]=='' and remote.effects.inspected[3]=='','remote membership keeps the per-window scan and final re-inspection fence')
 local cli=fixture()
 cli.effects.inspect=function(window)
  check(window==nil,'non-window clients are never scanned')
  return {clients={{conn=1,window='',kind='cli',since=1}},sessions=copy(held)}
 end
 body=cli.host_request(cli.req('catalog','cli-catalog'))
 check(body.status=='rejected' and body.error.code=='binding_mismatch' and body.error.message=='Visible host membership is missing or exceeds the 16-window inspection limit','a CLI-only host inventory still refuses membership')
 local both=fixture()
 both.effects.inspect=function(window)
  if window==nil then return {clients={{conn=1,window='local',kind='window',since=1},{conn=2,window='',kind='remote',since=2}},sessions={}} end
  return {sessions={{id=if window=='' then 2 else 1,tabs={{blocks={{id=77},{id=12}}}}}}}
 end
 body=both.host_request(both.req('catalog','both-catalog'))
 check(body.status=='rejected' and body.error.message:find('missing or ambiguous',1,true)~=nil,'a local and a remote window both holding the bridge pane are refused as ambiguous')
end
-- The bridge's own view is one compact human line. The keyed machine response stays intact and
-- bounded, and the SPAWN_BRIDGE v1 lease tells ORCH+ whether the pane may be reused or closed.
sections.bridge_view=function()
local function keyed(view,key)for _,child in ipairs(view.main.c)do if child.p and child.p.key==key then return child end end return nil end
local function span(node)local s=node.p.spans[1];return if type(s)=='string' then s else s.t end
local function lease(view)
 local bytes=span(assert(keyed(view,'spawn-dispatch-lease'),'bridge view must carry its lease node'))
 assert(bytes:sub(1,16)=='SPAWN_BRIDGE v1 ' and #bytes<=2048,'bridge lease is a bounded versioned machine node')
 return runtime.json.decode(bytes:sub(17))
end
local creator={schema=1,controller_pane='44',alias_nonce='alias',window_key='',window_epoch='epoch'}
local owner={controller_pane='44',alias_nonce='alias',window_key='',window_epoch='epoch'}
local f=fixture();f.effects.allow_mailbox=true
local definition=f.host();local cx={pane=77,save=function()end,render=function()end}
local idle=definition.init(cx,{runtime.json.encode(creator)},nil)
local view=definition.view(idle,cx)
local line=span(view.main.c[1])
check((view.main.c[1].p or {}).key==nil and line:find('SPAWN bridge - idle',1,true)==1 and #line<=160 and not line:find('{',1,true),'an idle bridge shows one compact human line, not raw JSON')
local idle_lease=lease(view)
check(not idle_lease.held and not idle_lease.live and not idle_lease.busy and f.p.equal(idle_lease.owner,owner),'a fresh bridge leases idle under its creating ORCH+ window')
check(f.p.equal(definition.save(idle).creator,owner),'the creator survives save, so a restored request-less bridge keeps its owner')
check(f.raw.stage(provision,f.binding,1,77).status=='pending','fixture stages a window challenge on bridge 77')
local restored=definition.init(cx,{},{request_json=runtime.json.encode(provision),creator=creator})
local staged_view=definition.view(restored,cx)
local staged=lease(staged_view)
check(staged.held and staged.live and keyed(staged_view,'spawn-dispatch-execution')~=nil and staged.owner.controller_pane==provision.controller_pane
 and staged.owner.window_epoch==provision.origin_binding.window_epoch,'a bridge with a live challenge leases held and live under its request owner')
local response=span(assert(keyed(staged_view,'spawn-dispatch-response')))
check(response:sub(1,18)=='SPAWN_DISPATCH v1 ' and #response<=8192 and f.p.unframe(response).status=='uncertain','the keyed machine response stays intact and bounded')
check(span(staged_view.main.c[1]):find('executing an authorized ORCH+ effect',1,true)~=nil,'the human line names a live execution projection')
local other={pane=78,save=function()end,render=function()end}
check(not lease(definition.view(definition.init(other,{},nil),other)).held,'SPAWN names only the exact challenged bridge, not its neighbours')
f.effects.now=1700030001.25
local expired=lease(definition.view(restored,cx))
check(expired.held and not expired.live,'an expired unconsumed challenge still names its bridge: held, so never closed or reused')
local g=fixture();g.effects.allow_mailbox=true;g.raw.stage(provision,g.binding,1,77)
g.raw.authorize(provision,g.raw.execution(provision,77).nonce,77,function()end,sourceclaim,'observer')
local gdef=g.host()
check(not lease(gdef.view(gdef.init(cx,{},{request_json=runtime.json.encode(provision)}),cx)).held,'a consumed authorization no longer holds its bridge')
-- A membership verification in flight renders the lease busy before its asynchronous answer, so
-- ORCH+ can neither close nor adopt the bridge mid-verification; the finish render clears it.
local h=fixture();local hdef=h.host();local renders=0
local hcx={pane=77,save=function()end,render=function()renders+=1 end}
local verifying=hdef.init(hcx,{runtime.json.encode(creator)},nil)
h.effects.defer_inspect=true
hdef.event(verifying,{ev='action',act='catalog',value=runtime.json.encode(h.req('catalog','busy-catalog'))},hcx)
check(h.effects.deferred~=nil and renders>=1 and lease(hdef.view(verifying,hcx)).busy and verifying.body==nil,
 'the lease is busy and rendered while membership verification is pending, before its callback')
local queued=renders
hdef.event(verifying,{ev='action',act='catalog',value=runtime.json.encode(h.req('catalog','busy-catalog-2'))},hcx)
check(renders>queued and lease(hdef.view(verifying,hcx)).busy,'a queued verification re-renders and keeps the lease busy')
local steps=0
while h.effects.deferred and steps<32 do local d=h.effects.deferred;h.effects.deferred=nil;steps+=1;d() end
h.effects.defer_inspect=false
check(steps<32 and not lease(hdef.view(verifying,hcx)).busy and verifying.body~=nil,
 'once every verification answers, the lease reads idle again')
end
if section then
 assert(sections[section],'unknown dispatch section '..section)
 sections[section]()
else
 for _,name in ipairs({'launch','migration','publication','ack_lifecycle','wake_binding','authorization','expired_authorization','recovery','duplex','retirement_binding','retirement_settlement','retirement_producer','coordinator_launch','wake_capacity','wake_retention','attachment','attachment_recovery','authority_rotation','host_local','rollover_accept','adopt','accept_recovery','remote_membership','bridge_view'})do sections[name]()end
end
return 'PASS dispatch'..(if section then '/'..section else '')..' '..tostring(checks)
