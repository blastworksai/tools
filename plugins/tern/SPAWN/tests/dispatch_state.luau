-- Pure current-state regressions against the shipping state/codec modules.
local directory=...
assert(type(directory)=='string','pass package directory')
local runtime,environment=tern,getfenv()
local modules={}
local function load(name)
 name=name:gsub('^%./','')
 if modules[name] then return modules[name] end
 local chunk=assert(loadstring(runtime.fs.read(directory..'/'..name..'.luau'),name))
 setfenv(chunk,setmetatable({tern=runtime,require=load},{__index=environment}))
 modules[name]=chunk();return modules[name]
end
local State,P,Codec=load('dispatch_state'),load('bridge_protocol'),load('wire/codec')
local checks=0
local function check(value,message) assert(value,message);checks+=1 end
local function count(map) local n=0;for _ in pairs(map) do n+=1 end;return n end
local function array(...) local out=tern.json.array();for _,value in ipairs({...}) do table.insert(out,value) end;return out end
local binding={authority_id='host-authority',managed_authority_id='host-authority'}
local function origin(logical)
 return {logical_session_id=logical,owner_id='owner',owner_generation=1,host_pane_id='12',alias_nonce='alias',window_key='',window_epoch='epoch',native_session_id='3',window_host_id='7'}
end
local function fresh()
 return {version=2,revision=1,namespace='spawn-authority',authority_namespace='orch-authority',admission_cursor=0,sessions={},workers={},requests={},mailboxes={version=1,generations={}},gates={},controls={},next_id=1}
end
local function control(root,op,logical,admission,revision)
 local s=root.sessions[logical]
 local c=s and s.control
 local r={schema=2,origin='orchplus',op=op,request_id=op..'-'..admission,action_id='control-'..admission,authority_namespace='orch-authority',logical_session_id=logical,admission_seq=admission,authority_revision=revision or 1,control_origin={kind='active',binding=origin(logical),controller_pane='44'},compatibility={schema=1,kind='current',protocol=2,authority_namespace='orch-authority',spawn_namespace=root.namespace},generation_floor=c and c.generation_floor or 0,next_request_serial=c and c.next_request_serial or 1,settled_before=c and c.request_floor or 1,consumed=array()}
 if op=='close_session' then r.close_id='close-'..admission end
 if op=='reconcile_session' then r.page_limit=Codec.DISPATCH.outstanding end
 return r
end
local function peer(root,r,released)
 local c={phase=if r.op=='close_session' then 'closing' else 'open',generation_floor=r.generation_floor,request_floor=r.settled_before,next_request_serial=r.next_request_serial,last_authority_revision=r.authority_revision,binding=if released then nil else P.clone(r.control_origin.binding),close_id=r.close_id}
 return {protocol=2,phase='stable',authority_namespace=r.authority_namespace,authority_revision=r.authority_revision,spawn_namespace=root.namespace,session={admission_seq=r.admission_seq,control=c}}
end
local function apply(root,r,released)
 if released then
  r=P.clone(r)
  r.control_origin.kind='closing';r.control_origin.close_id=r.close_id
  r.generation_floor=math.max(r.generation_floor,r.control_origin.binding.owner_generation)
 end
 check(Codec.decode_dispatch_request(tern.json.encode(r))~=nil,'fixture control must satisfy canonical schema')
 return State.control(root,r,binding,1,peer(root,r,released))
end
local function admit(root,logical,admission)
 local r=control(root,'admit_session',logical,admission)
 local body,why=apply(root,r)
 check(body and body.status=='admitted','explicit paired admission: '..tostring(why))
 return r
end
local function retain(root,logical,admission,serial,phase)
 local r={schema=2,origin='orchplus',op='catalog',request_id='request-'..serial,action_id='action-'..serial,authority_namespace='orch-authority',logical_session_id=logical,admission_seq=admission,request_serial=serial,next_request_serial=serial+1,settled_before=1,consumed=array(),origin_binding=origin(logical),controller_pane='44',controller_generation=1}
 P.observe(root)
 local e={request=r,request_json=tern.json.encode(r),body=P.body(r,phase or 'rejected',nil,if phase then nil else {code='target_unavailable'})}
 root.requests[logical..'/'..r.request_id]=e
 return e
