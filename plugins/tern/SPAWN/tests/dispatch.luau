-- Native Luau fixture runner. Durable KV, config authority, and transport effects
-- are injected; the real public codec, backend and dispatch transitions run.
local root,section=...
assert(type(root)=='string','pass package directory')
assert(section==nil or type(section)=='string','section must be a dispatch section name')
local runtime,environment=tern,getfenv()
local checks=0
local function check(v,m)assert(v,m);checks+=1 end
local function copy(v)if type(v)~='table'then return v end local n=if next(v)==nil and runtime.json.encode(v)=='[]' then runtime.json.array() else {} for k,x in pairs(v)do n[k]=copy(x)end return n end
local issued,next_serial,next_grant={},1,0
local function serial(id)
 if not issued[id] then issued[id]=next_serial;next_serial+=1 end
 return issued[id]
end
local function fixture(seed,actual_mailbox,setup_only,native_session_id)
 local saved=copy(seed or {});local modules={};local effects={reserves=0,observations=0,imports=0}
 local transport={files={},modes={},writes=0}
 local record={id='worker',provider='omp',account_label='Configured display',backend='native-agent',command='omp',arguments={},cwd='/work',placement='tab',enabled=true,fresh_native_default=true,mailbox={permitted_root='/mail',helper_path='/tools/helper',worker_identity='fixture',verified=true,evidence_ref='fixture-only',wake='native-ask-v1',producer={read=true,write=true,hash=true,journal=true,poll=false},capabilities={'report-files-v1','native-ask-v1'}}}
 record.mailbox.producer_helper_path='/tools/worker-helper'
 local snapshot={ready=true,namespace='host',host_key='host:test',config_revision=0,records={record},host_os='linux',host_shell='/bin/sh'}
 snapshot.setup={schema=1,state='completed',config_revision=0,readiness={state='not_run',config_revision=0,summary=''}}
 local binding={authority_id='host:1',managed_authority_id='host:1',session_key='host/session/1',host_key='host:test',native_session=1}
 local mailbox_binding,mailbox_handover=nil,nil
 local authority={snapshot=function()return copy(snapshot)end,managed_reserve=function(_,_,id,observer)effects.reserves+=1;return {id='attempt-1',record_id=id,observer_id=observer}end,managed_observe=function()effects.observations+=1;return true end,managed_retire=function(...)effects.retire_args={...};effects.retirements=(effects.retirements or 0)+1;return not effects.fail_retire,'injected retirement storage failure' end,managed_import=function()effects.imports+=1;return {imported=1}end}
 authority.managed_snapshot=authority.snapshot
 authority.record_launch_available=function(_,id)
  if effects.preparing_record==id or effects.preparing_record=='*' then return false,'Agent is owned by a setup diagnostic' end
  return true
 end
 authority.setup_snapshot=function()
  effects.setup_reads=(effects.setup_reads or 0)+1
  if effects.setup_error then return nil,effects.setup_error end
  if effects.absent then return {config_revision=0,records={},setup={schema=1,state='not_started',config_revision=0,readiness={state='not_run',config_revision=0,summary=''}}} end
  return copy(snapshot)
 end
 authority.execution_bindings=function()return {} end
 local mailbox={empty=function()return {version=1,generations={}}end,validate=function(r)if type(r)~='table' or r.version~=1 then return nil,{status='rejected',error={code='journal_corrupt'}} end return r end,recover=copy,get=function()return {binding=copy(mailbox_binding),record_id='worker',record_revision=0,phase='provisioned',capabilities=copy(record.mailbox.capabilities),handover=copy(mailbox_handover)}end,location=function()return {root='/mail/private',helper='/tools/helper',producer_helper='/tools/worker-helper',wake=effects.wake_route or 'native-ask-v1'}end}
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
  callback(if effects.target_full then {status='full',resource='target',current=1,limit=1} else copy(effects.outcome or {status='provisioned',payload={handle='mailbox',binding_digest=string.rep('a',64),capabilities=copy(record.mailbox.capabilities),identity={worker='fixture'},limits={mailbox_bytes=4194304,mailbox_files=1024,host_bytes=67108864,host_files=16384,generations=16,registry_bytes=4194304,reserved_bytes=262144,deadline_ms=30000,concurrency=4}}}))
 end
 mailbox.settle=function(registry,_,outcome)return copy(registry),outcome end
 local storage={}
 storage.get=function(k)
  effects.reads=effects.reads or {};effects.reads[k]=(effects.reads[k] or 0)+1
  if effects.before_read then effects.before_read(k,effects.reads[k]) end
  if effects.fail_read==k then error('injected read failure') end
  return copy(saved[k])
 end
 storage.set=function(k,v)
  effects.writes=(effects.writes or 0)+1
  effects.write_keys=effects.write_keys or {};table.insert(effects.write_keys,k)
  if effects.before_write then effects.before_write(k,v) end
  if effects.fail_write or effects.fail_write_key==k then error('injected failure') end
  saved[k]=copy(v)
  if effects.after_write then effects.after_write(k,v) end
  if effects.fail_after_write or effects.fail_after_write_key==k then error('injected failure after durable write') end
 end
 local injected=setmetatable({now=function()return effects.now or 1700000000.25 end,kv=storage},{__index=runtime})
 injected.on=function(name,fn) effects.handlers=effects.handlers or {};effects.handlers[name]=effects.handlers[name] or {};table.insert(effects.handlers[name],fn) end
 injected.fs=setmetatable({read=function(path,limit)
  if effects.procfiles and path:sub(1,6)=='/proc/' then local bytes=assert(effects.procfiles[path],'unavailable fixture process');assert(not limit or #bytes<=limit);return bytes end
  return runtime.fs.read(path,limit)
 end},{__index=runtime.fs})
 if actual_mailbox then
  injected.timer=function()return {cancel=function()end}end
  injected.process={run=function(argv,options,callback)
   local mode,path=argv[5],argv[6];table.insert(transport.modes,mode)
   if argv[6]=='retire-authorized' then mode='retire_producer';transport.modes[#transport.modes]=mode end
   local stdout='storage_error\n'
   if mode=='provision'then
    if transport.hold_provision then transport.provision_callback=callback;return end
    stdout='provisioned\n'
   elseif mode=='retire_producer' then stdout=(transport.producer_status or 'producer_absent')..'\n'
   elseif mode=='retire' and transport.allow_retire then stdout='retired\n'
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
  if name=='host_executor' then return {install=function()end,attach=function()end,epoch=function()return nil end} end
  if name=='window_journal' then return {host_initialize=function()return 'fixture-observers' end} end
  -- Actual updater registration is covered by the separate native consumer case.
  if name=='updater/host' then return {register=function()end} end
  if modules[name]then return modules[name]end
  local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
  setfenv(chunk,setmetatable({tern=injected,require=load},{__index=environment}))
  modules[name]=chunk()
  if name=='native_cli' then
   local original=modules[name].process
   modules[name].process=function(route,session,pane,opts,done)
    if effects.native_process then done({status=0,timed_out=false,stdout=runtime.json.encode(effects.native_process)},nil)
    else original(route,session,pane,opts,done) end
   end
  end
  return modules[name]
 end
 local p,c,d=load('bridge_protocol'),load('wire/codec'),load('dispatch')
 local engine=d
 local origin={logical_session_id='session',owner_id='owner',owner_generation=1,host_pane_id='12',alias_nonce='alias',window_key='',window_epoch='epoch',native_session_id=native_session_id or '3',window_host_id='7'}
 local peer_claims={}
 local function proof(r,claim,witness)
  local entry=saved['dispatch-v1'] and saved['dispatch-v1'].requests[r.logical_session_id..'/'..r.request_id]
  local selected=copy(claim or entry and entry.orch_claim)
  if selected and witness then
   local old=peer_claims[selected.grant_id]
   if not old then old={spawn_namespace=witness.spawn_namespace,claim_nonce=witness.claim_nonce};peer_claims[selected.grant_id]=old end
   selected.spawn_claim=copy(old)
  end
  return {authority_namespace=r.authority_namespace,authority_revision=100,logical_session_id=r.logical_session_id,admission_seq=r.admission_seq,request_serial=r.request_serial,action_id=r.action_id,request_sha256=c.sha256(entry and entry.request_json or runtime.json.encode(r)),phase='claimed',reconciliation_only=false,execution_origin=copy(r.origin_binding),execution_controller_pane=r.controller_pane,claim=selected}
 end
 local raw=setmetatable({},{__index=engine})
 raw.stage=function(r,b,s,bridge,bytes)return engine.stage(r,b,s,bridge,bytes or runtime.json.encode(r))end
 raw.authorize=function(r,nonce,bridge,changed,claim,executor,projection,observation)
  return engine.authorize(r,nonce,bridge,changed,claim,executor,projection or proof(r,claim),nil,observation)
 end
 local driver=setmetatable({},{__index=raw})
 driver.request=function(r,b,s,changed)
  if r.setup_origin or r.op=='status' or r.op=='owner_status' then return engine.request(r,b,s,changed) end
  local body=raw.stage(r,b,s,77)
  local projection=engine.execution(r,77)
  if body and body.status=='pending' and projection and projection.kind=='authorize' then
   effects.grants=(effects.grants or 0)+1;next_grant+=1
   local observation=if projection.startup_cleanup and effects.startup_observation then effects.startup_observation(projection) else nil
   return raw.authorize(r,projection.nonce,77,changed,{executor=r.origin_binding.window_epoch,epoch=1,grant_id='fixture-'..tostring(next_grant)},'fixture-window',nil,observation)
  end
  return body
 end
 local function native(r,executor,operation,result,claim)
  local entry=saved['dispatch-v1'] and saved['dispatch-v1'].requests[r.logical_session_id..'/'..r.request_id]
  local target=entry and r.op=='native_wake' and saved['dispatch-v1'].requests[r.logical_session_id..'/'..r.target_request_id]
  local witness=if target and target.wake then target.wake.claim else entry and entry.claim
  local current=proof(r,claim,witness)
  if r.op=='native_wake' then return engine.wake_claim(r,executor,operation,result,claim or entry and entry.orch_claim,current,witness) end
  return (if r.op=='stop' then engine.stop_claim else engine.claim)(r,executor,operation,result,current,witness)
 end
 driver.claim=native;driver.stop_claim=native;driver.wake_claim=native
 d=driver
 local function req(op,id,extra)
  local r={schema=2,origin='orchplus',op=op,request_id=id,action_id='action-'..id,authority_namespace='orch-authority',logical_session_id='session',admission_seq=1,controller_pane='44',controller_generation=1,origin_binding=copy(origin)}
  if op=='status' then r.target_request_serial=serial(extra.target_request_id)
  elseif op~='owner_status' and op~='mailbox_inventory' and op~='mailbox_allocation' then
   -- These independently issued fixture requests may arrive in any order.
   r.request_serial=serial(id);r.next_request_serial=1000000;r.settled_before=1;r.consumed=runtime.json.array()
  end
  for k,v in pairs(extra or {})do r[k]=v end return r
 end
 if not seed and not setup_only then
  -- Qualified paired source fixture; admit through the real native control seam.
  saved['dispatch-v1']={version=2,revision=0,namespace='spawn-authority',authority_namespace='orch-authority',next_id=1,admission_cursor=0,sessions={},workers={},controls={},requests={},mailboxes=mailbox.empty(),gates={}}
  saved['dispatch-v1-initialized']='spawn-authority'
  local admission={schema=2,origin='orchplus',op='admit_session',request_id='admit',action_id='admit-action',authority_namespace='orch-authority',authority_revision=100,logical_session_id='session',admission_seq=1,control_origin={kind='active',binding=copy(origin),controller_pane='44'},compatibility={schema=1,kind='current',protocol=2,authority_namespace='orch-authority',spawn_namespace='spawn-authority'},generation_floor=0,next_request_serial=1000000,settled_before=1,consumed=runtime.json.array()}
  raw.stage(admission,binding,1,77)
  local projection=assert(engine.execution(admission,77),'admission challenge')
  local peer={protocol=2,phase='stable',authority_namespace='orch-authority',authority_revision=100,spawn_namespace='spawn-authority',session={admission_seq=1,control={phase='open',generation_floor=0,request_floor=1,next_request_serial=1000000,last_authority_revision=100,binding=copy(origin)}}}
  assert(engine.control_authorize(admission,projection.nonce,77,'fixture-window',peer).status=='admitted','fixture explicit admission')
 end
 local function admit_origin(r)
  local state=saved['dispatch-v1'].sessions[r.logical_session_id]
  local request={schema=2,origin='orchplus',op='reconcile_session',request_id='reconcile-'..r.request_id,action_id='reconcile-action-'..r.request_id,authority_namespace=r.authority_namespace,authority_revision=100,logical_session_id=r.logical_session_id,admission_seq=r.admission_seq,control_origin={kind='active',binding=copy(r.origin_binding),controller_pane=r.controller_pane},compatibility={schema=1,kind='current',protocol=2,authority_namespace=r.authority_namespace,spawn_namespace='spawn-authority'},generation_floor=state.control.generation_floor,next_request_serial=1000000,settled_before=1,consumed=runtime.json.array()}
  request.page_limit=c.DISPATCH.outstanding
  local staged=raw.stage(request,binding,1,77)
  local challenge=engine.execution(request,77)
  check(staged==nil and challenge and challenge.kind=='control_authorize','new origin requires an ephemeral native control challenge, not a public pending outcome')
  local current={phase='open',generation_floor=state.control.generation_floor,request_floor=1,next_request_serial=1000000,last_authority_revision=100,binding=copy(r.origin_binding)}
  local peer={protocol=2,phase='stable',authority_namespace=r.authority_namespace,authority_revision=100,spawn_namespace='spawn-authority',session={admission_seq=r.admission_seq,control=current}}
  check(engine.control_authorize(request,challenge.nonce,77,'fixture-window',peer).status=='reconciled','new current origin explicitly reconciles after recovery')
 end
 local function launch(id,extra)
  local text="literal ' $HOME ; 雪\nsecond line"
  local e={worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',assignment_sha256=c.sha256(text)}
  for k,v in pairs(extra or {})do e[k]=v end
  mailbox_binding={logical_session_id='session',worker_id=e.worker_id,worker_generation=1,launch_request_id=id,work_id='work',enrolment_token=e.enrolment_token}
  -- A rollover successor's mailbox is provisioned with the issued ID and the pair digest.
  mailbox_handover=if e.handover_id then {handover_id=e.handover_id,handover_sha256=c.sha256(e.handover_id..':'..e.handover_token)} else nil
  return req('launch',id,{record_id='worker',record_revision=0,work_id='work',prompt=text,cwd='/work',placement='tab',fresh=true,mailbox_handle='mailbox',enrolment=e})
 end
 return {p=p,c=c,d=d,raw=raw,engine=engine,proof=proof,admit_origin=admit_origin,req=req,launch=launch,binding=binding,effects=effects,snapshot=snapshot,saved=saved,origin=origin,authority=authority,transport=transport,load=load,runtime=injected,image=function()return copy(saved)end}
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
do
 local guarded=fixture()
 local before=guarded.image()
 check(guarded.raw.record_preparation_busy('worker')==false and guarded.p.equal(before,guarded.image()),'empty managed registry inspection is read-only and establishes no active agent')
 guarded.effects.preparing_record='worker'
 local launch=guarded.req('launch','blocked-setup-launch',{record_id='worker',record_revision=0,work_id='work',prompt='assignment',cwd='/work',placement='tab',fresh=true,mailbox_handle='mailbox',enrolment={worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',assignment_sha256=guarded.c.sha256('assignment')}})
 check(guarded.raw.stage(launch,guarded.binding,1,77).status=='rejected' and not guarded.saved['dispatch-v1'].requests['session/blocked-setup-launch'] and guarded.effects.reserves==0,'diagnostic ownership blocks a managed pre-reservation before native consent or effects')
 guarded.effects.preparing_record=nil
 local ready=guarded.launch('launch-busy')
 check(guarded.d.request(ready,guarded.binding,1,function()end).status=='resolved','fixture admits the exact managed launch before native execution')
 check(guarded.raw.record_preparation_busy('worker')==true,'a prepared managed launch is busy before native claim or ordinary attempt observation')
 guarded.effects.preparing_record='worker'
 local refused=guarded.d.claim(ready,'window','claim')
 check(refused.status=='rejected' and refused.error.code=='target_unavailable','diagnostic lease is rechecked at actual native execution claim')
end
local r=f.req('catalog','catalog')
check(f.p.decode(runtime.json.encode(r))~=nil,'strict catalog accepts exact common fields')
local bad=copy(r);bad.command='raw-command';check(f.p.decode(runtime.json.encode(bad))==nil,'runtime raw command rejected')
check(f.p.decode('{"schema":1,"schema":1}')==nil,'duplicate keys rejected before native JSON normalization')
check(f.p.decode('{"schema":null}')==nil,'null rejected')
local wire=f.p.encode(f.d.request(r,f.binding,1,function()end))
check(f.p.unframe(wire,r).request_id=='catalog','exact body bytes/hash roundtrip')
check(f.p.unframe(wire..'x',r)==nil,'trailing bytes rejected')
do
 local large=fixture(nil,nil,nil,'1')
 local original=copy(large.snapshot.records[1])
 large.snapshot.records={}
 for index=1,12 do
  local record=copy(original)
  record.id=string.format('saved-agent-%02d',index)
  record.account_label=string.rep('Saved account ',9)..tostring(index)
  record.cwd='/work/'..string.rep('directory/',30)..tostring(index)
  table.insert(large.snapshot.records,record)
 end
 local firstRequest=large.req('catalog','full-catalog-first')
 local first=large.d.request(firstRequest,large.binding,1,function()end)
 local query=large.req('status','status-'..string.rep('q',80),{target_request_id=firstRequest.request_id})
 local firstWire=large.p.encode(first)
 check(first.status=='catalog' and first.payload.next_cursor~=nil and firstWire~=nil and #firstWire<=large.c.LIMITS.bridge,
  'twelve saved agents produce a genuine bounded first page and revision cursor')
 local retained=large.image()
 local inspected=large.d.request(query,large.binding,1,function()end)
 local frame=large.p.encode(inspected)
 local decoded=frame and large.p.unframe(frame,query)
 check(inspected.status=='found' and frame~=nil and #frame>large.c.LIMITS.bridge and #frame<=large.c.LIMITS.bridge_status
  and decoded and large.p.equal(decoded.payload.outcome,first) and large.p.encode(decoded.payload.outcome)==firstWire
  and large.p.equal(retained,large.image()),
  'status carries the identical valid original inside its bounded inspection envelope without changing retained state')
 check(large.p.equal(large.d.request(firstRequest,large.binding,1,function()end),first),
  'the original exact catalog remains readable after status inspection')
 -- Only carrier IO is injected: the actual status producer, relay publisher,
 -- ACK/drain ordering, stage and nonce-bound authorization all run together.
 local inbox,sent,acks,ackBlocked,sequence={},{},{},false,0
 local endpoint={}
 function endpoint.send(frame)
  table.insert(sent,copy(frame));return {id=frame.id}
 end
 function endpoint.receive(limit)
  local out={};for index=1,math.min(limit,#inbox)do table.insert(out,inbox[index])end
  return out
 end
 function endpoint.ack(message)
  if ackBlocked then return false,{code='ack_pending'} end
  acks[message.id]=true
  for index,item in ipairs(inbox)do if item.id==message.id then table.remove(inbox,index);break end end
  return true
 end
 function endpoint.settle()return 0 end
 function endpoint.acknowledged()return false end
 large.load('channel/channel').open=function()return endpoint end
 large.runtime.plugin={data='/fixture/spawn'}
 large.runtime.pane={list=function()return {{pane=12,program='orchplus.orchestrator'}}end}
 large.runtime.timer=function()return {cancel=function()end}end
 large.authority.binding=function(session)
  check(session==1,'the native catalog relay uses its bound source session');return large.binding
 end
 local relay=large.load('dispatch_relay').install()
 local function enqueue(act,bytes)
  sequence+=1
  local message={peer='orchplus',route='spawn.request',incarnation='catalog-orch',id='m-'..tostring(sequence),
   binding='catalog:lane:'..act..(if act=='bind' then '' else ':'..relay.boot),body=bytes}
  table.insert(inbox,message);return message.id
 end
 enqueue('bind',runtime.json.encode({schema=1,relay_endpoint='catalog',relay_boot='catalog-orch',lane_id='lane',
  host_pane_id='12',source_nonce=large.origin.alias_nonce,origin=copy(large.origin),
  desktop_proof='delegated_native_window',host_program='orchplus.orchestrator'}))
 relay.poll()
 local lane=assert(relay.lanes['catalog:lane'])
 local seen,count={},0
 local function collect(body)
  for _,record in ipairs(body.payload.records)do
   check(not seen[record.id],'each saved agent appears once across real native catalog pages')
   seen[record.id]=true;count+=1
  end
 end
 collect(first)
 local cursor=first.payload.next_cursor
 local page=1
 while cursor do
  page+=1
  local request=large.req('catalog','full-catalog-'..tostring(page),{cursor=cursor})
  local raw=runtime.json.encode(request)
  local statusMessage
  if page==2 then statusMessage=enqueue('status',runtime.json.encode(query));ackBlocked=true end
  local pageMessage=enqueue('catalog',raw)
  relay.poll()
  if page==2 then
   local published
   for _,message in ipairs(sent)do
    if message.route=='spawn.response' then published=large.p.unframe(message.body,query) or published end
   end
   check(published and published.status=='found' and large.p.equal(published.payload.outcome,first)
    and not acks[statusMessage] and not acks[pageMessage] and lane.request.request_id==query.request_id,
    'the actual relay publishes the complete retained outcome and holds the queued page behind its exact pending ACK')
   ackBlocked=false;relay.poll()
   check(acks[statusMessage] and acks[pageMessage] and lane.request.request_id==request.request_id,
    'normal carrier drain ACKs status and stages the already-queued next catalog exactly once without lane recovery')
  end
  local execution=assert(lane.published_execution)
  local claim={executor=request.origin_binding.window_epoch,epoch=1,grant_id='catalog-grant-'..tostring(page)}
  enqueue('spawn.authorize',runtime.json.encode({request_json=raw,nonce=execution.nonce,executor_id='catalog-window',
   orch_claim=claim,proof=large.proof(request,claim),relay_execution=copy(lane.execution_receipt)}))
  relay.poll()
  local body=lane.body
  check(body.status=='catalog' and body.request_id==request.request_id and large.p.encode(body)~=nil and #inbox==0,
   'the following exact cursor request completes through the real native authorization and result publisher')
  collect(body);cursor=body.payload.next_cursor
 end
 check(count==12 and large.effects.reserves==0 and large.effects.observations==0,
  'all twelve saved agents load without native launch, reservation or recovery')
end
do
 local observed=fixture()
 local q=observed.req('mailbox_inventory','inventory-empty',{stale_ms=1800000})
 q.request_serial=nil;q.next_request_serial=nil;q.settled_before=nil;q.consumed=nil
 local before=observed.image()
 local inventory=observed.raw.stage(q,observed.binding,1,77)
 check(inventory.status=='inventory' and inventory.payload.mailboxes==0 and inventory.payload.open_files==0 and inventory.payload.stale_files==0,'an actually empty retained mailbox scope returns a real empty inventory')
 check(observed.p.encode(inventory)~=nil and observed.p.equal(before,observed.image()) and observed.raw.execution(q,77)==nil,'read-only inventory acquires no grant and writes no authority or effect journal')
 local foreign=copy(q);foreign.request_id='inventory-foreign';foreign.origin_binding.native_session_id='999'
 check(observed.raw.stage(foreign,observed.binding,1,77).status=='rejected' and observed.p.equal(before,observed.image()),'inventory cannot observe another native session through an unbound request')
end
do
 local observed=fixture()
 local callbacks,timers,visited={},{},{}
 local active,peak,started,busy=0,0,0,true
 observed.runtime.timer=function(_,callback)table.insert(timers,callback);return {cancel=function()end}end
 local adapter=observed.load('mailbox_adapter')
 adapter.inventory_capacity=function()return if busy then 0 else 4-active end
 adapter.inventory=function(_,handle,_,callback,budget)
  check(budget>=1 and budget<=15000,'inventory children keep the existing per-helper deadline')
  active+=1;peak=math.max(peak,active);started+=1
  check(not visited[handle],'every retained target is scanned once')
  visited[handle]=true
  table.insert(callbacks,function()
   active-=1
   observed.effects.now=(observed.effects.now or 1700000000.25)+100
   callback({observed_at_ms=1700000000000,open_files=3,stale_files=1},nil)
  end)
 end
 local retained=observed.saved['dispatch-v1'].mailboxes.generations
 for index=1,32 do retained['mailbox-'..index]={status='provisioned',binding={logical_session_id='session'},target={}} end
 local q=observed.req('mailbox_inventory','inventory-complete-32',{stale_ms=1800000})
 q.request_serial=nil;q.next_request_serial=nil;q.settled_before=nil;q.consumed=nil
 local before=observed.image()
 local body=observed.raw.stage(q,observed.binding,1,77)
 check(body.status=='pending' and started==0 and #timers==1,'busy effect slots hold a bounded read observation rather than rejecting or stealing capacity')
 busy=false;table.remove(timers,1)()
 check(started==4 and peak==4,'inventory fills at most the existing four executor slots')
 while #callbacks>0 do table.remove(callbacks,1)() end
 body=observed.raw.stage(q,observed.binding,1,77)
 check(body.status=='inventory' and body.payload.mailboxes==32 and body.payload.open_files==96 and body.payload.stale_files==32 and started==32 and peak==4,'complete legal 32-worker inventory aggregates every target without serial-only delay or truncation')
 check(observed.p.encode(body)~=nil and observed.p.equal(before,observed.image()) and observed.raw.execution(q,77)==nil,'complete inventory is wire-valid and read-only')
 local timeout=observed.req('mailbox_inventory','inventory-budget',{stale_ms=1800000})
 timeout.request_serial=nil;timeout.next_request_serial=nil;timeout.settled_before=nil;timeout.consumed=nil
 busy=true
 check(observed.raw.stage(timeout,observed.binding,1,77).status=='pending','a new read starts with no fabricated prior counts')
 observed.effects.now+=31000
 while #timers>0 do table.remove(timers,1)() end
 check(observed.raw.stage(timeout,observed.binding,1,77).status=='rejected' and observed.p.equal(before,observed.image()),'read-only executor pressure has a truthful finite deadline without partial-count success')
end
do
 local setup=fixture(nil,nil,true)
 local q={schema=2,origin='orchplus',op='catalog',request_id='setup-catalog',action_id='setup-action',setup_origin={host_pane_id='12',window_key='',window_epoch='setup-epoch',native_session_id='3',window_host_id='7'}}
 check(setup.p.decode(runtime.json.encode(q))~=nil,'precontroller catalog accepts the exact closed read-only shape, including an empty native window key')
 for _,field in ipairs({'origin_binding','controller_generation','controller_pane','logical_session_id','command'}) do
  local invalid=copy(q);invalid[field]=if field=='origin_binding' then copy(setup.origin) else 'forbidden'
  check(setup.p.decode(runtime.json.encode(invalid))==nil,'precontroller catalog refuses controller/mutation field '..field)
 end
 for _,field in ipairs({'host_pane_id','window_key','window_epoch','native_session_id','window_host_id'}) do
  local invalid=copy(q);invalid.setup_origin[field]=nil
  check(setup.p.decode(runtime.json.encode(invalid))==nil,'precontroller catalog requires native identity '..field)
 end
 local invalid=copy(q);invalid.setup_origin.extra=true
 check(setup.p.decode(runtime.json.encode(invalid))==nil,'setup origin is closed')
 invalid=copy(q);invalid.op='owner_status'
 check(setup.p.decode(runtime.json.encode(invalid))==nil,'setup origin never authorizes a controller operation')
 setup.effects.absent=true
 local before=setup.image()
 local absent=setup.d.request(q,nil,nil,function()end)
 check(absent.status=='catalog' and absent.payload.catalog_version==2 and absent.payload.setup.state=='not_started' and absent.payload.setup.readiness.state=='not_run' and #absent.payload.records==0 and absent.payload.revision==0 and absent.payload.namespace==nil and absent.payload.host_key==nil,'genuine absence exposes empty not_started setup without invented authority identity')
 check(absent.origin_binding==nil and absent.controller_generation==nil and setup.p.equal(absent.setup_origin,q.setup_origin) and absent.action_id==q.action_id,'setup response correlates exact native origin and action without a fake controller')
 check(setup.p.equal(setup.p.unframe(setup.p.encode(absent),q),absent),'setup catalog retains bounded exact body framing')
 check(setup.p.equal(before,setup.image()) and setup.effects.reserves==0 and setup.effects.observations==0 and setup.effects.imports==0 and setup.effects.bindings==nil,'setup catalog writes no owners, requests, grants, fences, history or authority scopes')
 check(setup.raw.stage(q,nil,nil,77).status=='rejected' and setup.raw.execution(q,77)==nil and setup.p.equal(before,setup.image()),'setup requests cannot acquire a staged execution grant')
 for _,message in ipairs({'Authority missing after initialization; restore it','Corrupt authority; restore it'}) do
  setup.effects.setup_error=message
  local refused=setup.d.request(q,nil,nil,function()end)
  check(refused.status=='rejected' and refused.error.code=='storage_error' and refused.error.message==message and refused.payload==nil,'lost/corrupt authority never masquerades as first install')
 end
 setup.effects.setup_error=nil;setup.effects.absent=nil
 setup.snapshot.setup.state='in_progress'
 local adopted=setup.d.request(q,nil,nil,function()end)
 check(adopted.payload.setup.state=='in_progress' and #adopted.payload.records==1,'existing records cannot imply setup completion')
 setup.snapshot.config_revision=2;setup.snapshot.setup.state='completed';setup.snapshot.setup.config_revision=2
 setup.snapshot.setup.readiness={state='passed',config_revision=1,summary='Earlier optional exercise'}
 local current=setup.d.request(q,nil,nil,function()end)
 check(current.payload.config_revision==2 and current.payload.setup.state=='completed' and current.payload.setup.readiness.config_revision==1,'read-only repeated setup request observes current metadata and preserves visibly stale optional readiness')
 local page=copy(q);page.cursor={revision=0,index=1}
 check(setup.d.request(page,nil,nil,function()end).error.code=='binding_mismatch','setup catalog pagination remains revision-fenced')
 page.cursor={revision=2,index=3}
 check(setup.d.request(page,nil,nil,function()end).error.code=='invalid_schema','setup catalog rejects out-of-range cursors')
end
local cat=f.d.request(r,f.binding,1,function()end)
check(cat.status=='catalog' and cat.payload.catalog_version==2 and f.p.equal(cat.payload.setup,f.snapshot.setup) and cat.payload.records[1].eligible,'postcontroller catalog exports explicit setup metadata without inventing verified identity')
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
wrong.request_serial=serial(wrong.request_id)
check(f.d.request(wrong,f.binding,1,function()end).status=='rejected','wrong acceptance token rejected')
local status=f.req('status','status',{target_request_id='launch'})
check(f.d.request(status,f.binding,1,function()end).payload.outcome.status=='accepted','status addressed by retained launch request')
local probe=f.req('owner_status','owner-probe')
check(f.p.decode(runtime.json.encode(probe))~=nil,'read-only owner_status is a closed public request')
local before_probe=runtime.json.encode(f.saved['dispatch-v1'])
check(f.p.equal(f.d.request(probe,f.binding,1,function()end).payload.control.binding,f.origin),'owner_status reports exact current admission binding')
local reloaded_probe=copy(probe);reloaded_probe.request_id='owner-reloaded';reloaded_probe.origin_binding.window_epoch='window-after-reload'
check(f.p.equal(f.d.request(reloaded_probe,f.binding,1,function()end).payload.control.binding,f.origin),'reloaded observer sees earlier current incarnation without rebinding')
local foreign_probe=copy(probe);foreign_probe.request_id='owner-foreign';foreign_probe.origin_binding.owner_id='other'
check(f.p.equal(f.d.request(foreign_probe,f.binding,1,function()end).payload.control.binding,f.origin),'read-only observer sees current admission, not an invented owner history')
check(runtime.json.encode(f.saved['dispatch-v1'])==before_probe,'owner_status reserves, fences and records nothing')
local other=copy(r);other.request_id='other';other.origin_binding.owner_id='other'
other.request_serial=serial(other.request_id)
check(f.d.request(other,f.binding,1,function()end).error.code=='stale_binding','occupied controller refuses other owner')
local stale=f.req('catalog','stale',{cursor={revision=99,index=1}})
check(f.d.request(stale,f.binding,1,function()end).status=='rejected','revision-bound cursor rejects stale config')
local owners=f.d.recovery_view(f.binding)
check(f.d.recover_owner(f.binding,'session',owners[1].revision,false),'operator first fences old owner')
check(f.d.request(reloaded_probe,f.binding,1,function()end).payload.control.recovery.phase=='fenced','owner_status exposes live unconfirmed recovery')
check(f.d.request(f.req('catalog','fenced'),f.binding,1,function()end).status=='rejected','fenced controller cannot dispatch')
owners=f.d.recovery_view(f.binding)
check(f.d.recover_owner(f.binding,'session',owners[1].revision,true),'explicit exact-revision recovery records attestation')
check(f.d.request(probe,f.binding,1,function()end).payload.control.binding==nil and f.d.request(reloaded_probe,f.binding,1,function()end).payload.control.recovery.phase=='confirmed',
 'confirmed recovery retains current floor and recovery obligation, not a retired owner')
check(f.d.request(f.req('catalog','retired'),f.binding,1,function()end).status=='rejected','retired origin cannot reactivate')
local retired_launch=f.launch('retired-launch')
check(f.raw.stage(retired_launch,f.binding,1,77).status=='rejected' and f.raw.execution(retired_launch,77)==nil and f.effects.reserves==1,'retired binding cannot stage a fresh authorization or reserve another launch')
check(f.d.request(f.req('status','retired-status',{target_request_id='launch'}),f.binding,1,function()end).category=='stale_binding','retired execution binding cannot regain managed authority through status')
check(f.saved['dispatch-v1'].sessions.session.control.binding==nil and f.saved['dispatch-v1'].owners==nil,'read-only status cannot recreate owner or historical owner map')
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
local corrupt_host=fixture(corrupt_image);local corrupt_before=corrupt_host.image()
local corrupt_request=corrupt.req('catalog','corrupt-catalog')
local corrupt_body=corrupt_host.d.request(corrupt_request,corrupt.binding,1,function()end)
local corrupt_frame=corrupt_host.p.encode(corrupt_body)
check(corrupt_body.status=='rejected' and corrupt_frame~=nil and corrupt_host.p.unframe(corrupt_frame,corrupt_request)~=nil and corrupt_body.error~=nil and type(corrupt_body.error.message)=='string' and #corrupt_body.error.message<=512 and corrupt_body.error.message:find('journal_corrupt',1,true)~=nil and not corrupt_body.error.message:find('table:',1,true),'corrupt mailbox journal returns a bounded canonical refusal with its typed diagnostic')
check(corrupt_host.p.equal(corrupt_before,corrupt_host.image()) and corrupt_host.effects.reserves==0 and corrupt_host.effects.observations==0 and corrupt_host.effects.imports==0 and (corrupt_host.effects.transports or 0)==0 and corrupt_host.raw.execution(corrupt_request,77)==nil,'corrupt authority is never reset, authorized or executed')
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
do
 local old=fixture()
 local bytes='[{"id":"legacy","provider":"Codex","account_label":"Saved","backend":"local-terminal","command":"codex","arguments":[],"enabled":true,"include_all":true,"placement":"tab"}]'
 local preview={schema=1,origin='spawn-migration',op='import_config',request_id='old-consumed',source_client='client',target_host='host:test',source_revision=1,source_sha256=old.c.sha256(bytes),records_json=bytes}
 local gate=assert(old.d.open_import(old.binding,runtime.json.encode(preview)))
 local request=copy(preview);request.migration_gate_id=gate
 check(old.d.import_config(request).status=='imported','seed a consumed immutable old roster source')
 local image=old.image();image['dispatch-v1'].gates[gate].records[1].include_all=true
 local restored=fixture(image)
 check(restored.d.import_config(request).status=='imported' and restored.effects.imports==0,'a consumed gate with retired old canonical fields stays readable and never reimports')
 local saved=restored.saved['dispatch-v1'].gates[gate]
 check(saved.records[1].include_all==nil and saved.records[1].provider_family==nil and saved.request.records_json==bytes and saved.request.source_sha256==preview.source_sha256,'gate metadata normalizes while immutable original bytes and their hash remain exact')
end
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
local compacted=fixture()
compacted.saved['dispatch-v1'].sessions.session.control.request_floor=wake_request.request_serial+1
check(compacted.d.request(wake_request,compacted.binding,1,function()end).status=='already_consumed','current settled floor prevents recreating publication files')
local altered=copy(wake_request);altered.reply_seq=2
check(compacted.d.request(altered,compacted.binding,1,function()end).status=='already_consumed' and compacted.effects.transports==nil,'floor observation does not retain completed payload fingerprints or execute altered old serials')
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
local wake_projection=waked.raw.execution(submitted,77)
local wake_callback={request_json=runtime.json.encode(submitted),executor_id='window-a',orch_claim=copy(wake_projection.orch_claim),proof=waked.proof(submitted,wake_projection.orch_claim,wake_projection.claim),spawn_claim=copy(wake_projection.claim),result={status='submitted'}}
waked.d.wake_claim(submitted,'window-a','wakeresult',{status='submitted'})
check(waked.d.request(wake_request,waked.binding,1,function()end).payload.wake_status=='submitted','original publication replay exposes durable queued-ask settlement')
local wake_settled=waked.image()
check(waked.engine.retain_relay_result('spawn.wakeresult',runtime.json.encode(wake_callback)) and waked.p.equal(wake_settled,waked.image()),'applied wake repeat retains exact result proof after publication claim cleanup without poisoning settlement')
wake_callback.result.status='uncertain'
check(not waked.engine.retain_relay_result('spawn.wakeresult',runtime.json.encode(wake_callback)) and waked.p.equal(wake_settled,waked.image()),'different wake outcome cannot be acknowledged solely because the request is settled')
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
 check(ackf.d.wake_claim(notify,'window-a','wakeclaim').status=='claimed','host durably claims the separate native wake')
 ackf.effects.callback({status='already_published'})
 check(ackf.raw.execution(notify,77).phase=='claimed','duplicate publication outcome cannot reset a claimed wake')
 check(ackf.d.wake_claim(notify,'window-a','wakebegin').status=='launching','host durably begins the native wake')
 local reboot=fixture(ackf.image())
 check(reboot.d.request(publication,reboot.binding,1,function()end).payload.wake_status=='uncertain' and reboot.raw.execution(notify,77)==nil,'host reload preserves possible ACK wake as uncertain')
 check(reboot.d.wake_claim(notify,'window-a','wakeresult',{status='submitted'},original).status=='rejected','late prior VM wake callback is rejected')
 local result=if accepted then 'submitted' else 'uncertain'
 ackf.d.wake_claim(notify,'window-a','wakeresult',{status=result})
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
check(expiry.status=='rejected' and expiry.error.code=='binding_mismatch','expired authorization is refused at the binding boundary')
check(expired.raw.execution(provision,77)==nil and expired.p.equal(before_expiry,expired.image()) and not expired.effects.transports,'expiry exposes no executable nonce and starts no effect or retry')
local partial=fixture();partial.snapshot.records[1].mailbox.producer=nil;partial.snapshot.records[1].mailbox.capabilities=nil
local partialcat=partial.d.request(partial.req('catalog','partial'),partial.binding,1,function()end)
check(partialcat.status=='catalog' and not partialcat.payload.records[1].eligible,'partial mailbox config is ineligible, not a catalog exception')
end
-- Expiry/earlier VM proves only that this observation is unusable, not that an
-- external effect never happened. Re-staging still requires a fresh peer action.
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
local function unknown(body,r)
 return body.status=='uncertain' and body.category=='unknown_effect' and body.request_id==r.request_id and body.action_id==r.action_id
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
check(unknown(expired,wake) and f.raw.execution(wake,77)==nil,'expired unconsumed challenge is unknown potential effect, not pre-effect success')
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
check(rebooted.raw.execution(rebooted_wake,77)==nil and unknown(outcome_of(rebooted,rebooted_wake),rebooted_wake),'earlier VM challenge reports unknown potential effect')
local capacity=fixture()
check(capacity.d.request(provision,capacity.binding,1,function()end).status=='full','fixture retains a pre-effect capacity refusal')
capacity.raw.stage(provision,capacity.binding,1,77)
capacity.effects.now=1700030001.25
local retained=outcome_of(capacity,provision)
check(unknown(retained,provision),'expired recheck does not relabel a retained pre-effect base as current proof')
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
fencedwake.saved['dispatch-v1'].requests['session/wake']={request=copy(wake_request),request_json=runtime.json.encode(wake_request),body=fencedwake.p.body(wake_request,'published',{wake_status='launching',wake_effect_started=true,wake_target_request_id=wake_request.request_id,wake_target_action_id=wake_request.action_id}),wake={phase='launching',pane_binding=copy(pane),claim={spawn_namespace='spawn-authority',claim_nonce='previous-native-claim',executor_id='window-a',boot='previous-boot'}}}
local inspection=fencedwake.d.recovery_view(fencedwake.binding);local saw_wake=false
for _,item in ipairs(inspection[1].outcomes)do if item.request_id=='wake' and item.wake.phase=='launching'then saw_wake=true end end
check(saw_wake,'recovery inspection includes native wake claims')
check(fencedwake.d.recover_owner(fencedwake.binding,'session',inspection[1].revision,false),'operator fence includes native wake executor')
check(fencedwake.saved['dispatch-v1'].requests['session/wake'].wake.phase=='uncertain' and fencedwake.saved['dispatch-v1'].requests['session/wake'].body.payload.wake_status=='uncertain','owner fencing retains possible native wake as uncertainty')
for _,boundary in ipairs({'snapshot','owner-fence'})do
 local retained=fixture();retained.d.request(retained.launch('owner'),retained.binding,1,function()end)
 local prior=retained.p.body(provision,'uncertain',nil,{code='target_unavailable',message='Original publication may have happened'})
 retained.saved['dispatch-v1'].requests['session/provision']={request=copy(provision),request_json=runtime.json.encode(provision),body=copy(prior),operation='original-operation'}
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
oldread.request_serial=serial(oldread.request_id)
oldread.record_id=nil;oldread.record_revision=nil;oldread.capability=nil;oldread.handle='mailbox';oldread.expected_generation=1;oldread.selector={stream='ack',slot=1}
stagedread.raw.stage(oldread,stagedread.binding,1,77)
local currentread=copy(oldread);currentread.request_id='observed-read';currentread.action_id='observed-action'
currentread.request_serial=serial(currentread.request_id)
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
 publication.request_serial=serial(publication.request_id)
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
  fresh.request_serial=serial(fresh.request_id)
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
  ack2.request_serial=serial(ack2.request_id)
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
  bad.request_serial=serial(bad.request_id)
  check(f.d.request(bad,f.binding,1,function()end).status=='rejected','stop rejects wrong '..field)
 end
 local bad=copy(stop);bad.request_id='bad-generation';bad.worker_generation=2
 bad.request_serial=serial(bad.request_id)
 check(f.d.request(bad,f.binding,1,function()end).status=='rejected','stop rejects successor worker generation')
 bad=copy(stop);bad.request_id='bad-pane';bad.pane_binding.pane_id='56'
 bad.request_serial=serial(bad.request_id)
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
 second.request_serial=serial(second.request_id)
 check(lost.d.request(second,lost.binding,1,function()end).status=='rejected','new request cannot repeat ambiguous stop')
 local old,legacy=retirement_fixture(false)
 check(old.d.request(legacy,old.binding,1,function()end).status=='resolved','ordinary accepted worker can stop without inventing coordinator capability')
 f.effects.fail_write=true
 check(f.d.stop_claim(stop,'window-a','result',{status='stopped',pane_binding=pane,observation='absent'}).error.code=='storage_error' and f.effects.retirements==nil,'failed stopped evidence commit cannot settle reservation')
end
sections.retirement_settlement=function()
 local f,stop=retirement_fixture()
 f.d.request(stop,f.binding,1,function()end)
 f.d.stop_claim(stop,'window-a','claim');f.d.stop_claim(stop,'window-a','begin')
 local stop_projection=f.raw.execution(stop,77)
 local stop_callback={request_json=runtime.json.encode(stop),executor_id='window-a',orch_claim=copy(stop_projection.orch_claim),proof=f.proof(stop,stop_projection.orch_claim,stop_projection.claim),spawn_claim=copy(stop_projection.claim),result={status='stopped',pane_binding=copy(pane),observation='absent'}}
 local stopped=f.d.stop_claim(stop,'window-a','result',{status='stopped',pane_binding=pane,observation='absent'})
 check(stopped.status=='stopped' and f.p.equal(stopped.payload,{pane_binding=pane,observation='absent'}),'host routes exact native stopped outcome')
 check(f.effects.retirements==nil,'native stop alone does not release launch reservation')
 check(f.p.equal(f.d.request(stop,f.binding,1,function()end),stopped),'duplicate stop replays immutable outcome')
 local stopped_before=f.image()
 check(f.engine.retain_relay_result('spawn.result',runtime.json.encode(stop_callback)) and f.p.equal(stopped_before,f.image()),'exact stopped-result repeat has durable outcome proof without adding uncertainty')
 stop_callback.result.observation='exited'
 check(not f.engine.retain_relay_result('spawn.result',runtime.json.encode(stop_callback)) and f.p.equal(stopped_before,f.image()),'different stopped observation cannot reuse a settled native claim as result proof')
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
 premature.request_serial=serial(premature.request_id)
 local calls=f.effects.transports
 check(f.d.request(premature,f.binding,1,function()end).status=='rejected' and f.effects.transports==calls,'in-flight native stop cannot authorize producer deletion')
 f.d.stop_claim(stop,'executor','result',{status='stopped',pane_binding=pane,observation='exited'})
 local authorized=copy(retire);authorized.request_id='authorized';authorized.action_id='authorized-action'
 authorized.request_serial=serial(authorized.request_id)
 f.effects.outcome={status='retired'};f.d.request(authorized,f.binding,1,function()end)
 check(f.effects.operation.retire_producer==true and f.effects.retirements==1,'committed exact stop grants producer cleanup before reservation settlement')
end
-- A launch SPAWN definitively rejected never reached native execution, so ORCH+'s withdrawal can
-- retire its never-used mailbox without a native stop; an executed launch still needs its stop.
sections.unused_retirement=function()
 local f=fixture();f.effects.allow_mailbox=true
 local rejected=f.launch('rejected-launch',{coordinator_owner_id='coordinator-owner',coordinator_generation=2})
 check(f.d.request(rejected,f.binding,1,function()end).error.code=='unsupported_capability' and f.effects.reserves==0,'fixture launch is rejected before any native call')
 local retire=f.req('mailbox_retire','retire-unused',{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='rejected-launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,mode='retire',settlement_revision=5,report_floor=0,report_chain_sha256=f.c.sha256('unused'),reply_floor=0,grant_id='withdraw-grant'})
 f.effects.outcome={status='retired'}
 f.d.request(retire,f.binding,1,function()end)
 check(f.effects.operation~=nil and f.effects.operation.retire_producer==nil and f.saved['dispatch-v1'].requests['session/retire-unused'].body.status=='retired'
  and f.effects.retirements==nil,'the rejected launch\'s unused mailbox retires without a stop, producer cleanup or launch reservation settlement')
 check(f.saved['dispatch-v1'].requests['session/rejected-launch'].body.error.code=='unsupported_capability','retiring the rejected launch\'s mailbox keeps its original rejection code')
 local g,stop=retirement_fixture(false);g.effects.allow_mailbox=true;g.effects.outcome={status='retired'}
 local accepted=g.req('mailbox_retire','retire-accepted',{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,mode='retire',settlement_revision=5,report_floor=0,report_chain_sha256=g.c.sha256('unused'),reply_floor=0,grant_id='accepted-grant'})
 check(g.d.request(accepted,g.binding,1,function()end).status=='rejected' and g.effects.operation==nil and stop~=nil,'an executed launch\'s mailbox still needs its exact native stop')
 -- An expired or restored unclaimed snapshot is not never-executed evidence.
 -- Only the explicit terminal rejection above permits unused retirement.
 local function retire_staged(x,id)
  x.effects.allow_mailbox=true;x.effects.outcome={status='retired'};x.effects.operation=nil
  local q=x.req('mailbox_retire',id,{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='staged',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,mode='retire',settlement_revision=5,report_floor=0,report_chain_sha256=x.c.sha256('unused'),reply_floor=0,grant_id='grant-'..id})
  local answer=x.d.request(q,x.binding,1,function()end)
  local stored=x.saved['dispatch-v1'].requests['session/'..id]
  return if stored then stored.body else answer
 end
 local function shown(body)return ' ['..tostring(body.status)..' '..tostring(body.error and body.error.code)..' '..tostring(body.error and body.error.message)..']' end
 local e=fixture();local staged=e.launch('staged')
 check(e.raw.stage(staged,e.binding,1,77).status=='pending' and e.effects.reserves==0,'the launch is only staged behind a window challenge')
 e.effects.now=1700030001.25
 local expired=retire_staged(e,'retire-expired')
 local fenced=e.saved['dispatch-v1'].requests['session/staged']
 check(expired.status=='rejected' and e.effects.operation==nil and e.effects.retirements==nil,'expired authorization alone cannot retire a potentially used mailbox'..shown(expired))
 check(fenced.authorization~=nil,'refused retirement preserves the unresolved authorization')
 local restaged=e.raw.stage(staged,e.binding,1,77)
 check(restaged.status=='pending' and e.effects.reserves==0 and e.effects.operation==nil,'re-staging obtains only a challenge, never permission inferred from expiry')
 local l=fixture();local live=l.launch('staged')
 l.raw.stage(live,l.binding,1,77)
 local refused=retire_staged(l,'retire-live')
 check(refused.status=='rejected' and refused.error.code=='binding_mismatch' and refused.error.message=='Exact native stop or unaccepted cancellation evidence is missing' and l.effects.operation==nil and l.effects.retirements==nil,'a live launch challenge may still be consumed, so retirement needs exact stop or cancellation evidence'..shown(refused))
 check(l.saved['dispatch-v1'].requests['session/staged'].authorization~=nil,'a refused retirement leaves the live launch challenge untouched')
 local c=fixture();local claimed=c.launch('staged')
 check(c.d.request(claimed,c.binding,1,function()end).status=='resolved','ordinary launch is authorized');c.d.claim(claimed,'executor','claim')
 c.effects.now=1700030001.25
 local claim_refused=retire_staged(c,'retire-claimed')
 check(claim_refused.status=='rejected' and claim_refused.error.code=='binding_mismatch' and c.effects.operation==nil,'a claimed launch may have run, so retirement needs a native stop'..shown(claim_refused))
 local b=fixture();local before_boot=b.launch('staged')
 b.raw.stage(before_boot,b.binding,1,77)
 local rebooted=fixture(b.image());rebooted.launch('staged') -- A new host VM boot with the same registry and clock.
 local reboot_answer=retire_staged(rebooted,'retire-rebooted')
 check(reboot_answer.status=='rejected' and rebooted.effects.operation==nil,'restored earlier-boot absence of a claim cannot authorize unused mailbox retirement'..shown(reboot_answer))
end
sections.failed_startup=function()
 -- HOST fixtures inject only the private nonce-bound witness. Native membership/
 -- absence production is exercised through the actual dispatch_window adapter.
 local function started(actual,terminal)
  local f=fixture(nil,actual);local record=f.snapshot.records[1]
  if terminal then
   record.backend='local-terminal';record.fresh_native_default=nil
   record.fresh_executable='/tools/omp';record.fresh_arguments={'--task'};record.task_argument_index=2
   record.mailbox.wake='worker-poll-v1';record.mailbox.producer.poll=true
   record.mailbox.capabilities={'report-files-v1','worker-poll-v1','argv-v1'};f.effects.wake_route='worker-poll-v1'
  end
  table.insert(record.mailbox.capabilities,'coordinator-control-v1')
  local handle='mailbox'
  if actual then
   local provisioned;f.d.request(provision,f.binding,1,function(value)provisioned=value end)
   handle=assert(provisioned and provisioned.payload.handle)
  end
  local launch=f.launch('launch',{coordinator_owner_id='failed-owner',coordinator_generation=2});launch.mailbox_handle=handle
  assert(f.d.request(launch,f.binding,1,function()end).status=='resolved')
  f.d.claim(launch,'executor','claim');f.d.claim(launch,'executor','begin')
  assert(f.d.claim(launch,'executor','result',{status='submitted',pane_binding=copy(pane)}).status=='awaiting_acceptance')
  f.effects.allow_mailbox=true;f.effects.outcome={status='retired'};f.transport.allow_retire=true
  f.effects.startup_observation=function(projection)
   local state=f.effects.native_state or 'exited'
   if f.effects.no_witness or state~='exited' and state~='absent' then return nil end
   f.effects.witnesses=(f.effects.witnesses or 0)+1
   check(projection.startup_cleanup.backend==record.backend,'private cleanup target preserves the original launch backend')
   local observed=copy(projection.startup_cleanup.pane_binding)
   if f.effects.foreign_pane then observed.pane_id='56' end
   return {pane_binding=observed,observation=state}
  end
  local function retire(id,fields,stage_only)
   local q=f.req('mailbox_retire',id,{worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',
    enrolment_token='aaaaaaaaaaaaaaaa',handle=handle,expected_generation=1,mode='retire',settlement_revision=5,
    report_floor=0,report_chain_sha256=f.c.sha256('report-files-v1\n'..handle..'\n'),reply_floor=0,grant_id='failed-startup-grant'})
   for k,v in pairs(fields or {})do q[k]=v end
   if f.effects.reconcile_before_retire then f.admit_origin(q) end
   if stage_only then return f.raw.stage(q,f.binding,1,77),q,f.raw.execution(q,77) end
   local result;local body=f.d.request(q,f.binding,1,function(value)result=value end)
   return result or body,q
  end
  return f,retire,launch
 end
 for _,terminal in ipairs({false,true})do for _,state in ipairs({'exited','absent'})do
  local f,retire=started(false,terminal);f.effects.native_state=state
  local before=copy(f.saved['dispatch-v1'].requests['session/launch'])
  local result=retire('cleanup-'..state)
  local kept=f.saved['dispatch-v1'].requests['session/launch']
  check(result.status=='retired' and f.effects.witnesses==1 and f.effects.retirements==1
   and f.effects.operation.retire_producer==true and f.effects.operation.cancel_enrolment==true,
   'only fresh exact native '..state..' authorizes zero-floor producer cleanup and original reservation settlement')
  check(kept.mailbox_live==false and kept.acceptance==nil and kept.stopped==nil and kept.stop_request_id==nil
   and f.p.equal(kept.request,before.request) and f.p.equal(kept.pane_binding,before.pane_binding),
   'failed startup preserves immutable launch and pane without inventing stop or acceptance')
  check(f.raw.record_preparation_busy('worker')~=true,'retired failed startup releases the record preparation guard')
 end end
 for _,state in ipairs({'idle','working','waiting-input','unknown'})do
  local f,retire=started();f.effects.native_state=state
  check(retire('live-'..state).status=='rejected' and not f.effects.transports and not f.effects.retirements,
   'HOST requires an actual window witness; unaccepted '..state..' never grants cleanup')
 end
 for _,field in ipairs({'report_floor','reply_floor','report_chain_sha256'})do
  local f,retire=started()
  local result=retire('consumed-'..field,{[field]=if field=='report_chain_sha256' then string.rep('a',64) else 1})
  check(result.status=='rejected' and not f.effects.witnesses and not f.effects.transports,'nonempty producer floor/chain refuses '..field)
 end
 do
  local f,retire,launch=started()
  local accepted=f.req('accept','accepted-startup',{target_request_id='launch',target_action_id=launch.action_id,pane_binding=copy(pane),
   worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('accepted')})
  assert(f.d.request(accepted,f.binding,1,function()end).status=='accepted')
  check(retire('accepted-cleanup').status=='rejected' and not f.effects.witnesses and not f.effects.retirements,'accepted coordinator still needs ordinary stop/release')
 end
 for _,kind in ipairs({'no-witness','foreign-pane','stale-epoch','restored-pane'})do
  local f,retire=started()
  if kind=='no-witness' then f.effects.no_witness=true
  elseif kind=='foreign-pane' then f.effects.foreign_pane=true
  elseif kind=='stale-epoch' then f.saved['dispatch-v1'].requests['session/launch'].pane_binding.window_epoch='old-epoch'
  else f.saved['dispatch-v1'].requests['session/launch'].attachment={origin_binding=copy(f.origin),controller_pane='44',pane_binding=copy(pane)} end
  check(retire('held-'..kind).status=='rejected' and not f.effects.transports and not f.effects.retirements,'window witness cannot authorize '..kind)
 end
 for _,state in ipairs({'absent','exited'})do
  local f,retire=started(false,true);f.effects.native_state=state;f.effects.reconcile_before_retire=true
  local continued=copy(f.origin);continued.window_epoch='continued-epoch';continued.alias_nonce='continued-alias'
  local result=retire('continued-'..state,{origin_binding=continued})
  check(result.status==(if state=='absent' then 'retired' else 'rejected')
   and (f.effects.retirements or 0)==(if state=='absent' then 1 else 0),
   'fresh continued-controller routing accepts only original pane absence, never a restored existing '..state..' target')
 end
 for _,kind in ipairs({'expired','recovered','reload'})do
  local f,retire,launch=started()
  local pending,q,challenge=retire('pending-cleanup',nil,true)
  check(pending.status=='pending' and challenge.startup_cleanup.pane_binding.pane_id=='55' and not f.effects.transports,
   'HOST projects only retained original pane facts, never a fake WindowCx')
  local late=f.req('accept','pending-cleanup-accept',{target_request_id='launch',target_action_id=launch.action_id,pane_binding=copy(pane),
   worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('late acceptance')})
  check(f.d.request(late,f.binding,1,function()end).status=='rejected'
   and f.saved['dispatch-v1'].requests['session/launch'].acceptance==nil,'pending failed-startup retirement fences delayed semantic acceptance')
  local observation={pane_binding=copy(pane),observation='absent'}
  if kind=='expired' then f.effects.now=f.runtime.now()+30001
  elseif kind=='recovered' then local owners=f.d.recovery_view(f.binding);assert(f.d.recover_owner(f.binding,'session',owners[1].revision,false))
  else f=fixture(f.image()) end
  check(f.raw.authorize(q,challenge.nonce,77,function()end,{executor='epoch',epoch=1,grant_id='stale-cleanup'},'fixture-window',nil,observation).status=='rejected'
   and not f.effects.transports and not f.effects.retirements,'late native authorization cannot survive '..kind)
 end
 for _,producer in ipairs({'producer_absent','producer_unsettled'})do
  local f,retire=started(true,true);f.transport.producer_status=producer
  local result=retire('journal-'..producer)
  check(result.status==(if producer=='producer_absent' then 'retired' else 'rejected')
   and (f.effects.retirements or 0)==(if producer=='producer_absent' then 1 else 0),
   'real mailbox adapter requires producer journal proof: '..producer)
  if producer=='producer_unsettled' then
   check(result.error.code=='producer_unsettled' and f.raw.record_preparation_busy('worker')==true
    and not table.find(f.transport.modes,'retire'),'nonempty producer journal retains original generation and never reaches target retirement')
  end
 end
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
 local coordinator=configured.launch('coordinator',{coordinator_owner_id='coordinator-owner',coordinator_generation=2})
 check(configured.d.request(coordinator,configured.binding,1,function()end).status=='resolved','explicit coordinator role launches on approved capable record')
 local projection=configured.d.execution(coordinator,77)
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
  p.request_serial=serial(p.request_id)
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
 blocked_read.request_serial=serial(blocked_read.request_id)
 check(f.d.request(blocked_read,f.binding,1,function()end).status=='full','started notification reservations share the transport host budget')
 local old=copy(f.saved['dispatch-v1'].requests['session/'..wakes[1].request_id].orch_claim)
 local deferred=f.d.wake_claim(wakes[1],'window-a','wakedefer',nil,old)
 check(deferred.status=='full' and deferred.payload.effect_started==false,'busy native refusal releases only a proven unstarted notification')
 check(f.d.request(blocked_read,f.binding,1,function()end).status=='pending','freed execution slot admits independent transport')
 f.d.request(wakes[1],f.binding,1,function()end)
 check(f.d.wake_claim(wakes[1],'window-a','wakeclaim',nil,old).status=='rejected','late old grant cannot claim the safely deferred operation')
 f.d.wake_claim(wakes[1],'window-a','wakeclaim');f.d.wake_claim(wakes[1],'window-a','wakebegin');f.d.wake_claim(wakes[1],'window-a','wakeresult',{status='submitted'})
 local duplicate=copy(publications[1]);duplicate.request_id='duplicate-ack';duplicate.action_id='duplicate-action'
 duplicate.request_serial=serial(duplicate.request_id)
 f.effects.outcome={status='already_published'};f.d.request(duplicate,f.binding,1,function()end)
 local outcome=f.d.request(duplicate,f.binding,1,function()end)
 check(outcome.payload.wake_status=='submitted' and outcome.payload.wake_target_request_id==publications[1].request_id,'publication retry under a distinct ID preserves once-only canonical notification')
 local restored=fixture(f.image())
 check(restored.d.request(duplicate,restored.binding,1,function()end).payload.wake_status=='submitted','once-only notification survives reload')
end
local function attachment_request(f,id)
 local r=f.req('attach_worker',id,{target_request_id='launch',target_action_id='action-launch',previous_origin_binding=copy(f.origin),previous_pane_binding=copy(pane),pane_binding=copy(pane),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',attestation='old_executors_stopped_or_retired'})
 r.origin_binding.owner_generation=2;r.controller_generation=2
 r.origin_binding.window_epoch='new-epoch';r.origin_binding.window_key='new-window';r.origin_binding.alias_nonce='new-alias';r.controller_pane='88'
 r.pane_binding.window_epoch='new-epoch';r.pane_binding.window_key='new-window';r.pane_binding.pane_id='99'
 return r
end
sections.attachment=function()
 do
  local function automatic(f,id)
   local r=attachment_request(f,id)
   r.attestation='same_native_conversation_no_pending_effects'
   r.origin_binding=copy(f.origin);r.origin_binding.window_epoch='reloaded-epoch';r.origin_binding.alias_nonce='reloaded-alias'
   r.controller_generation=r.origin_binding.owner_generation;r.controller_pane='44'
   r.pane_binding=copy(pane);r.pane_binding.window_epoch='reloaded-epoch'
   return r
  end
  local safe=launched_fixture(true);local r=automatic(safe,'auto-reload')
  safe.admit_origin(r)
  local before=safe.effects.reserves
  check(safe.d.request(r,safe.binding,1,function()end).status=='attached','same native accepted conversation reconnects after a quiescent controller epoch change')
  check(safe.effects.reserves==before and safe.saved['dispatch-v1'].requests['session/launch'].body.status=='accepted','automatic attachment preserves accepted launch and does not start another worker')
  for _,field in ipairs({'pane_id','native_session_id'}) do
   local changed=launched_fixture(true);local q=automatic(changed,'changed-'..field)
   changed.admit_origin(q);q.pane_binding[field]='999'
   check(changed.d.request(q,changed.binding,1,function()end).status=='rejected','automatic reconnect rejects changed native identity '..field)
  end
  local held=launched_fixture(true);local wake=queue_wake(held,ack_request(held,2))
  held.d.wake_claim(wake,'old-window','wakeclaim');held.d.wake_claim(wake,'old-window','wakebegin')
  local owners=held.d.recovery_view(held.binding)
  assert(held.d.recover_owner(held.binding,'session',owners[1].revision,false))
  owners=held.d.recovery_view(held.binding);assert(held.d.recover_owner(held.binding,'session',owners[1].revision,true))
  local q=automatic(held,'retired-uncertain')
  q.origin_binding.owner_generation=2;q.controller_generation=2
  held.admit_origin(q)
  check(held.d.request(q,held.binding,1,function()end).status=='rejected','retired uncertain native effects remain held instead of authorizing automatic attachment')
 end
 if runtime.runtime.os=='linux' then
  local f=launched_fixture(false,true)
  local launch=f.saved['dispatch-v1'].requests['session/launch']
  local words=assert(f.load('config').parse_arguments(launch.launch.command))
  local files={['/proc/sys/kernel/random/boot_id']='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'}
  local function stat(pid,parent,group,start)
   local fields={'S',tostring(parent),tostring(group),'100','123','200'}
   for _=7,19 do table.insert(fields,'0') end
   table.insert(fields,tostring(start));return tostring(pid)..' (fixture) '..table.concat(fields,' ')..'\n'
  end
  files['/proc/100/stat']=stat(100,1,100,111);files['/proc/200/stat']=stat(200,100,200,222);files['/proc/300/stat']=stat(300,200,200,333)
  files['/proc/100/cmdline']='/bin/sh\0-c\0'..launch.launch.command..'\0'
  files['/proc/200/cmdline']=table.concat(words,'\0')..'\0'
  files['/proc/300/cmdline']='/bin/sh\0report-helper\0'
  f.effects.procfiles=files;f.effects.native_process={pane=55,child={pid=100},foreground={pid=300}}
  for _,callback in ipairs(f.effects.handlers.spawn) do
   callback({program='/bin/sh',args={'-c',launch.launch.command},cwd='/work',env={TERN_EXE='/tools/tern',TERN_PANE_SOCKET='/runtime/socket',TERN_WINDOW_KEY='',TERN_PANE='55'}})
  end
  check(f.saved['dispatch-v1'].requests['session/launch'].terminal_process==nil,'a fresh spawn or transient startup alone does not qualify a terminal conversation')
  local accepted=f.req('accept','accept-qualified-terminal',{target_request_id='launch',target_action_id=launch.request.action_id,pane_binding=pane,worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('accepted')})
  check(f.d.request(accepted,f.binding,1,function()end).status=='accepted','terminal continuation fixture reaches actual bound ACCEPTED')
  local qualified=f.image()
  check(qualified['dispatch-v1'].requests['session/launch'].terminal_process.provider_pid==200,'post-ACCEPTED actual foreground ancestry retains the configured CLI identity, not its report helper')
  local function automatic(g,id)
   local q=attachment_request(g,id);q.attestation='same_terminal_process_no_pending_effects'
   q.origin_binding=copy(g.origin);q.origin_binding.window_epoch='new-terminal-epoch';q.origin_binding.alias_nonce='new-terminal-alias'
   q.controller_generation=q.origin_binding.owner_generation;q.controller_pane='44'
   q.pane_binding=copy(pane);q.pane_binding.window_epoch='new-terminal-epoch'
   return q
  end
  local restored=fixture(qualified);restored.effects.procfiles=copy(files);restored.effects.native_process=copy(f.effects.native_process)
  local q=automatic(restored,'terminal-reload');restored.admit_origin(q)
  check(restored.d.request(q,restored.binding,1,function()end).status=='attached' and restored.effects.reserves==0,'qualified existing terminal reconnects after reload without launch, prompt replay or mailbox provisioning')
  local changed=fixture(qualified);changed.effects.procfiles=copy(files);changed.effects.native_process=copy(f.effects.native_process)
  changed.effects.procfiles['/proc/200/stat']=stat(200,100,200,999)
  local stale=automatic(changed,'terminal-reused-pid');changed.admit_origin(stale)
  check(changed.d.request(stale,changed.binding,1,function()end).status=='rejected' and changed.effects.reserves==0,'reused terminal PID with a changed OS creation identity remains held')
  local legacy=launched_fixture(true,true);local old=automatic(legacy,'terminal-no-proof');legacy.admit_origin(old)
  local reserves=legacy.effects.reserves
  check(legacy.d.request(old,legacy.binding,1,function()end).status=='rejected' and legacy.effects.reserves==reserves,'legacy terminal proof absence stays held without a replacement launch or human attestation')
 end
 local f=launched_fixture(true);local publication=ack_request(f,2)
 f.d.request(publication,f.binding,1,function()end)
 local r=attachment_request(f,'attach')
 check(f.p.decode(runtime.json.encode(r))~=nil,'explicit attachment uses a closed operation schema')
 local missing=copy(r);missing.attestation=nil
 check(f.p.decode(runtime.json.encode(missing))==nil,'attachment cannot omit owner executor attestation')
 local query=f.req('status','new-window-status',{target_request_id='launch'});query.origin_binding=copy(r.origin_binding);query.controller_pane=r.controller_pane;query.controller_generation=r.controller_generation
 local before=f.image();local status=f.d.request(query,f.binding,1,function()end)
 check(status.category=='stale_binding' and f.p.equal(before,f.image()),'new-window status cannot silently attach or mutate current authority')
 check(f.raw.execution(query,77)==nil,'pre-attachment inspection cannot execute an old claim')
 local original=copy(f.saved['dispatch-v1'].requests['session/launch'].request)
 local recovery=f.d.recovery_view(f.binding)
 check(f.d.recover_owner(f.binding,'session',recovery[1].revision,false),'attachment explicitly fences original origin')
 recovery=f.d.recovery_view(f.binding)
 check(f.d.recover_owner(f.binding,'session',recovery[1].revision,true),'attachment explicitly confirms stopped old executors')
 f.admit_origin(r)
 local result=f.d.request(r,f.binding,1,function()end)
 check(result.status=='attached' and f.p.equal(result.payload.pane_binding,r.pane_binding),'owner-selected exact current pane attaches explicitly')
 check(f.p.equal(f.saved['dispatch-v1'].requests['session/launch'].request,original) and f.p.equal(f.saved['dispatch-v1'].requests['session/launch'].pane_binding,pane),'attachment preserves immutable launch bytes and original pane evidence')
 check(f.d.claim(original,'executor-a','result',{status='submitted',pane_binding=pane}).status=='rejected','old native result rejected after owner route attachment')
 local oldquery=f.req('status','old-status',{target_request_id='launch'})
 check(f.d.request(oldquery,f.binding,1,function()end).category=='stale_binding' and f.raw.execution(oldquery,77)==nil,'old binding cannot regain authority after attachment')
 local notify=f.req('native_wake','attached-wake',{target_request_id=publication.request_id,target_action_id=publication.action_id});notify.origin_binding=copy(r.origin_binding);notify.controller_pane=r.controller_pane;notify.controller_generation=r.controller_generation
 check(f.d.request(notify,f.binding,1,function()end).status=='resolved' and f.p.equal(f.raw.execution(notify,77).pane_binding,r.pane_binding),'existing unstarted ACK notification uses only the explicitly attached route')
 f.d.wake_claim(notify,'new-window','wakeclaim');f.d.wake_claim(notify,'new-window','wakebegin');f.d.wake_claim(notify,'new-window','wakeresult',{status='submitted'})
 local stop=f.req('stop','attached-stop',{target_request_id='launch',target_action_id='action-launch',pane_binding=copy(r.pane_binding),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work'})
 stop.origin_binding=copy(r.origin_binding);stop.controller_pane=r.controller_pane;stop.controller_generation=r.controller_generation
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
 r.request_serial=serial(r.request_id)
 f.admit_origin(r)
 check(f.d.request(r,f.binding,1,function()end).status=='attached','explicitly retired executor records do not prohibit attachment forever')
 check(f.saved['dispatch-v1'].requests['session/'..notify.request_id].body.status=='uncertain','attachment does not pretend the original native wake succeeded')
 check(f.d.wake_claim(notify,'old-executor','wakeresult',{status='submitted'}).status=='rejected','retired old executor cannot deliver a late outcome')
 local read=f.req('mailbox_read','held-generation',{logical_session_id='session',worker_id='worker-id',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,selector={stream='watermark'}})
 read.origin_binding=copy(r.origin_binding);read.controller_pane=r.controller_pane;read.controller_generation=r.controller_generation
 check(f.d.request(read,f.binding,1,function()end).status=='full','unknown earlier wake continues to hold its exact generation after attachment')
 local attach_safe=attachment_request(f,'attach-safe');attach_safe.target_request_id=safe.request_id;attach_safe.target_action_id=safe.action_id;attach_safe.worker_id='safe-worker';attach_safe.previous_pane_binding=safe_pane;attach_safe.pane_binding.pane_id='109'
 check(f.d.request(attach_safe,f.binding,1,function()end).status=='attached','unrelated safe worker attaches while retired uncertain generation stays held')
 local safe_read=copy(read);safe_read.request_id='safe-read';safe_read.action_id='action-safe-read';safe_read.worker_id='safe-worker';safe_read.launch_request_id=safe.request_id;safe_read.handle='safe-mailbox'
 safe_read.request_serial=serial(safe_read.request_id)
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
 check(deferred.status=='full' and deferred.payload.effect_started==false,'fresh exact executor can commit its never-asked outcome before another grant')
 f.d.request(wake,f.binding,1,function()end)
 check(f.d.wake_claim(wake,'executor','wakeresult',{status='submitted'},original).status=='rejected','late old result cannot settle replacement grant')
 local reloaded=fixture(f.image())
 check(reloaded.raw.execution(wake,77)==nil,'reload fences replacement reserved wake before native claim')
 local query=reloaded.req('status','reserved-status',{target_request_id=wake.request_id})
 local result=reloaded.d.request(query,reloaded.binding,1,function()end).payload.outcome
 check(result.status=='full' and result.payload.effect_started==false,'durable explicit never-asked outcome remains pre-effect after reload')
 check(reloaded.d.wake_claim(wake,'executor','wakeclaim',nil,original).status=='rejected','late old claim cannot regain the fenced replacement reservation')
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
check(projection.launch.prompt:find('Copy handover_id and handover_token verbatim',1,true)~=nil and projection.launch.prompt:find('refuses a mismatch before publishing',1,true)~=nil,
 'the preface tells the successor to copy the pair verbatim and that the helper verifies it')
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
-- The launch must present the exact pair whose digest the mailbox was provisioned with.
local g=fixture()
local mistyped=g.launch('successor-mistyped',{handover_id='handover-2',handover_token=token})
mistyped.enrolment.handover_token='handover-token-1235'
local refused=g.d.request(mistyped,g.binding,1,function()end)
check(refused.status=='rejected' and refused.error.code=='binding_mismatch' and refused.error.message:find('handover digest',1,true)~=nil and g.effects.reserves==0,
 'a launch whose handover pair differs from the provisioned digest is refused before any reservation: '..runtime.json.encode(refused))
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
sections.enrol=function()
 local function request(f,id,delivery)
  local r=f.launch(id)
  r.op='enrol';r.fresh=nil;r.cwd=nil;r.placement=nil;r.preserve_context=true;r.delivery=delivery;r.pane_binding=copy(pane)
  r.prompt=f.c.OPEN_CONVERSATION_ASSIGNMENT;r.enrolment.assignment_sha256=f.c.sha256(r.prompt)
  if delivery=='clipboard' then
   local record=f.snapshot.records[1]
   record.backend='local-terminal';record.fresh_native_default=nil;record.fresh_executable='worker';record.fresh_arguments={};record.task_argument_index=1
   record.mailbox.wake='worker-poll-v1';record.mailbox.producer.poll=true;record.mailbox.capabilities={'report-files-v1','worker-poll-v1','argv-v1'}
  end
  return r
 end
 for _,delivery in ipairs({'native_ask','clipboard'}) do
  local f=fixture();local r=request(f,'enrol-'..delivery,delivery)
  check(f.p.decode(runtime.json.encode(r))~=nil,'enrollment is a closed context-preserving request')
  local original=copy(f.snapshot.records[1])
  local resolved=f.d.request(r,f.binding,1,function()end)
  check(resolved.status=='resolved' and f.effects.reserves==0,'enrollment reserves no fresh native launch')
  local beforePreparationRead=f.image()
  check(f.raw.record_preparation_busy('worker')==true and f.p.equal(beforePreparationRead,f.image()),'enrollment without any ordinary launch attempt still blocks host-wide preparation read-only')
  local projection=f.d.execution(r,77)
  check(projection.kind=='enrol' and projection.launch==nil and projection.prompt:sub(-#r.prompt)==r.prompt,'consumer receives exact enrollment bytes and no launch command')
  check(f.c.sha256(projection.prompt:match('ASSIGNMENT_BYTES_BEGIN\n(.*)$'))==r.enrolment.assignment_sha256,'ACCEPTED digest covers exact canonical assignment, not transport instructions')
  check(f.d.claim(r,'enrol-executor','claim').status=='claimed' and f.d.claim(r,'enrol-executor','begin').status=='launching','once-only existing-conversation delivery uses the persisted native claim')
  local status=if delivery=='clipboard' then 'copied' else 'submitted'
  local delivered=f.d.claim(r,'enrol-executor','result',{status=status,pane_binding=copy(pane)})
  check(delivered.status=='awaiting_acceptance' and delivered.payload.prompt_delivery==(if delivery=='clipboard' then 'copied_not_accepted' else 'submitted_not_accepted'),'delivery is not confused with semantic ACCEPTED')
  check(f.effects.reserves==0 and f.effects.observations==0 and f.p.equal(original,f.snapshot.records[1]),'enrollment neither starts a process nor rewrites saved record/account/cwd')
  local damaged=f.image();local projected=damaged['dispatch-v1'].requests['session/'..r.request_id]
  projected.launch.cwd='/invented-launch';projected.launch_sha256=f.p.fingerprint(projected.launch)
  local invalid=fixture(damaged);local invalid_status=invalid.d.request(invalid.req('status','invalid-enrol-'..delivery,{target_request_id=r.request_id}),invalid.binding,1,function()end)
  check(invalid_status.status=='rejected' and invalid_status.error.code=='storage_error','even self-consistently hashed enrollment state cannot acquire fresh-launch fields on reload')
  local accept=f.req('accept','accept-'..delivery,{target_request_id=r.request_id,target_action_id=r.action_id,pane_binding=copy(pane),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('accepted '..delivery)})
  check(f.d.request(accept,f.binding,1,function()end).status=='accepted','matching actual report identity completes enrollment only after delivery')
  check(f.d.request(request(f,'duplicate-'..delivery,delivery),f.binding,1,function()end).error.code=='binding_mismatch','another enrollment cannot seize an already bound conversation')
  local restored=fixture(f.image())
  local observed=restored.d.request(restored.req('status','enrol-status-'..delivery,{target_request_id=r.request_id}),restored.binding,1,function()end)
  check(observed.payload.outcome.status=='accepted','settled enrollment persists without delivery replay on reload')
  check(restored.raw.record_preparation_busy('worker')==true,'accepted enrollment remains busy across reload until exact stop/cancellation and mailbox retirement')
 end
 local f=fixture();local replay=request(f,'replayed-task','native_ask');replay.prompt='Repeat the old coding task';replay.enrolment.assignment_sha256=f.c.sha256(replay.prompt)
 check(f.p.decode(runtime.json.encode(replay))==nil,'closed enrollment schema rejects a noncanonical assignment before dispatch')
 local before_replay=f.image()
 check(f.d.request(replay,f.binding,1,function()end).error.code=='invalid_schema' and f.effects.reserves==0 and not f.effects.transports and f.p.equal(before_replay,f.image()),'new enrollment cannot replay or replace existing task context or mutate authority')
 local g=fixture();local wrong=request(g,'wrong-digest','native_ask');wrong.enrolment.assignment_sha256=g.c.sha256('different')
 check(g.d.request(wrong,g.binding,1,function()end).error.code=='content_conflict','enrollment digest mismatch refuses before delivery')
 local u=fixture();local uncertain=request(u,'copy-uncertain','clipboard');u.d.request(uncertain,u.binding,1,function()end);u.d.claim(uncertain,'x','claim');u.d.claim(uncertain,'x','begin')
 check(u.d.claim(uncertain,'x','result',{status='uncertain'}).status=='uncertain' and u.d.execution(uncertain,77)==nil,'unknown clipboard outcome never reissues the capability')
 check(u.d.claim(uncertain,'x','result',{status='copied',pane_binding=copy(pane)}).status=='uncertain','late clipboard success cannot overwrite an uncertain effect')
 local function cancel(f,r,id)
  return f.req('mailbox_retire',id,{worker_id=r.enrolment.worker_id,worker_generation=1,launch_request_id=r.request_id,work_id=r.work_id,enrolment_token=r.enrolment.enrolment_token,handle=r.mailbox_handle,expected_generation=1,mode='retire',settlement_revision=5,report_floor=0,report_chain_sha256=f.c.sha256('report-files-v1\n'..r.mailbox_handle..'\n'),reply_floor=0,grant_id='cancel-enrolment'})
 end
 check(u.d.request(cancel(u,uncertain,'cancel-unknown'),u.binding,1,function()end).status=='rejected' and not u.effects.transports,'uncertain enrollment delivery is held without fabricated unused-token or native-stop evidence')
 for _,delivery in ipairs({'native_ask','clipboard'}) do
  local f=fixture();local r=request(f,'cancel-'..delivery,delivery)
  f.d.request(r,f.binding,1,function()end);f.d.claim(r,'x','claim');f.d.claim(r,'x','begin')
  f.d.claim(r,'x','result',{status=if delivery=='clipboard' then 'copied' else 'submitted',pane_binding=copy(pane)})
  local retirement=cancel(f,r,'retire-'..delivery);f.effects.allow_mailbox=true;f.effects.outcome={status='retired'}
  local result;f.d.request(retirement,f.binding,1,function(value)result=value end)
  check(result and result.status=='retired' and f.effects.operation.retire_producer==true and f.effects.operation.cancel_enrolment==true,'unaccepted enrollment revokes its exact zero-floor capability through real helper authority')
  local retained=f.saved['dispatch-v1'].requests['session/'..r.request_id]
  check(retained.mailbox_live==false and retained.stopped==nil and retained.stop_request_id==nil and f.effects.retirements==nil,'enrollment cancellation settles association without stopping or pretending to stop existing conversation')
  local late=f.req('accept','late-'..delivery,{target_request_id=r.request_id,target_action_id=r.action_id,pane_binding=copy(pane),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=f.c.sha256('mailbox:report:1'),seq=1,event_sha256=f.c.sha256('late accepted')})
  check(f.d.request(late,f.binding,1,function()end).status=='rejected','a retired capability cannot establish managed acceptance after delayed paste')
 end
 local consumed=fixture();local cr=request(consumed,'consumed-enrol','clipboard');consumed.d.request(cr,consumed.binding,1,function()end);consumed.d.claim(cr,'x','claim');consumed.d.claim(cr,'x','begin');consumed.d.claim(cr,'x','result',{status='copied',pane_binding=copy(pane)})
 consumed.effects.allow_mailbox=true;consumed.effects.outcome={status='rejected',error={code='producer_unsettled'}}
 local result;consumed.d.request(cancel(consumed,cr,'consumed-cancel'),consumed.binding,1,function(value)result=value end)
 check(result and result.status=='rejected' and consumed.saved['dispatch-v1'].requests['session/consumed-enrol'].mailbox_live~=false,'producer-won cancellation refusal preserves capability obligation and does not invent retirement')
end
sections.presentation=function()
 for _,placement in ipairs({'split','replace_if_alone'}) do
  for _,presentation in ipairs({'user_new_tab','coordinator_adjacent'}) do
   for _,backend in ipairs({'native-agent','local-terminal'}) do
    local f=fixture();local record=f.snapshot.records[1];record.placement=placement
    if backend=='local-terminal' then
     record.backend=backend;record.fresh_native_default=nil;record.fresh_executable='worker';record.fresh_arguments={'--fresh'};record.task_argument_index=2
     record.mailbox.wake='worker-poll-v1';record.mailbox.producer.poll=true;record.mailbox.capabilities={'report-files-v1','worker-poll-v1','argv-v1'}
    end
    local original=copy(record);local r=f.launch('presented');r.presentation=presentation;r.execution_cwd='/projects/雪 project';r.cwd=r.execution_cwd
    check(f.d.request(r,f.binding,1,function()end).status=='resolved','explicit conversation presentation overrides saved '..placement..' on '..backend)
    local projection=f.d.execution(r,77)
    check(projection.launch.placement=='tab' and projection.launch.cwd==r.execution_cwd and f.p.equal(record,original),'effective project cwd/new tab leave saved executable/argv/account/revision and placement intact')
   end
  end
 end
 local f=fixture();f.snapshot.records[1].placement='split';local r=f.launch('background');r.presentation='background';r.placement='split';r.execution_cwd='/projects/rollover';r.cwd=r.execution_cwd
 check(f.d.request(r,f.binding,1,function()end).status=='resolved','background successor accepts verified project cwd while retaining selected record placement')
 for _,case in ipairs({
  {backend='local-terminal',placement='tab',accepted=true},
  {backend='local-terminal',placement='replace_if_alone',accepted=false},
  {backend='local-terminal',placement='tab',accepted=false,handover=false},
  {backend='native-agent',placement='replace_if_alone',accepted=true},
  {backend='native-agent',placement='tab',accepted=false},
 }) do
  local f=fixture();local record=f.snapshot.records[1];record.placement='replace_if_alone'
  if case.backend=='local-terminal' then
   record.backend=case.backend;record.fresh_native_default=nil;record.fresh_executable='worker';record.fresh_arguments={'--fresh'};record.task_argument_index=2
   record.mailbox.wake='worker-poll-v1';record.mailbox.producer.poll=true;record.mailbox.capabilities={'report-files-v1','worker-poll-v1','argv-v1'}
  end
  local original=copy(record)
  local handover=if case.handover~=false then {handover_id='rollover-handover',handover_token='bbbbbbbbbbbbbbbb'} else nil
  local r=f.launch('replacement-rollover',handover)
  r.presentation='background';r.placement=case.placement;r.execution_cwd='/projects/rollover 雪';r.cwd=r.execution_cwd
  local result=f.d.request(r,f.binding,1,function()end)
  if case.accepted then
   local projection=f.d.execution(r,77)
   check(result.status=='resolved' and projection.launch.placement==case.placement and projection.launch.cwd==r.execution_cwd,
    'background rollover constructs the exact approved placement and project cwd for '..case.backend)
  else
   check(result.status=='rejected' and result.error.code=='binding_mismatch' and f.effects.reserves==0,
    'background placement allowance cannot replace a terminal or broaden native-agent placement')
  end
  check(f.p.equal(original,record),'rollover presentation never rewrites saved argv, account, revision, cwd or replacement placement')
 end
 local strict=fixture();strict.snapshot.records[1].placement='split';local old=strict.launch('unapproved-placement')
 check(strict.d.request(old,strict.binding,1,function()end).error.code=='binding_mismatch','retained launch without explicit presentation keeps strict saved placement')
 local cwd=fixture();local mismatch=cwd.launch('unapproved-cwd');mismatch.cwd='/projects/not-authorized'
 check(cwd.d.request(mismatch,cwd.binding,1,function()end).error.code=='binding_mismatch','cwd override without execution_cwd proof refuses')
 local revision=fixture();local stale=revision.launch('stale-record');stale.presentation='user_new_tab';revision.snapshot.config_revision=1
 check(revision.d.request(stale,revision.binding,1,function()end).status=='rejected' and revision.effects.reserves==0,'presentation never relaxes exact record revision')
end
-- Live macOS defect: owner recovery revoked a staged, never-authorized accept of a launch still
-- awaiting acceptance. The revocation is a distinct pre-effect outcome, the launch is unchanged,
-- the old controller stays fenced, and after explicit attachment the same immutable acceptance
-- is accepted on the attached route.
sections.accept_recovery=function()
 do
  local pending=launched_fixture(false)
  local original=pending.req('accept','continuation-pending-accept',{target_request_id='launch',target_action_id='action-launch',pane_binding=copy(pane),worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',event_id=pending.c.sha256('mailbox:report:1'),seq=1,event_sha256=pending.c.sha256('accepted')})
  check(pending.raw.stage(original,pending.binding,1,77).status=='pending','unconsumed old-window acceptance is staged, not executed')
  local same=copy(original);same.request_id='same-window-control'
  pending.admit_origin(same)
  check(pending.saved['dispatch-v1'].requests['session/continuation-pending-accept'].authorization.phase=='requested','same-binding reconciliation preserves its live unconsumed permit')
  local next_window=copy(original);next_window.request_id='continued-window-control';next_window.origin_binding.window_epoch='continued-epoch'
  pending.admit_origin(next_window)
  local retained=pending.saved['dispatch-v1'].requests['session/continuation-pending-accept']
  check(retained.authorization==nil and retained.authorization_fence.phase=='requested' and retained.body.status=='rejected' and retained.body.error.code=='authorization_revoked','admitted continuation durably rejects only the never-consumed old-window permit')
  check(pending.saved['dispatch-v1'].requests['session/launch'].body.status=='awaiting_acceptance','continuation does not start, accept or replace the existing launch')
  check(pending.d.request(original,pending.binding,1,function()end).status=='rejected','the fenced original window cannot consume its old permit after continuation')
 end
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
 stale.request_serial=serial(stale.request_id)
 check(f.d.request(stale,f.binding,1,function()end).status=='rejected' and f.saved['dispatch-v1'].requests['session/launch'].body.status=='awaiting_acceptance',
  'the recovered old controller can never accept')
 local attach=attachment_request(f,'attach')
 f.admit_origin(attach)
 check(f.d.request(attach,f.binding,1,function()end).status=='attached','explicit attested attachment rebinds the launch route')
 local fresh=copy(old_accept);fresh.request_id='new-accept';fresh.action_id='action-new-accept'
 fresh.request_serial=serial(fresh.request_id)
 fresh.origin_binding=copy(attach.origin_binding);fresh.controller_pane=attach.controller_pane;fresh.controller_generation=attach.controller_generation;fresh.pane_binding=copy(attach.pane_binding)
 check(f.d.request(fresh,f.binding,1,function()end).status=='accepted' and f.saved['dispatch-v1'].requests['session/launch'].body.status=='accepted',
  'same semantic acceptance in a newly issued request is accepted on the attached route')
 local changed=copy(fresh);changed.request_id='changed-accept';changed.action_id='action-changed-accept';changed.event_sha256=f.c.sha256('different')
 changed.request_serial=serial(changed.request_id)
 check(f.d.request(changed,f.binding,1,function()end).error.code=='content_conflict','a different ACCEPTED event can never be accepted')
end
sections.native_rollback=function()
 local f=fixture();local request=f.launch('rollback-launch')
 check(f.d.request(request,f.binding,1,function()end).status=='resolved','rollback fixture has authorized but unclaimed launch')
 local preclaim=f.image()
 check(f.d.claim(request,'executor-a','claim').status=='claimed','first unpredictable native claim persists')
 local first=copy(f.raw.execution(request,77).claim)
 local peer=f.proof(request,nil,first) -- Simulated ORCH commit survives SPAWN restore.
 check(peer.claim.spawn_claim.claim_nonce==first.claim_nonce,'peer commits exact first nonce before begin')
 local afterclaim=f.image()
 local effects=0
 local function begin(dispatch,native,proof)
  local result=dispatch.engine.claim(request,'executor-a','begin',nil,proof,native)
  if result.status=='launching' then effects+=1 end
  return result
 end
 check(begin(f,first,peer).status=='launching' and effects==1,'one durable begin crosses the native effect boundary')
 local afterbegin=f.image()
 check(f.engine.claim(request,'executor-a','result',{status='submitted',pane_binding=pane},peer,first).status=='awaiting_acceptance','first effect result remains awaiting authority consumption')
 local restored=fixture(preclaim);restored.launch('rollback-launch')
 check(restored.engine.claim(request,'executor-a','claim',nil,peer).status=='claimed','restored preclaim snapshot gets a fresh native nonce')
 local second=copy(restored.raw.execution(request,77).claim)
 check(second.claim_nonce~=first.claim_nonce and second.spawn_namespace==first.spawn_namespace,'claim nonce changes independently of restored allocation counter')
 local mismatch=begin(restored,second,peer)
 check(mismatch.category=='claim_mismatch' and mismatch.status=='uncertain' and effects==1,'retained first peer witness prevents the second native effect after preclaim rollback')
 check(restored.raw.execution(request,77)==nil,'mismatched witness has no executable projection')
 for _,image in ipairs({afterclaim,afterbegin}) do
  local resumed=fixture(image)
  local query=resumed.req('status','restore-status',{target_request_id=request.request_id})
  check(resumed.d.request(query,resumed.binding,1,function()end).payload.outcome.status=='uncertain','at/after-claim restored VM preserves uncertainty')
  check(begin(resumed,first,peer).status~='launching' and effects==1,'old executor boot cannot begin after restored claim')
 end
 local stale=fixture();local q=stale.launch('fresh-proof')
 local exact_bytes=' \n'..runtime.json.encode(q)..'\t'
 check(stale.engine.stage(q,stale.binding,1,77,exact_bytes).status=='pending','proof fixture stages exact noncanonical immutable bytes')
 local challenge=stale.raw.execution(q,77)
 local grant={executor=q.origin_binding.window_epoch,epoch=1,grant_id='fresh-proof-grant'}
 local current=stale.proof(q,grant)
 local invalid=copy(current);invalid.authority_revision=99
 check(stale.engine.authorize(q,challenge.nonce,77,function()end,grant,'executor-a',invalid).category=='stale_revision' and stale.effects.reserves==0,'stale native projection cannot authorize even equal request bytes')
 invalid=copy(current);invalid.request_sha256=stale.c.sha256(runtime.json.encode(q)..' ')
 check(stale.engine.authorize(q,challenge.nonce,77,function()end,grant,'executor-a',invalid).category=='stale_revision' and stale.effects.reserves==0,'semantic JSON equality does not replace immutable exact-byte hash')
 check(stale.engine.authorize(q,challenge.nonce,77,function()end,grant,'executor-a',nil).category=='stale_revision','reverse peer restore with missing action is not a fresh effect grant')
 check(stale.engine.authorize(q,challenge.nonce,77,function()end,grant,'executor-a',current).status=='resolved','exact current proof authorizes only the original immutable request')
 check(stale.saved['dispatch-v1'].requests['session/'..q.request_id].request_json==exact_bytes,'issued bytes persist unchanged through authorization')
 local unknown=stale.req('status','unknown-issued',{target_request_id='absent-request'})
 local observation=stale.d.request(unknown,stale.binding,1,function()end)
 check(observation.category=='unknown_effect' and observation.status=='missing','missing issued peer record above floor never proves no potential effect')
end
sections.owner_retention=function()
 local f=fixture()
 for generation=1,2049 do
  local current=f.d.recovery_view(f.binding)
  check(#current==1 and f.d.recover_owner(f.binding,'session',current[1].revision,false),'current owner fences at generation '..generation)
  current=f.d.recovery_view(f.binding)
  check(f.d.recover_owner(f.binding,'session',current[1].revision,true),'exact confirmed recovery advances generation floor '..generation)
  local root=f.saved['dispatch-v1'];local control=root.sessions.session.control
  check(control.binding==nil and control.generation_floor==generation and control.recovery.phase=='confirmed','only confirmed current recovery and floor remain')
  local successor=f.req('catalog','successor-'..generation)
  successor.origin_binding.owner_generation=generation+1
  successor.origin_binding.window_epoch='epoch-'..(generation+1)
  successor.origin_binding.alias_nonce='alias-'..(generation+1)
  successor.controller_generation=generation+1
  f.admit_origin(successor)
  root=f.saved['dispatch-v1'];control=root.sessions.session.control
  check(control.binding.owner_generation==generation+1 and control.recovery==nil and control.generation_floor==generation,'successor replaces current authority without retired owner history')
  check(root.owners==nil and root.retired_bindings==nil and root.request_fences==nil and root.tombstones==nil and next(root.controls)==nil and next(root.requests)==nil and next(root.workers)==nil,'2048 lifetime recovery cap cannot accumulate historical identities')
 end
 local root=f.saved['dispatch-v1']
 check(root.sessions.session.control.generation_floor==2049 and root.admission_cursor==1 and next(root.sessions,'session')==nil,'2049 confirmed recoveries preserve one active admission')
end
sections.bootstrap=function()
 local creation={request_id='native-create',orch_session_id='session',owner_id='owner',generation=1,authority_namespace='orch-authority',source_nonce='native-source'}
 local key,marker='dispatch-v1','dispatch-v1-initialized'
 local function refused(f,identity,label)
  local before,configuration,writes=f.image(),copy(f.snapshot),f.effects.writes or 0
  local callbacks=0
  local value,why,disposition,code=f.engine.admin_bootstrap(identity,function()callbacks+=1 end)
  check(value==nil and type(why)=='string' and #why>0 and disposition=='refused' and code=='bootstrap_refused',label..' refuses explicit bootstrap')
  check(callbacks==0 and (f.effects.writes or 0)==writes and f.p.equal(before,f.image()) and f.p.equal(configuration,f.snapshot),label..' preserves every existing source and configuration byte')
 end
 local f=fixture(nil,nil,true)
 local before,configuration=f.image(),copy(f.snapshot)
 check(f.p.bootstrap_creation(creation),'bootstrap uses the shared closed native Create validator')
 local source,why,code=f.engine.admin_source_readonly()
 check(source==nil and type(why)=='string' and code=='source_absent','only verified absent root and marker report source_absent')
 check(select(3,f.engine.admin_source(f.binding))=='source_absent','bound source observes absence without establishing an owner')
 check(f.engine.admin_apply('inspect',{},{} )==nil and f.engine.current()==nil,'ordinary inspect and current cannot bootstrap')
 local owner=f.req('owner_status','bootstrap-owner')
 local observation=f.engine.request(owner,f.binding,1,function()end)
 check(observation.status=='rejected' and observation.category=='migration_blocked' and observation.error.code=='migration_blocked'
  and observation.error.message:sub(1,14)=='storage_error:','owner_status refuses a genuinely missing store instead of initializing it')
 local ordinary=f.req('catalog','bootstrap-ordinary')
 check(f.engine.request(ordinary,f.binding,1,function()end).error.code=='storage_error' and f.engine.stage(ordinary,f.binding,1,77).status=='rejected','ordinary managed requests cannot initialize first use')
 check(f.p.equal(before,f.image()) and f.p.equal(configuration,f.snapshot) and not f.effects.writes,'all ordinary missing-store observations are noninitializing')
 local transition,callbacks=nil,0
 f.effects.before_write=function(k,value)
  if k==marker then
   check(f.saved[key]==nil and f.saved[marker]==nil and transition.source_namespace==value,'marker is the first write, after exact candidate capture')
  else
   check(k==key and f.saved[key]==nil and f.saved[marker]==value.namespace and f.effects.write_keys[1]==marker,'registry write requires its own positively read-back initialization marker')
   check(f.effects.reads[marker]>=3 and f.effects.reads[key]>=3,'both absent stores are rechecked, then the marker and still-absent root are read before registry commit')
  end
 end
 local result,problem,disposition,result_code=f.engine.admin_bootstrap(creation,function(candidate)
  callbacks+=1;transition=copy(candidate)
  check(f.p.equal(before,f.image()) and not f.effects.writes,'candidate transition is captured before either initialization write')
  check(candidate.source_revision==1 and candidate.protocol==2 and candidate.state=='ready','candidate proof includes the final assigned save revision')
 end)
 f.effects.before_write=nil
 check(result~=nil and problem==nil and disposition==nil and result_code==nil and callbacks==1,'explicit witnessed first use returns an actual qualification')
 local initialized=copy(f.saved[key])
 check(initialized.version==2 and initialized.revision==1 and f.p.id(initialized.namespace) and initialized.namespace==f.saved[marker] and initialized.authority_namespace==nil,'bootstrap creates only the existing unpaired version2 identity shape')
 check(initialized.next_id==1 and initialized.admission_cursor==0 and next(initialized.sessions)==nil and next(initialized.workers)==nil and next(initialized.requests)==nil and next(initialized.controls)==nil and next(initialized.gates)==nil and next(initialized.mailboxes.generations)==nil,'bootstrap creates no worker, owner, request, plan or migration obligation')
 check(f.effects.writes==2 and f.p.equal(configuration,f.snapshot) and f.effects.reserves==0 and f.effects.observations==0 and f.effects.imports==0 and not f.effects.transports,'bootstrap writes only marker then registry, without changing configuration or running effects')
 check(f.p.equal(transition,result.proof) and result.proof.source_sha256==f.c.sha256(f.c.dispatch_source_bytes(initialized)),'success proves the exact persisted candidate, not an inferred empty source')
 check(f.p.equal(f.engine.current(nil).qualification,result) and f.p.equal(f.engine.admin_source_readonly(),result),'current and fresh read-only source expose the actual initialized qualification')
 before=f.image()
 check(f.engine.request(owner,f.binding,1,function()end).error.code=='migration_blocked' and f.p.equal(before,f.image()),'new empty identity still grants no controller or implicit pairing')
 refused(f,creation,'repeat of successful Create')
 local function peer_for(captured)
  return {proof={source_schema=4,source_revision=20,source_sha256=string.rep('a',64),source_namespace='orch-authority',candidate_namespace='orch-authority',protocol=2,state='ready',phase='stable',managed_sha256=captured.proof.managed_sha256,pending_immutable=0,blockers=0},selection=copy(captured.selection)}
 end
 local inspected=assert(f.engine.admin_apply('inspect',result.proof,peer_for(result)))
 check(inspected.compatibility.kind=='migration' and f.p.equal(before,f.image()),'real inspect accepts the initialized source without mutation')
 local prepared=assert(f.engine.admin_apply('prepare',result.proof,peer_for(result)))
 check(f.saved[key].migration~=nil and f.saved[key].authority_namespace==creation.authority_namespace,'real preparation pairs the new source only through the existing reducer')
 local finished=assert(f.engine.admin_apply('finish',prepared.proof,peer_for(prepared)))
 check(finished.proof.source_revision==3 and f.saved[key].migration==nil and f.saved[key].namespace==initialized.namespace and f.saved[marker]==initialized.namespace and f.p.equal(configuration,f.snapshot),'real finish preserves configuration and the original initialization identity')
 for field in pairs(creation) do
  local invalid=copy(creation);invalid[field]=nil
  refused(fixture(nil,nil,true),invalid,'missing creation '..field)
  invalid=copy(creation);invalid[field]=if field=='generation' then 0 else ''
  refused(fixture(nil,nil,true),invalid,'invalid creation '..field)
 end
 refused(fixture(nil,nil,true),nil,'missing creation')
 refused(fixture(nil,nil,true),false,'nonobject creation')
 local extra=copy(creation);extra.expected={}
 refused(fixture(nil,nil,true),extra,'extra creation field')
 for _,kind in ipairs({'existing','unmarked','marker-only','lost','corrupt','marker-false','marker-mismatch','unreadable-root','unreadable-marker'}) do
  local occupied=if kind=='existing' then launched_fixture(true) elseif kind=='unmarked' or kind=='lost' or kind=='corrupt' or kind=='marker-mismatch' then fixture() else fixture(nil,nil,true)
  if kind=='unmarked' then occupied.saved[marker]=nil
  elseif kind=='marker-only' then occupied.saved[marker]='earlier-source'
  elseif kind=='lost' then occupied.saved[key]=nil
  elseif kind=='corrupt' then occupied.saved[key].version=999
  elseif kind=='marker-false' then occupied.saved[marker]=false
  elseif kind=='marker-mismatch' then occupied.saved[marker]='different-source'
  elseif kind=='unreadable-root' then occupied.effects.fail_read=key
  elseif kind=='unreadable-marker' then occupied.effects.fail_read=marker end
  refused(occupied,creation,kind)
  if kind=='existing' or kind=='unmarked' then
   check(occupied.engine.admin_source_readonly()~=nil,'existing '..kind..' source remains inspectable without initialization')
  else
   check(select(3,occupied.engine.admin_source_readonly())=='source_unavailable' and select(3,occupied.engine.admin_source(occupied.binding))=='source_unavailable',kind..' never masquerades as verified first use')
  end
 end
 for _,kind in ipairs({'absent','lost','corrupt','unreadable','empty-namespace','invalid-namespace'}) do
  local invalid=fixture(nil,nil,true)
  if kind=='absent' then invalid.effects.absent=true
  elseif kind=='unreadable' then invalid.authority.setup_snapshot=function()error('injected configuration read failure')end
  elseif kind=='empty-namespace' then invalid.snapshot.namespace=''
  elseif kind=='invalid-namespace' then invalid.snapshot.namespace=false
  else invalid.effects.setup_error='Configuration '..kind..'; preserve the actual source' end
  refused(invalid,creation,kind..' configuration')
  check(select(3,invalid.engine.admin_source_readonly())=='source_unavailable' and not invalid.effects.writes,kind..' configuration cannot produce source_absent')
 end
 for _,kind in ipairs({'root','marker','configuration','unreadable-root','unreadable-marker','callback-error'}) do
  local raced=fixture(nil,nil,true);local capture
  local value,err,state,failure=raced.engine.admin_bootstrap(creation,function(candidate)
   capture=copy(candidate)
   if kind=='root' then raced.saved[key]=copy(initialized)
   elseif kind=='marker' then raced.saved[marker]='another-create'
   elseif kind=='configuration' then raced.snapshot.namespace='another-config'
   elseif kind=='unreadable-root' then raced.effects.fail_read=key
   elseif kind=='unreadable-marker' then raced.effects.fail_read=marker
   else error('injected transition capture failure') end
  end)
  check(capture~=nil and value==nil and type(err)=='string' and state=='refused' and failure=='bootstrap_refused' and not raced.effects.writes,'single-writer pre-marker recheck refuses '..kind..' without overwriting or fencing an unattempted write')
  if kind=='root' then check(raced.p.equal(raced.saved[key],initialized),'pre-marker root race preserves the competing source') end
  if kind=='marker' then check(raced.saved[marker]=='another-create','pre-marker marker race preserves the competing fence') end
 end
 for _,kind in ipairs({'marker-before','marker-after','marker-read','marker-lost','marker-changed','root-appeared','root-absence-read','configuration-after-marker','root-before','root-after','root-read','root-lost','root-changed','final-marker-read','final-marker-lost','final-marker-changed','commit-notification'}) do
  local failed=fixture(nil,nil,true);local captured,called=nil,0
  if kind=='marker-before' then failed.effects.fail_write_key=marker
  elseif kind=='marker-after' then failed.effects.fail_after_write_key=marker
  elseif kind=='root-before' then failed.effects.fail_write_key=key
  elseif kind=='root-after' then failed.effects.fail_after_write_key=key end
  failed.effects.after_write=function(k)
   if k==marker then
    if kind=='marker-read' then failed.effects.fail_read=marker
    elseif kind=='marker-lost' then failed.saved[marker]=nil
    elseif kind=='marker-changed' then failed.saved[marker]='changed-marker'
    elseif kind=='root-appeared' then failed.saved[key]=copy(initialized)
    elseif kind=='root-absence-read' then failed.effects.fail_read=key
    elseif kind=='configuration-after-marker' then failed.snapshot.namespace='changed-config' end
   else
    if kind=='root-read' then failed.effects.fail_read=key
    elseif kind=='root-lost' then failed.saved[key]=nil
    elseif kind=='root-changed' then failed.saved[key].next_id+=1
    elseif kind=='final-marker-read' then failed.effects.fail_read=marker
    elseif kind=='final-marker-lost' then failed.saved[marker]=nil
    elseif kind=='final-marker-changed' then failed.saved[marker]='changed-marker' end
   end
  end
  if kind=='commit-notification' then failed.engine.install(function()error('injected post-commit notification failure')end) end
  local value,err,state,failure=failed.engine.admin_bootstrap(creation,function(candidate)called+=1;captured=copy(candidate)end)
  check(value==nil and type(err)=='string' and #err>0 and state=='uncertain' and failure=='bootstrap_uncertain' and called==1,kind..' reports uncertainty after the marker write attempt')
  local registry_attempted=kind=='root-before' or kind=='root-after' or kind=='root-read' or kind=='root-lost' or kind=='root-changed' or kind=='final-marker-read' or kind=='final-marker-lost' or kind=='final-marker-changed' or kind=='commit-notification'
  check(failed.effects.writes==(if registry_attempted then 2 else 1) and failed.effects.write_keys[1]==marker,kind..' cannot write the registry without first fencing initialization')
  if kind=='root-appeared' then check(failed.p.equal(failed.saved[key],initialized),'post-marker CAS never overwrites a newly observed root') end
  failed.effects.fail_read=nil;failed.effects.fail_write_key=nil;failed.effects.fail_after_write_key=nil;failed.effects.after_write=nil
  failed.engine.install(nil)
  before=failed.image()
  refused(failed,creation,kind..' retry after clearing injected failures')
  check(failed.engine.qualification()==nil and (failed.engine.current()==nil or failed.engine.current().qualification==nil),kind..' never publishes predicted qualification as successful readback')
  local observed,_,observation_code=failed.engine.admin_source_readonly()
  if failed.saved[key]==nil then
   check(observed==nil and observation_code=='source_unavailable',kind..' uncertain hold prevents source_absent even when both writes are unobserved')
   check(failed.engine.request(failed.req('owner_status','held-owner'),failed.binding,1,function()end).error.code=='migration_blocked',kind..' hold blocks owner reads from recreating a source')
  elseif kind=='root-after' or kind=='root-read' or kind=='commit-notification' then
   check(observed and failed.p.equal(observed.proof,captured),kind..' explicit source observation can prove the exact durable candidate without replay')
  elseif kind=='root-changed' then
   check(observed and not failed.p.equal(observed.proof,captured),'same-revision changed root cannot satisfy the exact captured candidate')
  end
  check(failed.p.equal(before,failed.image()),kind..' reconciliation observations never write or clear the marker')
  local reloaded=fixture(failed.image(),nil,true);local reload_before=reloaded.image()
  reloaded.engine.admin_source_readonly()
  if reloaded.saved[marker]~=nil or reloaded.saved[key]~=nil then
   refused(reloaded,creation,kind..' reloaded persisted fence')
  else
   check(reloaded.engine.admin_apply('inspect',{},{} )==nil and reloaded.engine.request(reloaded.req('owner_status','reloaded-absent'),reloaded.binding,1,function()end).error.code=='migration_blocked',kind..' reload does not automatically replay an unobserved initialization')
  end
  check(reloaded.p.equal(reload_before,reloaded.image()) and not reloaded.effects.writes,kind..' reload leaves all persisted evidence untouched')
 end
 local held=fixture()
 held.effects.fail_write=true
 held.d.request(held.req('catalog','unrelated-write'),held.binding,1,function()end)
 held.effects.fail_write=nil;held.saved[key]=nil;held.saved[marker]=nil
 refused(held,creation,'prior unrelated uncertain write hold')
 check(select(3,held.engine.admin_source_readonly())=='source_unavailable','unrelated global hold cannot qualify an apparently empty store for bootstrap')
end
sections.administration=function()
 local f=fixture(nil,nil,true)
 local original={empty=runtime.json.array(),items=runtime.json.array({'retained'}),object={}}
 local cloned=f.p.clone(original)
 check(runtime.json.encode(cloned.empty)=='[]' and runtime.json.encode(cloned.object)=='{}' and cloned.items[1]=='retained','deep clone preserves native JSON array and object shapes without cloning protected metatables')
 table.remove(cloned.items)
 check(runtime.json.encode(cloned.items)=='[]' and original.items[1]=='retained','a cloned nonempty array remains an array when emptied and never aliases its source')
 local setup={schema=2,origin='orchplus',op='catalog',request_id='admin-setup',action_id='admin-setup-action',setup_origin={host_pane_id='12',window_key='',window_epoch='setup-epoch',native_session_id='3',window_host_id='7'}}
 check(f.engine.request(setup,f.binding,1,function()end).status=='catalog' and next(f.saved)==nil,'ordinary setup catalog cannot initialize migration identity')
 check(f.engine.admin_apply('inspect',{},{} )==nil and next(f.saved)==nil,'administrative apply without captured source cannot initialize missing identity')
 local absent_before=f.image()
 local source,why,code=f.engine.admin_source_readonly()
 check(source==nil and type(why)=='string' and code=='source_absent' and f.p.equal(absent_before,f.image()) and not f.effects.writes,'pane-free inspection identifies verified absence without initializing either store')
 source,why,code=f.engine.admin_source(f.binding)
 check(source==nil and type(why)=='string' and code=='source_absent' and f.p.equal(absent_before,f.image()) and not f.effects.writes,'bound inspection also identifies true first use without initialization')
 local seed={['dispatch-v1']={version=2,revision=1,namespace='spawn-source',next_id=1,admission_cursor=0,sessions={},workers={},controls={},requests={},mailboxes={version=1,generations={}},gates={}},['dispatch-v1-initialized']='spawn-source'}
 do
  local legacy=fixture({['dispatch-v1']={version=1,revision=1,namespace='legacy-source',next_id=1,
   owners={},tombstones=runtime.json.array(),request_fences={},requests={},mailboxes={version=1,generations={}},gates={}}},nil,true)
  local before=legacy.image();local captured=assert(legacy.engine.admin_source_readonly())
  local projection=legacy.engine.current(nil)
  check(projection.protocol==1 and projection.phase=='legacy' and projection.qualification.proof.protocol==1
   and legacy.p.equal(captured,projection.qualification) and legacy.p.equal(before,legacy.image()),
   'unconverted legacy source is not mislabeled as an actually prepared candidate')
 end
 f=fixture(seed,nil,true)
 local source_before,authority_before=f.image(),copy(f.snapshot)
 check(f.engine.current(nil).qualification==nil,'existing source needs no prior managed qualification')
 source,why=f.engine.admin_source_readonly()
 check(source~=nil and f.p.equal(source_before,f.image()) and f.p.equal(authority_before,f.snapshot) and not f.effects.writes and f.effects.setup_reads==1,'pane-free source before qualification reads validated authority and leaves both stores unchanged: '..tostring(why))
 check(f.p.equal(f.engine.current(nil).qualification,source),'current projection exposes only the genuine freshly captured qualification')
 local bound=assert(f.engine.admin_source(f.binding))
 check(f.p.equal(bound,source) and f.p.equal(source_before,f.image()) and not f.effects.writes,'bound and pane-free inspection return identical genuine source and selection')
 local guarded=fixture(seed,nil,true)
 guarded.authority.managed_snapshot=function(binding)
  check(binding==guarded.binding,'bound source forwards its exact native binding')
  return nil,'Native binding is stale; reconnect'
 end
 check(guarded.engine.admin_source(guarded.binding)==nil and guarded.p.equal(seed,guarded.image()) and not guarded.effects.writes,'bound source retains the managed authority safeguard')
 for _,failure in ipairs({'absent','unvalidated','lost'}) do
  local rejected=fixture(seed,nil,true)
  if failure=='absent' then rejected.effects.absent=true
  else rejected.effects.setup_error=if failure=='lost' then 'Authority missing after initialization; restore the matching store' else 'Authority is invalid; preserve and restore the source' end
  local before,authority=rejected.image(),copy(rejected.snapshot)
  local result,problem,code=rejected.engine.admin_source_readonly()
  check(result==nil and type(problem)=='string' and #problem>0 and code=='source_unavailable' and rejected.p.equal(before,rejected.image()) and rejected.p.equal(authority,rejected.snapshot) and not rejected.effects.writes,'pane-free inspection refuses '..failure..' authority without mutation')
 end
 local invalid=fixture(seed,nil,true);invalid.saved['dispatch-v1'].version=999
 local invalid_before=invalid.image()
 local invalid_source,invalid_error,invalid_code=invalid.engine.admin_source_readonly()
 check(invalid_source==nil and type(invalid_error)=='string' and invalid_code=='source_unavailable' and invalid.p.equal(invalid_before,invalid.image()) and not invalid.effects.writes,'unvalidated dispatch source is refused without repair or adoption')
 check(source.projection==nil and f.c.validate_dispatch_migration_selection(source.selection) and #source.selection.logical_session_ids==0 and #source.selection.mailbox_handles==0,'native qualification carries bounded canonical reference selection, never full managed identity')
 local function peer_for(captured)
  return {proof={source_schema=4,source_revision=20,source_sha256=string.rep('a',64),source_namespace='orch-authority',candidate_namespace='orch-authority',protocol=2,state='ready',phase='stable',managed_sha256=captured.proof.managed_sha256,pending_immutable=0,blockers=0},selection=copy(captured.selection)}
 end
 local peer=peer_for(source);local before=f.image()
 local inspected=f.engine.admin_apply('inspect',source.proof,peer)
 check(inspected and inspected.compatibility.kind=='migration' and inspected.projection==nil and f.p.equal(inspected.selection,source.selection) and f.p.equal(before,f.image()),'native inspect publishes exact source pair and bounded references without persisting migration or exposing full normal form')
 check(f.p.equal(f.engine.qualification().proof,source.proof),'explicit source qualification is exposed only at its captured revision')
 local wrong=copy(peer);wrong.proof.managed_sha256=f.c.sha256('different peer projection')
 check(f.engine.admin_apply('prepare',source.proof,wrong)==nil and f.p.equal(before,f.image()),'peer digest must equal complete independently derived local managed identity')
 wrong=copy(peer);table.insert(wrong.selection.logical_session_ids,'unseen-session')
 check(f.engine.admin_apply('prepare',source.proof,wrong)==nil and f.p.equal(before,f.image()),'extra peer logical reference cannot invent a current managed identity')
 wrong=copy(peer);table.insert(wrong.selection.mailbox_handles,'unseen-mailbox')
 check(f.engine.admin_apply('prepare',source.proof,wrong)==nil and f.p.equal(before,f.image()),'extra peer mailbox reference cannot qualify an unmatched generation')
 wrong=copy(peer);wrong.selection.extra=true
 check(f.engine.admin_apply('prepare',source.proof,wrong)==nil and f.p.equal(before,f.image()),'selection is closed rather than normalized around unsupported fields')
 wrong=copy(peer);wrong.projection={}
 check(f.engine.admin_apply('prepare',source.proof,wrong)==nil and f.p.equal(before,f.image()),'obsolete full-normal transport is refused even beside valid bounded references')
 local stale=copy(source.proof);stale.source_sha256=f.c.sha256('other local bytes')
 check(f.engine.admin_apply('prepare',stale,peer)==nil and f.p.equal(before,f.image()),'captured own hash is independently rechecked before any save')
 f.saved['dispatch-v1'].next_id+=1 -- Same namespace and revision, different canonical source bytes.
 before=f.image()
 local current=f.engine.current()
 check(current and current.qualification==nil and f.engine.qualification()==nil and f.p.equal(before,f.image()),'same-revision source replacement cannot relabel or expose captured qualification')
 check(f.engine.admin_apply('prepare',source.proof,peer)==nil and f.p.equal(before,f.image()),'prepare independently rejects same-revision changed local content')
 source=assert(f.engine.admin_source(f.binding));peer=peer_for(source)
 check(f.p.equal(f.engine.current().qualification.proof,source.proof),'only explicit recapture publishes qualification for replacement bytes')
 f.saved['dispatch-v1'].revision+=1 -- Another committed owner operation, after native capture.
 before=f.image()
 check(f.engine.qualification()==nil,'changed local source invalidates ephemeral published qualification')
 check(f.engine.admin_apply('prepare',source.proof,peer)==nil and f.p.equal(before,f.image()),'stale captured local source cannot prepare after an intervening owner commit')
 local fresh=assert(f.engine.admin_source(f.binding));peer=peer_for(fresh)
 local prepared,problem=f.engine.admin_apply('prepare',fresh.proof,peer)
 check(prepared and f.saved['dispatch-v1'].migration~=nil and f.saved['dispatch-v1'].authority_namespace=='orch-authority','exact fresh native pair prepares through the migration owner: '..tostring(problem))
 check(f.engine.current(nil).protocol==2 and f.engine.current(nil).phase=='prepared',
  'prepared current phase comes from the actual persisted candidate, not canonical proof phase')
 before=f.image()
 check(f.engine.admin_apply('finish',fresh.proof,peer)==nil and f.p.equal(before,f.image()),'preparation source cannot be reused as current finish proof')
 peer=peer_for(prepared);wrong=copy(peer)
 wrong.proof.source_namespace='another-orch';wrong.proof.candidate_namespace='another-orch'
 check(f.engine.admin_apply('finish',prepared.proof,wrong)==nil and f.p.equal(before,f.image()),'matching empty references and managed digest cannot replace the already-paired peer namespace')
 local completed,finish_error=f.engine.admin_apply('finish',prepared.proof,peer)
 check(completed and f.saved['dispatch-v1'].migration==nil and f.saved['dispatch-v1'].namespace==source.proof.candidate_namespace and f.saved['dispatch-v1'].authority_namespace=='orch-authority','finish keeps both exact independent source identities: '..tostring(finish_error))
 check(f.engine.current(nil).protocol==2 and f.engine.current(nil).phase=='stable',
  'finished current phase comes from the actual removal of the prepared migration')
 local missing=f.image();missing['dispatch-v1']=nil
 local lost=fixture(missing,nil,true);before=lost.image()
 check(select(3,lost.engine.admin_source(lost.binding))=='source_unavailable' and lost.p.equal(before,lost.image()),'explicit inspection cannot initialize over a missing previously-marked source')
 check(select(3,lost.engine.admin_source_readonly())=='source_unavailable' and lost.p.equal(before,lost.image()) and not lost.effects.writes,'pane-free inspection also refuses lost marked source without recovery')
 local active=fixture();local captured=assert(active.engine.admin_source(active.binding))
 check(captured.projection==nil and #captured.selection.logical_session_ids==1 and captured.selection.logical_session_ids[1]=='session','current managed session participates in complete bounded selection')
 local omitted=peer_for(captured);omitted.selection.logical_session_ids=runtime.json.array()
 before=active.image()
 check(active.engine.admin_apply('inspect',captured.proof,omitted)==nil and active.p.equal(before,active.image()),'even matching complete managed digest cannot authorize a peer-selected subset of current sessions')
 local failed=fixture(seed,nil,true);local initial=assert(failed.engine.admin_source_readonly())
 local transition,callbacks=nil,0
 before=failed.image();failed.effects.fail_after_write=true
 local result,commit_error,disposition=failed.engine.admin_apply('prepare',initial.proof,peer_for(initial),function(candidate)
  callbacks+=1;transition=copy(candidate)
  check(failed.p.equal(before,failed.image()),'predicted transition is published before durable write')
  check(candidate.source_revision==initial.proof.source_revision+1,'predicted proof includes final assigned commit revision')
 end)
 check(result==nil and type(commit_error)=='string' and disposition=='uncertain' and callbacks==1 and transition~=nil,'write-then-throw is an uncertain commit, not a refused candidate')
 check(failed.saved['dispatch-v1'].migration~=nil and failed.saved['dispatch-v1'].revision==transition.source_revision,'injected write-then-throw really persisted the prepared candidate')
 before=failed.image()
 local observed=failed.engine.admin_source_readonly()
 check(observed and failed.p.equal(observed.proof,transition) and failed.p.equal(before,failed.image()),'read-only inspection under commit hold proves the exact observed transition without recovery mutation')
 check(#failed.engine.result_deliveries()==0 and failed.p.equal(before,failed.image()),
  'validated receipt-free source remains reachable for explicit read-only reconciliation under an unrelated write hold')
 local refused=fixture(seed,nil,true);assert(refused.engine.admin_source(refused.binding))
 refused.saved['dispatch-v1'].revision=9007199254740991
 local exhausted=assert(refused.engine.admin_source(refused.binding));local invoked=false
 before=refused.image()
 result,commit_error,disposition=refused.engine.admin_apply('prepare',exhausted.proof,peer_for(exhausted),function()invoked=true end)
 check(result==nil and type(commit_error)=='string' and disposition=='refused' and not invoked and refused.p.equal(before,refused.image()),'candidate refused before write publishes no transition and preserves source bytes')
end
sections.consumed_status=function()
 local function acknowledge(f,launch,tag)
  local root=f.saved['dispatch-v1']
  local ack={schema=2,origin='orchplus',op='reconcile_session',request_id='consume-'..tag,action_id='consume-action-'..tag,authority_namespace=launch.authority_namespace,authority_revision=100,logical_session_id='session',admission_seq=1,control_origin={kind='active',binding=copy(f.origin),controller_pane='44'},compatibility={schema=1,kind='current',protocol=2,authority_namespace=launch.authority_namespace,spawn_namespace=root.namespace},generation_floor=0,next_request_serial=1000000,settled_before=launch.request_serial+1,consumed=runtime.json.array()}
  ack.page_limit=f.c.DISPATCH.outstanding
  local staged=f.raw.stage(ack,f.binding,1,77)
  local challenge=f.raw.execution(ack,77)
  check(staged==nil and challenge and challenge.kind=='control_authorize','completed launch ACK requires ephemeral native control challenge, not a public pending outcome')
  local peer={protocol=2,phase='stable',authority_namespace=ack.authority_namespace,authority_revision=100,spawn_namespace=root.namespace,session={admission_seq=1,control={phase='open',generation_floor=0,request_floor=ack.settled_before,next_request_serial=ack.next_request_serial,last_authority_revision=100,binding=copy(f.origin)}}}
  check(f.engine.control_authorize(ack,challenge.nonce,77,'fixture-window',peer).status=='reconciled','exact peer consumed floor reclaims completed issued request')
  return ack
 end
 local f=fixture();local launch=f.launch('consumed-launch');launch.record_id='unavailable-record'
 check(f.d.request(launch,f.binding,1,function()end).status=='rejected' and f.effects.reserves==0,'old launch is explicitly rejected before reserving or executing a worker')
 local ack=acknowledge(f,launch,'rejected')
 local key='session/'..launch.request_id;local root=f.saved['dispatch-v1']
 check(root.requests[key]==nil and root.workers[key]==nil,'ACK of terminal pre-effect rejection leaves no current worker')
 local replacement=copy(launch)
 replacement.record_id='worker';replacement.action_id='new-launch-action';replacement.request_serial=serial('new-launch-serial');replacement.settled_before=ack.settled_before
 check(f.raw.stage(replacement,f.binding,1,77).status=='pending','new issued launch action may reuse only a consumed pre-effect request-ID without a current worker')
 local old=f.req('status','old-launch-status',{target_request_id=launch.request_id})
 old.target_request_serial=launch.request_serial
 local before=f.image();local observed=f.d.request(old,f.binding,1,function()end)
 check(observed.status=='already_consumed' and observed.category=='already_consumed' and f.p.equal(before,f.image()),'old serial below floor is consumed before considering a newer action using the same request-ID')
 local fresh=copy(old);fresh.request_id='new-launch-status';fresh.action_id='new-launch-status-action';fresh.target_request_serial=replacement.request_serial
 observed=f.d.request(fresh,f.binding,1,function()end)
 check(observed.status=='found' and observed.payload.outcome.action_id==replacement.action_id and observed.payload.outcome.request_serial==replacement.request_serial,'status for the new serial observes only its own pending immutable action')
 local accepted=launched_fixture(true);local original=copy(accepted.saved['dispatch-v1'].requests['session/launch'].request)
 ack=acknowledge(accepted,original,'accepted')
 root=accepted.saved['dispatch-v1']
 check(root.requests['session/launch']==nil and root.workers['session/launch']~=nil,'ACK of accepted launch retains current worker facts')
 local duplicate=copy(original);duplicate.action_id='duplicate-current-worker';duplicate.request_serial=serial('duplicate-current-worker');duplicate.settled_before=ack.settled_before
 before=accepted.image();local reservations=accepted.effects.reserves
 local refused=accepted.raw.stage(duplicate,accepted.binding,1,77)
 check(refused.status=='rejected' and accepted.raw.execution(duplicate,77)==nil and accepted.effects.reserves==reservations and accepted.p.equal(before,accepted.image()),'new serial cannot relaunch a retained current worker through request-ID reuse')
end
sections.scope_progress=function()
 local f=fixture()
 local first=f.engine.current('session')
 local function control(operation,tag,same_scope)
  local origin=copy(f.origin)
  if not same_scope then origin.logical_session_id='other-session';origin.owner_id='other-owner';origin.alias_nonce='other-alias' end
  local admission,revision=if same_scope then 1 else 2,if same_scope then 101 else 100
  local request={schema=2,origin='orchplus',op=operation,request_id=tag,action_id='action-'..tag,
   authority_namespace='orch-authority',authority_revision=revision,logical_session_id=origin.logical_session_id,admission_seq=admission,
   control_origin={kind='active',binding=origin,controller_pane='44'},
   compatibility=copy(first.compatibility),generation_floor=0,next_request_serial=1000000,settled_before=1,consumed=runtime.json.array()}
  if operation=='reconcile_session' then request.page_limit=16 end
  assert(f.raw.stage(request,f.binding,1,77)==nil)
  local challenge=assert(f.engine.execution(request,77))
  local peer={protocol=2,phase='stable',authority_namespace='orch-authority',authority_revision=revision,spawn_namespace=first.spawn_namespace,
   session={admission_seq=admission,control={phase='open',generation_floor=0,request_floor=1,next_request_serial=1000000,last_authority_revision=revision,binding=copy(origin)}}}
  local response=f.engine.control_authorize(request,challenge.nonce,77,'fixture-window',peer)
  assert(response.category=='current_admission',response.error and response.error.message)
 end
 control('admit_session','progress-other-admit')
 for index=1,3 do control('reconcile_session','progress-other-'..index) end
 local unchanged=f.engine.current('session')
 check(unchanged.authority_revision>first.authority_revision and unchanged.session_progress==first.session_progress,
  'another admitted session and its repeated reconciliations never change this session delivery fingerprint')
 local request=f.req('catalog','progress-late-catalog')
 assert(f.raw.stage(request,f.binding,1,77).status=='pending')
 local arrived=f.engine.current('session')
 check(arrived.session_progress~=unchanged.session_progress and f.p.equal(arrived.sessions.session.control,unchanged.sessions.session.control),
  'a late outstanding request changes scoped progress even when admission counters and control remain unchanged')
 assert(f.d.request(request,f.binding,1,function()end).status=='catalog')
 local completed=f.engine.current('session')
 check(completed.session_progress~=arrived.session_progress,
  'the current result changes scoped progress before its acknowledgement without retaining completed history')
 local before=f.image()
 local observed=f.d.request(f.req('owner_status','progress-read'),f.binding,1,function()end)
 check(observed.category=='current_admission' and f.engine.current('session').session_progress==completed.session_progress and f.p.equal(before,f.image()),
  'read-only owner observation and scoped projection cannot mutate either store or its delivery fingerprint')
 control('reconcile_session','progress-same-observation',true)
 local repaged=f.engine.current('session')
 check(repaged.sessions.session.control.last_authority_revision>completed.sessions.session.control.last_authority_revision
  and repaged.session_progress==completed.session_progress,
  'a later page observation advances its authority fence without inventing delivery progress')
end
sections.relay_fence=function()
 local f=fixture();local r=f.launch('relay-launch')
 local relay=f.c.sha256('actual-orch-host-pane-12:source:lane:incarnation')
 local other=f.c.sha256('different-relay-incarnation')
 local bytes=runtime.json.encode(r)
 local pending=f.engine.stage(r,f.binding,1,12,bytes,relay)
 local projection=f.engine.execution(r,12,relay)
 check(pending.status=='pending' and projection.kind=='authorize' and type(projection.deadline)=='number','trusted relay receives an actual expiring private authorization challenge')
 check(f.engine.execution(r,12,other)==nil and f.engine.execution(r,12)==nil,'neither another relay nor retained pane transport sees the private projection')
 local before=f.image()
 check(f.engine.stage(r,f.binding,1,12,bytes,other).error.code=='binding_mismatch' and f.p.equal(before,f.image()),'same native pane number cannot rebind an immutable request to another relay incarnation')
 local grant={executor=r.origin_binding.window_epoch,epoch=1,grant_id='relay-grant'}
 local proof=f.proof(r,grant)
 check(f.engine.authorize(r,projection.nonce,12,function()end,grant,'relay-window',proof,other).status=='rejected','another relay cannot consume the exact otherwise valid nonce')
 check(f.engine.authorize(r,projection.nonce,12,function()end,grant,'relay-window',proof,relay).status=='resolved','the original relay can consume the matching current authorization')
 local authorized=f.engine.execution(r,12,relay)
 check(authorized.nonce==projection.nonce and authorized.deadline==projection.deadline,'native execution preserves the original nonce and deadline without polling renewal')
 check(f.engine.claim(r,'relay-window','claim',nil,f.proof(r),nil,other).status=='rejected' and f.engine.claim(r,'relay-window','claim',nil,f.proof(r)).status=='rejected','native claim cannot bypass the relay fence through another transport API')
 check(f.engine.claim(r,'relay-window','claim',nil,f.proof(r),nil,relay).status=='claimed','exact current relay establishes one persisted native claim')
 local native=f.engine.execution(r,12,relay).claim
 local witnessed=f.proof(r,nil,native)
 f.effects.now=projection.deadline+1
 check(f.engine.claim(r,'relay-window','begin',nil,witnessed,native,relay).error.code=='stale_binding','delayed immutable begin cannot execute after original native consent expires')
 check(f.engine.execution(r,12,relay).deadline==projection.deadline,'observing expired consent never extends its deadline')
 local restored=fixture(f.image())
 check(restored.engine.execution(r,12,other)==nil,'host reload cannot project a retained action into a replacement relay')
 local legacy=fixture();local old=legacy.launch('old-pane-launch')
 check(legacy.d.request(old,legacy.binding,1,function()end).status=='resolved','retained pane-origin request exists before cutover')
 local legacy_before=legacy.image()
 check(legacy.engine.stage(old,legacy.binding,1,12,runtime.json.encode(old),relay).error.code=='binding_mismatch' and legacy.p.equal(legacy_before,legacy.image()),'untagged historical bridge identity is never silently rebound')
 check(legacy.engine.execution(old,12,relay)==nil,'old resolved work cannot become new relay execution')
 local status=legacy.d.request(legacy.req('status','old-pane-status',{target_request_id=old.request_id}),legacy.binding,1,function()end)
 check(status.status=='found' and status.payload.outcome.status=='resolved','retained old outcome remains honestly inspectable for recovery')
 local completed=fixture();local q=completed.launch('relay-result')
 completed.engine.stage(q,completed.binding,1,12,runtime.json.encode(q),relay)
 local challenge=completed.engine.execution(q,12,relay)
 local qgrant={executor=q.origin_binding.window_epoch,epoch=1,grant_id='relay-result-grant'}
 check(completed.engine.authorize(q,challenge.nonce,12,function()end,qgrant,'relay-window',completed.proof(q,qgrant),relay).status=='resolved','result fixture acquires original bounded consent')
 check(completed.engine.claim(q,'relay-window','claim',nil,completed.proof(q),nil,relay).status=='claimed','result fixture claims before expiry')
 local qnative=completed.engine.execution(q,12,relay).claim;local qproof=completed.proof(q,nil,qnative)
 check(completed.engine.claim(q,'relay-window','begin',nil,qproof,qnative,relay).status=='launching','effect begins only under fresh original consent')
 local begun_image=completed.image()
 completed.effects.now=challenge.deadline+1
 check(completed.engine.claim(q,'relay-window','result',{status='submitted',pane_binding=copy(pane)},qproof,qnative,relay).status=='awaiting_acceptance','a genuinely begun effect result remains reconcilable after consent expires')
 local stale=fixture(begun_image)
 local callback={request_json=runtime.json.encode(q),executor_id='relay-window',orch_claim=copy(qgrant),proof=copy(qproof),spawn_claim=copy(qnative),result={status='submitted',pane_binding=copy(pane)}}
 local callback_bytes=runtime.json.encode(callback)
 local applied_before=completed.image()
 check(completed.engine.retain_relay_result('spawn.result',callback_bytes) and completed.p.equal(applied_before,completed.image()),'exact already-applied result repeat acknowledges without creating an unresolved evidence obligation')
 local applied_reload=fixture(applied_before)
 check(applied_reload.engine.retain_relay_result('spawn.result',callback_bytes) and applied_reload.saved['dispatch-v1'].requests['session/'..q.request_id].relay_result==nil,'reload between applying result and transport ACK preserves exact result repeat proof')
 local conflicting=copy(callback);conflicting.result.pane_binding.pane_id='56'
 check(not completed.engine.retain_relay_result('spawn.result',runtime.json.encode(conflicting)) and completed.p.equal(applied_before,completed.image()),'another result cannot borrow the settled phase as outcome proof')
 conflicting=copy(callback);conflicting.orch_claim.grant_id='another-grant'
 check(not completed.engine.retain_relay_result('spawn.result',runtime.json.encode(conflicting)),'a different base grant cannot borrow the native witness')
 check(stale.engine.retain_relay_result('spawn.result',callback_bytes),'stale exact post-effect bytes can be retained against their existing original request')
 local evidence=stale.saved['dispatch-v1'].requests['session/'..q.request_id]
 check(evidence.relay_result.bytes==callback_bytes and evidence.body.status=='uncertain' and evidence.pane_binding==nil and stale.p.equal(evidence.claim,qnative),'retained evidence never applies a result, substitutes a pane, or renews its original native claim')
 local retained_before=stale.image()
 check(stale.engine.retain_relay_result('spawn.result',callback_bytes) and stale.p.equal(retained_before,stale.image()),'identical retained evidence retry performs no authority write')
 callback.result.pane_binding.pane_id='56'
 check(not stale.engine.retain_relay_result('spawn.result',runtime.json.encode(callback)) and stale.p.equal(retained_before,stale.image()),'conflicting sole outcome evidence remains in its carrier rather than overwriting the retained bytes')
 check(not stale.engine.relay_releasable(relay),'unreconciled native evidence keeps its lane and authority obligation held')
 local delivery={peer='orchplus',recipient='spawn',incarnation='relay-incarnation',id='applied-repeat',route='spawn.request',binding='endpoint:lane:spawn.result:boot',body=callback_bytes,slot=1}
 local attach_writes=completed.effects.writes
 check(completed.engine.retain_relay_result('spawn.result',callback_bytes,delivery) and completed.effects.writes==attach_writes+1 and completed.p.equal(completed.saved['dispatch-v1'].requests['session/'..q.request_id].native_result.delivery,delivery),'already applied result without a receipt attaches the new exact delivery fence in one save')
 check(not completed.engine.relay_releasable(relay),'even an applied native result holds its shared lane until exact transport ACK settlement')
 check(completed.engine.settle_result_deliveries({delivery}) and completed.engine.relay_releasable(relay),'private positive ACK settlement releases the otherwise settled shared lane')
 check(stale.engine.settle_result_deliveries({delivery}) and stale.p.equal(retained_before,stale.image()) and not stale.engine.relay_releasable(relay),'ACK of unapplied retained bytes never clears uncertainty or permits lane release')
 local next_read=completed.req('catalog','after-result-repeat');next_read.consumed=runtime.json.array();table.insert(next_read.consumed,q.request_serial)
 check(completed.d.request(next_read,completed.binding,1,function()end).status=='catalog','exact applied repeats do not block subsequent session consumption and authorization')
 check(completed.saved['dispatch-v1'].requests['session/'..q.request_id]==nil and completed.saved['dispatch-v1'].workers['session/'..q.request_id].native_result==nil,'ordinary request reclamation removes private result proof rather than creating a current-worker outcome history')
 local expired=fixture();local pending_request=expired.launch('expired-relay')
 expired.engine.stage(pending_request,expired.binding,1,12,runtime.json.encode(pending_request),relay)
 local original=expired.engine.execution(pending_request,12,relay)
 expired.effects.now=original.deadline+1;local expired_before=expired.image()
 check(expired.engine.stage(pending_request,expired.binding,1,12,runtime.json.encode(pending_request),relay).error.code=='binding_mismatch' and expired.p.equal(expired_before,expired.image()),'expired pending consent cannot be renewed by redelivering the same immutable request')
 check(expired.engine.execution(pending_request,12,relay)==nil,'expired authorization is not an executable relay projection')
end
sections.native_delivery=function()
 local absent=fixture(nil,false,true);local absent_before=absent.image()
 check(#absent.engine.result_deliveries()==0 and absent.p.equal(absent_before,absent.image()) and not absent.effects.writes,'pending delivery inspection never initializes absent authority')
 for _,kind in ipairs({'launch','stop','wake'}) do
  local f,r,result,operation,act
  if kind=='stop' then
   f,r=retirement_fixture();result={status='stopped',pane_binding=copy(pane),observation='absent'}
  elseif kind=='wake' then
   f=launched_fixture(true);r=queue_wake(f,ack_request(f,2),'delivery-wake');result={status='submitted'}
  else
   f=fixture();r=f.launch('delivery-launch');result={status='submitted',pane_binding=copy(pane)}
  end
  operation=if kind=='wake' then 'wakeresult' else 'result'
  act='spawn.'..operation
  f.d.request(r,f.binding,1,function()end)
  f.d.claim(r,'delivery-executor',if kind=='wake' then 'wakeclaim' else 'claim')
  f.d.claim(r,'delivery-executor',if kind=='wake' then 'wakebegin' else 'begin')
  local projection=assert(f.raw.execution(r,77))
  local callback={request_json=runtime.json.encode(r),executor_id='delivery-executor',orch_claim=copy(projection.orch_claim),proof=f.proof(r,projection.orch_claim,projection.claim),spawn_claim=copy(projection.claim),result=copy(result)}
  local bytes=runtime.json.encode(callback)
  local message={peer='orchplus',recipient='spawn',incarnation='delivery-incarnation',id='delivery-'..kind,route='spawn.request',binding='endpoint:lane:'..act..':boot',body=bytes,slot=24}
  local function apply(message)
   if kind=='wake' then return f.engine.wake_claim(r,callback.executor_id,operation,result,callback.orch_claim,callback.proof,callback.spawn_claim,nil,message) end
   return (if kind=='stop' then f.engine.stop_claim else f.engine.claim)(r,callback.executor_id,operation,result,callback.proof,callback.spawn_claim,nil,message)
  end
  local before=f.image();local malformed=copy(message);malformed.extra=true
  check(apply(malformed).error.code=='invalid_schema' and f.p.equal(before,f.image()),kind..' rejects open receipt schema without outcome mutation')
  local writes=f.effects.writes
  local outcome=apply(message)
  local key='session/'..r.request_id
  check(outcome.status==(if kind=='launch' then 'awaiting_acceptance' elseif kind=='stop' then 'stopped' else 'submitted'),'native delivery applies exact '..kind..' outcome')
  check(f.effects.writes==writes+1 and f.p.equal(f.saved['dispatch-v1'].requests[key].native_result.delivery,message),kind..' outcome and full receipt fence commit atomically')
  writes=f.effects.writes;before=f.image()
  check(f.engine.retain_relay_result(act,bytes,message) and f.effects.writes==writes and f.p.equal(before,f.image()),kind..' exact retained duplicate performs no write')
  local conflict=copy(message);conflict.id..='-other'
  check(not f.engine.retain_relay_result(act,bytes,conflict) and f.effects.writes==writes and f.p.equal(before,f.image()),kind..' changed receipt cannot replace pending evidence')
  local changed=copy(callback);changed.result={status='uncertain',message='different outcome'}
  conflict=copy(message);conflict.body=runtime.json.encode(changed)
  check(not f.engine.retain_relay_result(act,conflict.body,conflict) and f.effects.writes==writes and f.p.equal(before,f.image()),kind..' conflicting outcome remains unacknowledged without writes')
  local reboot=fixture(f.image())
  local pending=reboot.engine.result_deliveries()
  check(#pending==1 and reboot.p.equal(pending[1],message),kind..' commit-before-ACK reload preserves exact full receipt')
  local query=reboot.req('status','delivery-status-'..kind,{target_request_id=r.request_id})
  check(reboot.d.request(query,reboot.binding,1,function()end).payload.outcome.status==outcome.status,kind..' status overtakes transport ACK without losing outcome')
  local consume=reboot.req('catalog','delivery-consume-'..kind);table.insert(consume.consumed,r.request_serial)
  reboot.raw.stage(consume,reboot.binding,1,77)
  local consumption_challenge=reboot.raw.execution(consume,77)
  before=reboot.image()
  check(reboot.raw.authorize(consume,consumption_challenge.nonce,77,function()end,{executor=consume.origin_binding.window_epoch,epoch=1,grant_id='consume-'..kind},'fixture-window').error.code=='stale_revision' and reboot.p.equal(before,reboot.image()) and reboot.saved['dispatch-v1'].requests[key]~=nil,kind..' status cannot authorize consumption or pruning before ACK')
  conflict=copy(message);conflict.slot=23
  check(not reboot.engine.settle_result_deliveries({conflict}) and reboot.p.equal(before,reboot.image()),kind..' private settlement requires the exact retained receipt')
  reboot.effects.fail_write=true
  check(not reboot.engine.settle_result_deliveries({message}) and reboot.p.equal(before,reboot.image()),kind..' failed settlement save preserves durable fence')
  local acknowledged=fixture(reboot.image())
  -- The private host adapter supplies this batch only after positive actual ACK proof.
  acknowledged.d.request(query,acknowledged.binding,1,function()end)
  before=acknowledged.image();writes=acknowledged.effects.writes
  check(acknowledged.engine.settle_result_deliveries({message}) and acknowledged.effects.writes==writes+1,kind..' positive private settlement uses one authority save')
  before['dispatch-v1'].requests[key].native_result.delivery=nil
  before['dispatch-v1'].revision=acknowledged.saved['dispatch-v1'].revision
  check(acknowledged.p.equal(before,acknowledged.image()) and #acknowledged.engine.result_deliveries()==0,kind..' settlement only clears receipt fence in existing request state')
  local recovered=fixture(acknowledged.image())
  check(recovered.d.request(query,recovered.binding,1,function()end).payload.outcome.status==outcome.status,kind..' ACK-before-final-publication reload recovers outcome through status')
  consume=recovered.req('catalog','delivery-final-consume-'..kind);table.insert(consume.consumed,r.request_serial)
  check(recovered.d.request(consume,recovered.binding,1,function()end).status=='catalog' and recovered.saved['dispatch-v1'].requests[key]==nil,kind..' ordinary consumed-request GC removes native result proof')
  for _,worker in pairs(recovered.saved['dispatch-v1'].workers) do
   check(worker.native_result==nil and worker.relay_result==nil and worker.delivery==nil and worker.receipts==nil,kind..' GC does not expand worker receipts or retain callback history')
  end
 end
end
sections.allocation=function()
 local f=fixture(nil,true)
 f.transport.hold_provision=true
 local r=f.req('mailbox_provision','allocation-provision',{logical_session_id='session',worker_id='allocation-worker',worker_generation=1,launch_request_id='allocation-launch',work_id='allocation-work',enrolment_token=string.rep('a',16),record_id='worker',record_revision=0,capability='report-files-v1'})
 local completed
 local issued=f.d.request(r,f.binding,1,function(body)completed=body end)
 check(issued.status=='pending' and f.transport.provision_callback~=nil,'real provisioning persists its generation before the helper outcome')
 local target={logical_session_id=r.logical_session_id,worker_id=r.worker_id,worker_generation=r.worker_generation,launch_request_id=r.launch_request_id,work_id=r.work_id,enrolment_sha256=f.c.sha256(r.enrolment_token)}
 local query=f.req('mailbox_allocation','allocation-observe',{target=copy(target)})
 local before=f.image();local grants=f.effects.grants;local calls=#f.transport.modes
 local waiting=f.raw.stage(query,f.binding,1,77)
 check(waiting.status=='uncertain' and waiting.category=='unknown_effect' and waiting.error.code=='allocation_pending' and waiting.payload==nil,'an actual pending helper remains unknown and never reports absent allocation')
 check(f.p.equal(before,f.image()) and f.effects.grants==grants and #f.transport.modes==calls,'allocation observation issues no grant, helper, preparation or journal write')
 f.transport.provision_callback({status=0,timed_out=false,stdout='binding_mismatch\n',stderr=''})
 check(completed and completed.status=='rejected','the actual helper rejection settles the original outcome')
 local refused=copy(f.saved['dispatch-v1'].requests['session/'..r.request_id].body)
 local found=f.raw.stage(query,f.binding,1,77)
 check(found.status=='allocation' and found.payload.allocation.state=='retained' and f.p.equal(found.payload.target,target) and f.p.encode(found)~=nil,'full exact target recovers its retained allocation without inventing a successful original outcome')
 local handle=found.payload.allocation.provision.handle
 check(f.p.equal(f.saved['dispatch-v1'].requests['session/'..r.request_id].body,refused) and next(f.saved['dispatch-v1'].workers)==nil and f.effects.reserves==0,'allocation evidence does not rewrite rejection, enroll a worker or launch a conversation')
 local consume=f.req('catalog','allocation-consume-original')
 table.insert(consume.consumed,r.request_serial)
 check(f.d.request(consume,f.binding,1,function()end).status=='catalog' and f.saved['dispatch-v1'].requests['session/'..r.request_id]==nil,'normal consumed-action handling removes the old framed outcome')
 before=f.image();grants=f.effects.grants;calls=#f.transport.modes
 local legacy=f.raw.stage(query,f.binding,1,77)
 check(legacy.status=='allocation' and legacy.payload.allocation.provision.handle==handle and legacy.payload.allocation.state=='retained','consumed legacy action recovers from its settled provision journal without guessed old request IDs or outcomes')
 check(f.p.equal(before,f.image()) and f.effects.grants==grants and #f.transport.modes==calls,'legacy allocation lookup is also read-only')
 for _,field in ipairs({'worker_id','worker_generation','launch_request_id','work_id','enrolment_sha256'}) do
  local changed=copy(query);changed.request_id='allocation-wrong-'..field
  changed.target[field]=if field=='enrolment_sha256' then string.rep('0',64) elseif type(changed.target[field])=='number' then changed.target[field]+1 else changed.target[field]..'-wrong'
  local result=f.raw.stage(changed,f.binding,1,77)
  check(result.status=='uncertain' and result.payload==nil,'changed selector is unknown, never absent: '..field)
 end
 local foreign=copy(query);foreign.request_id='allocation-foreign'
 foreign.logical_session_id='foreign';foreign.target.logical_session_id='foreign';foreign.origin_binding.logical_session_id='foreign'
 check(f.raw.stage(foreign,f.binding,1,77).status=='rejected','another logical session cannot observe an unadmitted allocation')
 for _,field in ipairs({'authority_namespace','admission_seq','native_session_id','window_host_id'}) do
  local generation=f.saved['dispatch-v1'].mailboxes.generations[handle]
  local original=copy(generation.writes.provision.request)
  if field=='native_session_id' or field=='window_host_id' then generation.writes.provision.request.origin_binding[field]='999'
  else generation.writes.provision.request[field]=if field=='admission_seq' then 2 else 'foreign-authority' end
  local result=f.raw.stage(query,f.binding,1,77)
  check(result.status=='uncertain' and result.payload==nil,'retained proof must match original authority/admission/native facts: '..field)
  generation.writes.provision.request=original
 end
 f.transport.allow_retire=true
 local retirement=f.req('mailbox_retire','allocation-retire',{logical_session_id=r.logical_session_id,worker_id=r.worker_id,worker_generation=r.worker_generation,launch_request_id=r.launch_request_id,work_id=r.work_id,enrolment_token=r.enrolment_token,handle=handle,expected_generation=r.worker_generation,mode='retire',settlement_revision=1,report_floor=0,reply_floor=0,report_chain_sha256=f.c.sha256('report-files-v1\n'..handle..'\n'),grant_id='allocation-retirement'})
 local retired
 f.d.request(retirement,f.binding,1,function(body)retired=body end)
 check(retired and retired.status=='retired','recovered exact allocation uses the existing guarded retirement path')
 before=f.image();calls=#f.transport.modes
 local released=f.raw.stage(query,f.binding,1,77)
 check(released.status=='allocation' and released.payload.allocation.state=='none' and f.p.encode(released)~=nil,'none requires exact completed retirement, not a missing handle or rejected launch')
 check(f.p.equal(before,f.image()) and #f.transport.modes==calls,'completed-retirement observation performs no extra cleanup')
 local ack=f.req('catalog','allocation-consume-retirement');table.insert(ack.consumed,retirement.request_serial)
 check(f.d.request(ack,f.binding,1,function()end).status=='catalog','normal ACK reclaims settled retired metadata')
 check(f.raw.stage(query,f.binding,1,77).status=='uncertain','after all specific proof is consumed, absence alone does not fabricate allocation-none')
 local unallocated=fixture(nil,true)
 unallocated.snapshot.records[1].mailbox.verified=false
 local rejected=copy(r);rejected.request_id='allocation-before-prepare';rejected.action_id='action-before-prepare'
 local rejection=unallocated.d.request(rejected,unallocated.binding,1,function()end)
 check(rejection.status=='rejected' and #unallocated.transport.modes==0,'counterfactual refuses before any generation/helper allocation')
 local proof=copy(query);proof.request_id='allocation-no-reservation'
 local absent=unallocated.raw.stage(proof,unallocated.binding,1,77)
 check(absent.status=='allocation' and absent.payload.allocation.state=='none','a retained exact preallocation rejection proves no reservation')
 local missing=fixture(nil,true)
 check(missing.raw.stage(proof,missing.binding,1,77).status=='uncertain','no matching request or generation is unknown, never a fake empty allocation')
end
-- Explicit forget through the real engine: read-only preview, boot-bound latest-only challenge, quiescence recheck at commit.
sections.forget=function()
 local f=launched_fixture(true)
 local root=f.saved['dispatch-v1']
 root.mailboxes.generations.mine={binding={logical_session_id='session'}}
 local roster=copy(f.snapshot.records)
 local function request(op,attempt,extra)
  local o=f.origin
  local r={schema=1,origin='orchplus',op=op,request_id='forget-'..op..'-'..attempt,attempt_id=attempt,authority_namespace='orch-authority',spawn_namespace='spawn-authority',
   logical_session_id='session',admission_seq=1,controller_pane='44',
   owner={owner_id=o.owner_id,owner_generation=o.owner_generation,host_pane_id=o.host_pane_id,alias_nonce=o.alias_nonce,window_key=o.window_key,native_session_id=o.native_session_id,window_host_id=o.window_host_id}}
  for k,v in pairs(extra or {}) do r[k]=v end
  assert(f.c.decode_forget_request(runtime.json.encode(r)),'fixture request must satisfy the canonical forget schema: '..op)
  return r
 end
 local live=function(b)return 'present' end
 local gone=function(b)return 'absent' end
 local function ask(op,attempt,extra,observe)
  local body=f.d.forget(request(op,attempt,extra),f.binding,1,observe or gone)
  assert(f.c.encode_forget_response(body),'response must satisfy the canonical schema: '..runtime.json.encode(body):sub(1,200))
  return body
 end
 local cap=ask('discard_capability','attempt-1')
 check(cap.status=='capable' and ask('discard_capability','attempt-1').payload.challenge==cap.payload.challenge,'the same attempt is idempotent and returns the same challenge')
 local older=cap.payload.challenge
 cap=ask('discard_capability','attempt-2')
 check(cap.payload.challenge~=older and ask('discard_preview','attempt-1',{challenge=older}).error.code=='stale_challenge','a replacement attempt invalidates the older challenge')
 local wrong_owner=request('discard_capability','attempt-2');wrong_owner.owner.alias_nonce='someone-else'
 check(f.d.forget(wrong_owner,f.binding,1).error.code=='owner_mismatch','a different retained owner identity is refused')
 local wrong_ns=request('discard_capability','attempt-2');wrong_ns.spawn_namespace='other-spawn'
 check(f.d.forget(wrong_ns,f.binding,1).error.code=='changed','another SPAWN namespace is refused')
 local before=f.image();local writes=f.effects.writes
 local blocked=ask('discard_preview','attempt-2',{challenge=cap.payload.challenge},live)
 check(blocked.status=='blocked' and blocked.payload.blockers[1].kind=='pane' and blocked.payload.blockers[1].pane=='55'
  and f.p.equal(before,f.image()) and f.effects.writes==writes,'a blocked preview names the pane and writes nothing (no loader recovery, no revocation, no ACK)')
 local clean=ask('discard_preview','attempt-2',{challenge=cap.payload.challenge})
 check(clean.status=='clean' and f.p.equal(before,f.image()) and f.effects.writes==writes,'a clean preview is also read-only')
 local bound={challenge=cap.payload.challenge,dispatch_revision=clean.payload.dispatch_revision,spawn_boot=clean.spawn_boot}
 local stale=copy(bound);stale.dispatch_revision+=1
 check(ask('discard_session','attempt-2',stale).error.code=='changed','a changed dispatch revision requires another preview')
 local reboot=copy(bound);reboot.spawn_boot='old-boot'
 check(ask('discard_session','attempt-2',reboot).error.code=='changed','a preview from another SPAWN boot is refused')
 local raced=ask('discard_session','attempt-2',bound,live)
 check(raced.error and raced.error.code=='blocked' and f.p.equal(before,f.image()),'execution that reappears before commit blocks it and changes nothing')
 local done=ask('discard_session','attempt-2',bound)
 root=f.saved['dispatch-v1']
 local left=0
 for _,e in pairs(root.requests) do if e.request.logical_session_id=='session' then left+=1 end end
 for _,w in pairs(root.workers) do if w.logical_session_id=='session' then left+=1 end end
 for _,g in pairs(root.mailboxes.generations) do if g.binding.logical_session_id=='session' then left+=1 end end
 check(done.status=='closed' and done.payload.admission_cursor==root.admission_cursor and root.sessions.session==nil and left==0,'dispatch-v1 holds no session, request, worker or mailbox generation of the forgotten session')
 check(f.p.equal(f.snapshot.records,roster) and f.effects.reserves==1,'the agent roster is untouched and no native effect ran')
 -- Lost completion: the graph is gone; an authenticated retry with a fresh capability is idempotent.
 check(ask('discard_session','attempt-2',bound).error.code=='stale_challenge','a consumed challenge is not reusable')
 local again=ask('discard_capability','attempt-3')
 check(again.status=='capable','an absent session whose admission existed can be re-authenticated')
 local retry=ask('discard_session','attempt-3',{challenge=again.payload.challenge,dispatch_revision=0,spawn_boot=again.spawn_boot})
 check(retry.status=='closed','an authenticated retry after SPAWN already deleted the graph returns idempotent completion')
 local never=request('discard_capability','attempt-4');never.admission_seq=99
 check(f.d.forget(never,f.binding,1).error.code=='not_found','an admission SPAWN never recorded is not completed')
end
-- The actual relay carries the dedicated forget operations on their own protocol, bound to the bound source's identity.
sections.forget_relay=function()
 local f=launched_fixture(true)
 -- The fixture admits through native session 1 but its origin names session 3; the relay passes the bound source's session.
 f.saved['dispatch-v1'].sessions.session.host_session=3
 local inbox,sent,sequence={},{},0
 local endpoint={}
 function endpoint.send(frame) table.insert(sent,copy(frame));return {id=frame.id} end
 function endpoint.receive(limit) local out={};for index=1,math.min(limit,#inbox)do table.insert(out,inbox[index])end;return out end
 function endpoint.ack(message) for index,item in ipairs(inbox)do if item.id==message.id then table.remove(inbox,index);break end end;return true end
 function endpoint.settle()return 0 end
 function endpoint.acknowledged()return false end
 f.load('channel/channel').open=function()return endpoint end
 f.runtime.plugin={data='/fixture/spawn'}
 f.runtime.pane={list=function()return {{pane=12,program='orchplus.orchestrator'}}end}
 f.runtime.timer=function()return {cancel=function()end}end
 f.authority.binding=function(session) return f.binding end
 local relay=f.load('dispatch_relay').install()
 local function enqueue(act,bytes)
  sequence+=1
  table.insert(inbox,{peer='orchplus',route='spawn.request',incarnation='forget-orch',id='m-'..tostring(sequence),binding='forget:lane:'..act..(if act=='bind' then '' else ':'..relay.boot),body=bytes})
 end
 enqueue('bind',runtime.json.encode({schema=1,relay_endpoint='forget',relay_boot='forget-orch',lane_id='lane',host_pane_id='12',source_nonce=f.origin.alias_nonce,
  origin=copy(f.origin),desktop_proof='delegated_native_window',host_program='orchplus.orchestrator'}))
 relay.poll()
 local o=f.origin
 local function request(op,extra)
  local r={schema=1,origin='orchplus',op=op,request_id='relay-'..op,attempt_id='relay-attempt',authority_namespace='orch-authority',spawn_namespace='spawn-authority',
   logical_session_id='session',admission_seq=1,controller_pane='12',
   owner={owner_id=o.owner_id,owner_generation=o.owner_generation,host_pane_id=o.host_pane_id,alias_nonce=o.alias_nonce,window_key=o.window_key,native_session_id=o.native_session_id,window_host_id=o.window_host_id}}
  for k,v in pairs(extra or {}) do r[k]=v end
  return r
 end
 local function ask(op,extra)
  local r=request(op,extra);local before=#sent
  enqueue(op,runtime.json.encode(r));relay.poll();relay.poll()
  local body
  for index=#sent,before+1,-1 do
   if sent[index].route=='spawn.response' then body=f.c.decode_forget_response(sent[index].body,r);if body then break end end
  end
  return body
 end
 local cap=ask('discard_capability')
 check(cap and cap.status=='capable','the relay answers a capability request on the forget protocol')
 local clean=ask('discard_preview',{challenge=cap.payload.challenge})
 check(clean and clean.status=='clean','the relay answers a preview with the same read-only engine')
 local before=f.image()
 local forged=request('discard_capability');forged.owner.alias_nonce='other-owner'
 enqueue('discard_capability',runtime.json.encode(forged));relay.poll()
 check(f.p.equal(before,f.image()),'a request whose owner is not the bound source identity changes nothing and is not answered')
 local closed=ask('discard_session',{challenge=cap.payload.challenge,dispatch_revision=clean.payload.dispatch_revision,spawn_boot=clean.spawn_boot})
 check(closed and closed.status=='closed' and f.saved['dispatch-v1'].sessions.session==nil,'the relay carries the discard and SPAWN persists exactly one deletion')
end
if section then
 assert(sections[section],'unknown dispatch section '..section)
 sections[section]()
else
 for _,name in ipairs({'launch','allocation','migration','publication','ack_lifecycle','wake_binding','authorization','expired_authorization','recovery','duplex','retirement_binding','retirement_settlement','retirement_producer','unused_retirement','failed_startup','coordinator_launch','wake_capacity','wake_retention','attachment','attachment_recovery','authority_rotation','host_local','rollover_accept','adopt','enrol','presentation','accept_recovery','native_rollback','owner_retention','bootstrap','administration','consumed_status','scope_progress','relay_fence','native_delivery'})do sections[name]()end
end
return 'PASS dispatch'..(if section then '/'..section else '')..' '..tostring(checks)