end
local function page(root,r)
 P.observe(root)
 local body=P.body(r,'reconciled',{admission_cursor=root.admission_cursor,compatibility=r.compatibility,control=P.clone(root.sessions[r.logical_session_id].control)},nil,'current_admission')
 local result,why=State.page(root,r,body)
 check(result~=nil,'bounded page encodes: '..tostring(why))
 local encoded,diagnostic=P.encode(result)
 check(encoded~=nil and #encoded<=8192,'complete serialized page fits bridge: '..tostring(diagnostic))
 check(Codec.decode_dispatch_response(encoded,r)~=nil,'page roundtrips canonical correlation')
 return result.payload.outstanding
end

-- Authority maintenance and dispatch use the same pure whole-store validator.
do
 local root=fresh();admit(root,'session',1)
 retain(root,'session',1,1)
 root.sessions.session.control.next_request_serial=2
 local records_json=tern.json.encode(array())
 local request={schema=1,origin='spawn-migration',op='import_config',request_id='import',source_client='client',target_host='host',source_revision=1,source_sha256=Codec.sha256(records_json),records_json=records_json}
 root.gates.import={request=request,records=array(),binding={authority_id='authority',session_key='session',host_key='host'},boot='boot'}
 local before=Codec.dispatch_source_bytes(root)
 check(State.validate_registry(root)==root,'current issued request and import gate validate through the pure state seam')
 check(Codec.dispatch_source_bytes(root)==before,'validation never rewrites the source or clears a gate')
 local invalid=P.clone(root);invalid.gates.import.request.source_sha256=string.rep('0',64)
 local rejected_before=Codec.dispatch_source_bytes(invalid)
 check(State.validate_registry(invalid)==nil,'registry validation retains the exact import snapshot hash check')
 check(Codec.dispatch_source_bytes(invalid)==rejected_before,'refused validation preserves all source evidence')
 invalid=P.clone(root);invalid.requests['session/request-1'].stop_backend='local-terminal'
 check(State.validate_registry(invalid)==nil,'non-stop requests cannot carry a stop backend projection')
 invalid=P.clone(root);invalid.requests['session/request-1'].stop_request_id='stop'
 check(State.validate_registry(invalid)==nil,'only launch-family entries may own an exclusive stop fence')
 invalid=P.clone(root);invalid.mailboxes.extra=true
 check(State.validate_registry(invalid)==nil,'the shared seam still validates the whole mailbox registry')
 local relayed=P.clone(root);relayed.requests['session/request-1'].relay_binding=Codec.sha256('exact relay correlation')
 check(State.validate_registry(relayed)==relayed,'retained relay correlation is a closed optional digest, not worker identity')
 relayed.requests['session/request-1'].relay_consent={nonce='grant',boot='host-boot',bridge=12,deadline=30000,executor_id='window-executor'}
 check(State.validate_registry(relayed)==relayed,'consumed relay consent retains the exact native source and finite deadline')
 local foreign=P.clone(relayed);foreign.requests['session/request-1'].relay_consent.bridge=77
 check(State.validate_registry(foreign)==nil,'consumed relay consent cannot substitute an invented or historical bridge pane')
 foreign=P.clone(relayed);foreign.requests['session/request-1'].relay_binding=nil
 check(State.validate_registry(foreign)==nil,'consumed relay consent cannot become an unbound historical transport fact')
 relayed.requests['session/request-1'].relay_binding='invented-pane-or-endpoint'
 check(State.validate_registry(relayed)==nil,'malformed relay correlation cannot enter persisted authority state')
 local release_root=P.clone(root);local release_entry=release_root.requests['session/request-1']
 local relay=Codec.sha256('release-lane');release_entry.relay_binding=relay
 check(State.relay_releasable(release_root,relay),'settled rejection permits transport lane release without deleting authority')
 for _,phase in ipairs({'pending','resolved','claimed','launching','uncertain'}) do
  release_entry.body.status=phase
  check(not State.relay_releasable(release_root,relay),'unsettled '..phase..' keeps its exact relay lane held')
 end
 release_entry.body.status='rejected';release_entry.body.error={code='claim_mismatch'}
 check(not State.relay_releasable(release_root,relay),'conflicting native witness cannot be treated as an inert rejection')
 check(State.relay_releasable(release_root,Codec.sha256('other-lane')),'an unrelated relay lane does not inherit another lane obligation')
end

-- A finite sweep captures SPAWN's ceiling, not a restored ORCH next-issued value.
do
 local root=fresh();admit(root,'session',1)
 for _,serial in ipairs({1,3,5,7,9}) do retain(root,'session',1,serial,'pending') end
 root.sessions.session.control.next_request_serial=10
 root.sessions.session.control.last_authority_revision=10
 local r=control(root,'reconcile_session','session',1);r.page_limit=2;r.next_request_serial=2
 local before=P.clone(root)
 local observed,why,changed=apply(root,r)
 check(observed and not changed and P.equal(before,root),'restored peer observes a finite page without regressing ACK, counters or revision: '..tostring(why))
 local first=observed.payload.outstanding
 check(first.through_serial==9 and first.entries[1].request_serial==1 and first.entries[2].request_serial==3 and not first.complete,'ceiling includes peer work above restored next-issued')
 retain(root,'session',1,2,'pending') -- Arrives below this sweep's cursor.
 local seen={};local current=first;local high=10;local pages=1
 while not current.complete do
  retain(root,'session',1,high,'pending');high+=1
  r.outstanding_cursor={after_serial=current.next_after_serial,through_serial=current.through_serial}
  current=page(root,r);pages+=1
  for _,entry in ipairs(current.entries) do seen[entry.request_serial]=true;check(entry.request_serial<=9,'churn cannot extend captured ceiling') end
  check(pages<=3,'finite sweep cannot starve under continuous higher arrivals')
 end
 check(seen[5] and seen[7] and seen[9] and not seen[2],'first sweep exhausts original high holes')
 r.outstanding_cursor=nil
 local second=page(root,r)
 check(second.entries[1].request_serial==1 and second.entries[2].request_serial==2,'next sweep reaches late lower serial despite long-running floor')
end

-- Lost ACKs retain outcomes; explicit consumed holes reclaim only settled work.
do
 local root=fresh();admit(root,'session',1)
 retain(root,'session',1,1,'pending');retain(root,'session',1,2);retain(root,'session',1,3)
 local ack=control(root,'reconcile_session','session',1);ack.next_request_serial=4
 local before=P.clone(root.requests)
 check(State.acknowledge(root,ack) and P.equal(before,root.requests),'missing ACK does not infer consumption from higher issuance')
 ack.consumed=array(3)
 check(State.acknowledge(root,ack) and root.requests['session/request-3']==nil and root.requests['session/request-2']~=nil and root.requests['session/request-1']~=nil,'completed high hole reclaimed above running low floor')
 check(State.acknowledge(root,ack) and count(root.requests)==2,'lost ACK replay needs no completed-ID set')
 ack.consumed=array(1,2);before=P.clone(root)
 local ok,why=State.acknowledge(root,ack)
 check(not ok and why=='unknown_effect' and P.equal(before,root),'page refusing potentially started work cannot partially reclaim a settled sibling')
 ack.consumed=array();ack.settled_before=3
 ok,why=State.acknowledge(root,ack)
 check(not ok and why=='unknown_effect' and root.requests['session/request-2']~=nil,'floor cannot skip potential effect')
 ack.settled_before=1;ack.next_request_serial=3
 ok,why=State.acknowledge(root,ack)
 check(not ok and why=='stale_revision','reverse ORCH restore cannot lower observed next-issued')
 root.requests['session/request-1'].body.status='uncertain'
 ack.next_request_serial=4;ack.consumed=array(1)
 ok,why=State.acknowledge(root,ack)
 check(not ok and why=='unknown_effect','uncertain claim remains live across later equal revision/ACK')
end

-- Completion count does not become a retained request/fence/owner history.
do
 local root=fresh();admit(root,'session',1)
 for serial=1,4097 do
  retain(root,'session',1,serial)
  local ack=control(root,'reconcile_session','session',1)
  ack.next_request_serial=serial+1;ack.settled_before=serial+1
  check(State.acknowledge(root,ack) and next(root.requests)==nil,'settled lifecycle reclaims request '..serial)
 end
 check(root.request_fences==nil and root.tombstones==nil and root.owners==nil and count(root.sessions)==1,'4097 completions retain no old 4096/2048 identity history')
 check(root.sessions.session.control.request_floor==4098,'request floor advances without a completed set')
end

-- Closing is a live fence until owners and every dependency have gone.
do
 local root=fresh();admit(root,'session',1);admit(root,'other',2)
 local close=control(root,'close_session','session',1)
 local body=apply(root,close,false)
 check(body and body.status=='closing' and root.sessions.session.control.phase=='closing','held owner keeps close pending')
 local ordinary=control(root,'reconcile_session','session',1)
 local refused,why=apply(root,ordinary)
 check(not refused and why=='admission_refused','closing fences ordinary admission/reconciliation')
 retain(root,'session',1,1,'uncertain')
 local candidate=P.clone(root)
 body,why=apply(candidate,close,true)
 check(body and body.status=='closing' and body.category=='current_admission' and candidate.sessions.session.control.binding==nil and candidate.sessions.session.closing_origin.close_id==close.close_id,'potential effect keeps the released-owner closing fence live')
 local false_ack=P.clone(close);false_ack.next_request_serial=2;false_ack.consumed=array(1)
 candidate=P.clone(root);local before=P.clone(candidate)
 body,why=apply(candidate,false_ack,true)
 check(not body and why=='unknown_effect' and P.equal(before,candidate),'false consumed ACK of uncertain work refuses closure without mutation')
 root.requests={}
 root.workers.worker={logical_session_id='session'}
 candidate=P.clone(root);body,why=apply(candidate,close,true)
 check(body and body.status=='closing' and body.category=='current_admission' and candidate.sessions.session~=nil,'current worker keeps closure pending')
 root.workers={};root.mailboxes.generations.box={binding={logical_session_id='session'}}
 candidate=P.clone(root);body,why=apply(candidate,close,true)
 check(body and body.status=='closing' and body.category=='current_admission' and candidate.sessions.session~=nil,'live mailbox keeps closure pending')
 root.mailboxes.generations={}
 local other=P.clone(root.sessions.other)
 body=apply(root,close,true)
 check(body and body.status=='closed' and root.sessions.session==nil and P.equal(other,root.sessions.other),'closure removes only its current session')
 local stale=control(root,'admit_session','session',1)
 body,why=apply(root,stale)
 check(not body and why=='admission_refused','absent old admission cannot resurrect after close')
 for n=3,68 do
  local logical='session-'..n;admit(root,logical,n)
  local finish=control(root,'close_session',logical,n)
  check(apply(root,finish,true).status=='closed','completed session does not consume lifetime capacity')
 end
 check(count(root.sessions)==1 and root.sessions.other~=nil and root.admission_cursor==68,'more than 64 lifecycles retain only another active session')
 local unknown=control(root,'owner_status','absent',1)
 unknown.control_origin=nil;unknown.compatibility=nil;unknown.origin_binding=origin('absent');unknown.controller_pane='44';unknown.controller_generation=1
 local observed=State.observation(root,unknown)
 check(observed.category=='admission_absent','missing admission is observation, not effect success or never-executed proof')
end
-- Explicit forget (evidence model spawn-work-v1): SPAWN's own execution obligations decide; panes and processes never do.
do
 local function build()
  local root=fresh();admit(root,'session',1);admit(root,'other',2)
  root.requests['session/launch']={request={op='launch',logical_session_id='session',request_id='launch',record_id='claude-a',origin_binding=origin('session')},body={status='accepted'},observer_id='managed-aaa',attempt_id='attempt-1'}
  root.requests['other/launch']={request={op='launch',logical_session_id='other',request_id='launch',record_id='omp-b',origin_binding=origin('other')},body={status='accepted'},observer_id='managed-bbb',attempt_id='attempt-2'}
  root.workers['session/w']={logical_session_id='session',record_id='claude-a',origin_binding=origin('session'),phase='accepted'}
  root.mailboxes.generations.mine={binding={logical_session_id='session'},record_id='claude-a',status='live',writes={}};root.mailboxes.generations.theirs={binding={logical_session_id='other'},record_id='omp-b',status='live',writes={}}
  return root
 end
 local root=build()
 local inv=State.forget_inventory(root,'session',{host='7'})
 check(#inv.blockers==0 and inv.inventory.requests==1 and inv.inventory.workers==1 and inv.inventory.generations==1 and inv.dispatch_revision==root.revision,'settled work gives a clean inventory of exactly this graph')
 check(#inv.participants==1 and inv.participants[1].agent=='claude-a','a retained agent is an informational participant, never a blocker (no pane, command or process is consulted)')
 check(#inv.journal==1 and inv.journal[1].observer_id=='managed-aaa' and inv.journal[1].attempt_id=='attempt-1','the reservation journal names exactly this session\'s managed reservations')
 local function blocked_by(mutate,kind)
  local r=build();mutate(r)
  local i=State.forget_inventory(r,'session',{host='7'})
  return #i.blockers==1 and i.blockers[1].kind==(kind or 'uncertain') and i.blockers[1].agent=='claude-a',i
 end
 check(blocked_by(function(r) r.requests['session/launch'].body.status='claimed' end),'a claimed launch blocks')
 check(blocked_by(function(r) r.requests['session/launch'].body.status='uncertain' end),'an uncertain outcome blocks')
 check(blocked_by(function(r) r.requests['session/launch'].attempt_pending=true end),'a pending reservation write blocks')
 check(blocked_by(function(r) r.requests['session/launch'].operation='op-1' end),'a pending mailbox operation blocks')
 check(blocked_by(function(r) r.requests['session/launch'].authorization={phase='consumed'};r.requests['session/launch'].body.status='resolved' end),'a consumed authorization without a settled result blocks')
 check(blocked_by(function(r) r.requests['session/launch'].stop_request_id='stop';r.requests['session/launch'].body.status='pending' end),'an unfinished stop blocks')
 check(blocked_by(function(r) r.requests['session/launch'].wake={phase='launching'} end),'a launching wake blocks')
 check(blocked_by(function(r) r.workers['session/w'].phase='claimed' end),'a claimed worker obligation blocks')
 check(blocked_by(function(r) r.workers['session/w'].wakes={wake1={wake={phase='claimed'}}} end),'a claimed wake retained on a worker blocks')
 check(blocked_by(function(r) r.mailboxes.generations.mine.active={id='op'} end),'a running mailbox child record blocks')
 check(blocked_by(function(r) r.mailboxes.generations.mine.writes={k={status='uncertain'}} end),'an uncertain mailbox write blocks')
 check(blocked_by(function(r) r.mailboxes.generations.mine.status='intent' end),'an unconfirmed mailbox generation blocks')
 local settled=build()
 settled.requests['session/launch'].authorization={phase='consumed'};settled.requests['session/launch'].claim={executor_id='x'};settled.requests['session/launch'].body.status='accepted'
 settled.mailboxes.generations.mine.writes={k={status='settled'}};settled.mailboxes.generations.mine.status='retired'
 check(#State.forget_inventory(settled,'session',{host='7'}).blockers==0,'a settled launch (its claim and consumed grant retained), a settled write and a retired generation do not block')
 local helper=State.forget_inventory(build(),'session',{host='7',children=function(l) return if l=='session' then 1 else 0 end})
 check(#helper.blockers==1 and helper.blockers[1].kind=='uncertain' and helper.blockers[1].agent=='mailbox helper','an outstanding helper child blocks')
 local conflict=State.forget_inventory(build(),'session',{host='7',conflicts=function(j) return #j end})
 check(#conflict.blockers==1 and conflict.blockers[1].kind=='unobservable','a reservation Authority holds in another shape blocks')
 -- Deterministic and deduplicated.
 local many=build()
 for index=1,12 do many.requests['session/r'..index]={request={op='launch',logical_session_id='session',request_id='r'..index,record_id=string.format('agent-%02d',13-index),origin_binding=origin('session')},body={status='accepted'}} end
 many.requests['session/dup']={request={op='launch',logical_session_id='session',request_id='dup',record_id='claude-a',origin_binding=origin('session')},body={status='accepted'}}
 local m=State.forget_inventory(many,'session',{host='7'})
 check(#m.participants==13 and m.participants[1].agent=='agent-01' and m.participants[13].agent=='claude-a','participants are deduplicated by agent and host and ordered deterministically')
 -- Deletion removes exactly this graph.
 root=build()
 local before_other=P.clone(root.sessions.other);local theirs=P.clone(root.mailboxes.generations.theirs)
 local rest={version=root.version,namespace=root.namespace,authority_namespace=root.authority_namespace,admission_cursor=root.admission_cursor,gates=P.clone(root.gates),next_id=root.next_id}
 State.forget_delete(root,'session')
 check(root.sessions.session==nil and count(root.requests)==1 and root.requests['other/launch']~=nil and count(root.workers)==0,'only the matching session graph is removed')
 check(root.mailboxes.generations.mine==nil and P.equal(root.mailboxes.generations.theirs,theirs) and P.equal(root.sessions.other,before_other),'its mailbox generations go; another session is untouched')
 for key,value in pairs(rest) do check(P.equal(root[key],value),'roster-side fields, counters and the admission watermark are untouched: '..key) end
 local plain=control(build(),'close_session','session',1)
 plain.discard=true
 check(Codec.decode_dispatch_request(tern.json.encode(plain))==nil,'the legacy close_session schema is unchanged: it does not accept a discard field')
 -- Wire: dedicated operations, closed schemas, the work discriminator is required, legacy untouched.
 local owner={owner_id='owner',owner_generation=1,host_pane_id='12',alias_nonce='alias',window_key='',native_session_id='3',window_host_id='7'}
 local request={schema=1,origin='orchplus',op='discard_capability',work='spawn-work-v1',request_id='r1',attempt_id='a1',authority_namespace='orch-authority',spawn_namespace='spawn-authority',logical_session_id='session',admission_seq=1,owner=owner,controller_pane='44'}
 check(Codec.decode_forget_request(tern.json.encode(request))~=nil,'a capability request is a closed, valid object')
 local legacy_intent=P.clone(request);legacy_intent.work=nil
 check(Codec.decode_forget_request(tern.json.encode(legacy_intent))==nil,'a request without spawn-work-v1 is refused: there is no legacy-intent branch')
 legacy_intent.work='spawn-work-v0'
 check(Codec.decode_forget_request(tern.json.encode(legacy_intent))==nil,'another work model is refused')
 local with_epoch=P.clone(request);with_epoch.owner.window_epoch='epoch'
 check(Codec.decode_forget_request(tern.json.encode(with_epoch))==nil,'the owner identity carries no window epoch field')
 local preview=P.clone(request);preview.op='discard_preview'
 check(Codec.decode_forget_request(tern.json.encode(preview))==nil,'a preview must carry the challenge')
 preview.challenge='forget-0000000000000000'
 check(Codec.decode_forget_request(tern.json.encode(preview))~=nil,'a preview with its challenge is valid')
 local discard=P.clone(preview);discard.op='discard_session'
 check(Codec.decode_forget_request(tern.json.encode(discard))==nil,'a discard must bind the observed revision and SPAWN boot')
 discard.dispatch_revision=5;discard.spawn_boot='boot-1'
 check(Codec.decode_forget_request(tern.json.encode(discard))~=nil,'a discard with its binding is valid')
 check(Codec.decode_dispatch_request(tern.json.encode(request))==nil,'legacy decoders refuse the forget operations')
 local function body_of(payload,status) return {schema=1,op='discard_preview',request_id='r1',attempt_id='a1',status=status or 'blocked',work='spawn-work-v1',spawn_namespace='spawn-authority',authority_namespace='orch-authority',logical_session_id='session',admission_seq=1,spawn_boot='boot-1',payload=payload} end
 local body=body_of({dispatch_revision=5,participants=array({agent='claude-a',host='7'}),omitted=0,blockers=array({kind='uncertain',agent='claude-a',host='7'},{kind='unobservable',agent='x',host='9'}),blockers_omitted=0})
 local bytes=Codec.encode_forget_response(body)
 check(bytes~=nil and Codec.decode_forget_response(bytes,preview)~=nil,'a blocked preview response round-trips against its request')
 local other_request=P.clone(preview);other_request.attempt_id='a2'
 check(Codec.decode_forget_response(bytes,other_request)==nil,'a response bound to another attempt is refused')
 local no_work=P.clone(body);no_work.work=nil
 check(Codec.encode_forget_response(no_work)==nil,'a response without spawn-work-v1 is refused')
 local pane_kind=P.clone(body);pane_kind.payload.blockers=array({kind='pane',agent='claude-a',host='7'})
 check(Codec.encode_forget_response(pane_kind)==nil,'pane blocker kinds no longer exist')
 local ready=body_of({dispatch_revision=5,inventory={requests=1,workers=1,generations=1},participants=array(),omitted=3},'clean')
 check(Codec.encode_forget_response(ready)~=nil,'a ready preview carries participants and an exact omitted count')
 local nine=P.clone(ready);nine.payload.participants=array({agent='a1',host='7'},{agent='a2',host='7'},{agent='a3',host='7'},{agent='a4',host='7'},{agent='a5',host='7'},{agent='a6',host='7'},{agent='a7',host='7'},{agent='a8',host='7'},{agent='a9',host='7'})
 check(Codec.encode_forget_response(nine)==nil,'participant rows are bounded')
 local capable=body_of({challenge='forget-0000000000000000',work='spawn-work-v1'},'capable');capable.op='discard_capability'
 check(Codec.encode_forget_response(capable)~=nil,'the capability payload carries the work model')
 capable.payload.work=nil
 check(Codec.encode_forget_response(capable)==nil,'a capability without spawn-work-v1 is refused')
end
-- Enrollment's copied/submitted distinction survives immutable request retirement.
for _,delivery in ipairs({'native_ask','clipboard'}) do
 local root=fresh();admit(root,'session',1)
 local pane={pane_id='55',window_epoch='epoch',window_key='',native_session_id='3',window_host_id='7'}
 local r={op='enrol',request_id='enrol',action_id='enrol-action',logical_session_id='session',origin_binding=origin('session'),controller_pane='44',controller_generation=1,record_id='worker',record_revision=0,work_id='work',mailbox_handle='mailbox',delivery=delivery,enrolment={worker_id='worker',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',assignment_sha256=Codec.sha256(Codec.OPEN_CONVERSATION_ASSIGNMENT)}}
 local entry={request=r,body={status='awaiting_acceptance'},pane_binding=pane,launch={backend=if delivery=='native_ask' then 'native-agent' else 'local-terminal'},binding=binding,observer_id='enrol-observer'}
 State.preserve_worker(root,entry)
 check(State.validate_registry(root)==root,'current worker registry accepts retained enrollment delivery')
 local reloaded=P.clone(root);local observed=State.worker(reloaded,'session','enrol')
 check(observed.request.op=='enrol' and observed.request.delivery==delivery and observed.attempt_id==nil and P.equal(observed.pane_binding,pane),'retirement keeps exact delivery, pane and absence of fresh launch reservation')
 observed.body.status='accepted';State.flush(reloaded)
 check(reloaded.workers['session/enrol'].phase=='accepted' and reloaded.workers['session/enrol'].delivery==delivery,'semantic acceptance preserves enrollment identity on the current worker')
 local malformed=P.clone(root);malformed.workers['session/enrol'].delivery=nil
 check(State.validate_registry(malformed)==nil,'lost delivery facts cannot become an apparently submitted enrollment')
 malformed=P.clone(root);malformed.workers['session/enrol'].attempt_id='fabricated-launch'
 check(State.validate_registry(malformed)==nil,'existing conversation enrollment cannot acquire a fresh launch reservation')
 malformed=P.clone(root);malformed.workers['session/enrol'].backend='ssh-command'
 check(State.validate_registry(malformed)==nil,'same-user enrollment cannot restore a clipboard route as an SSH process')
end
return 'dispatch_state: '..checks..' checks'
