-- Pure paired migration owner tests. Run with the staged SPAWN package root.
local root=...
assert(type(root)=='string','pass the package directory')
local runtime,environment=tern,getfenv()
local modules={}
local fake=setmetatable({kv={get=function()error('migration must not read KV')end,set=function()error('migration must not write KV')end}},{__index=runtime})
local function load(name)
 name=name:gsub('^%./','')
 if modules[name] then return modules[name] end
 local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
 setfenv(chunk,setmetatable({require=load,tern=fake},{__index=environment}))
 modules[name]=chunk();return modules[name]
end
local Migration,State,Mailbox,Codec,P=load('dispatch_migration'),load('dispatch_state'),load('mailbox'),load('wire/codec'),load('bridge_protocol')
local checks=0
local function check(value,message) assert(value,message);checks+=1 end
local function empty(version)
 local r={version=version,namespace='spawn-established',revision=7,next_id=3,requests={},mailboxes=Mailbox.empty(),gates={}}
 if version==1 then r.owners={};r.tombstones={};r.request_fences={}
 else r.sessions={};r.workers={};r.controls={};r.admission_cursor=0 end
 return r
end
local function evidence(source,protocol)
 local own,why,normal=Migration.proof(source,State.validate_registry);assert(own,why and why.message)
 local peer={source_schema=if protocol==1 then 3 else 4,source_revision=20,source_sha256=string.rep('a',64),candidate_namespace='orch-established',protocol=protocol,
  state='ready',phase=if protocol==1 then 'prepared' else 'stable',managed_sha256=own.managed_sha256,pending_immutable=0,blockers=0}
 if protocol==2 then peer.source_namespace=peer.candidate_namespace end
 return {schema=1,kind='migration',orch=peer,spawn=own},normal
end
for _,version in ipairs({1,2}) do
 local source=empty(version);local before=Codec.dispatch_source_bytes(source)
 local pair,normal=evidence(source,if version==1 then 1 else 2)
 check(pair.spawn.source_namespace==source.namespace and pair.spawn.candidate_namespace==source.namespace,'established SPAWN namespace is independent from ORCH namespace')
 local candidate,problem=Migration.prepare(source,pair,Migration.selection(normal),State.validate_registry)
 check(candidate and not problem and candidate.version==2 and candidate.migration and candidate.authority_namespace=='orch-established','validated empty source prepares without implicit initialization')
 check(candidate.owners==nil and candidate.tombstones==nil and candidate.request_fences==nil,'current candidate retains no legacy history maps')
 check(Codec.dispatch_source_bytes(source)==before,'preparation never mutates source')
 local candidatePair,candidateNormal=evidence(candidate,2)
 check(candidatePair.spawn.source_sha256==Codec.sha256(Codec.dispatch_source_bytes(candidate)) and candidatePair.spawn.source_sha256~=pair.spawn.source_sha256,'candidate proof hashes exact current source including migration obligation')
 local completed=assert(Migration.finish(candidate,candidatePair,Migration.selection(candidateNormal),State.validate_registry))
 check(completed.migration==nil and completed.namespace==source.namespace and candidate.migration~=nil,'completion is one pure validated candidate transition')
 local stale=P.clone(candidatePair);stale.spawn.source_sha256=pair.spawn.source_sha256
 check(Migration.finish(candidate,stale,Migration.selection(candidateNormal),State.validate_registry)==nil,'stale original source hash cannot settle current candidate')
 local compact={schema=1,kind='current',protocol=2,authority_namespace='orch-established',spawn_namespace=source.namespace}
 check(Migration.prepare(source,compact,Migration.selection(normal),State.validate_registry)==nil and Migration.finish(candidate,compact,Migration.selection(normal),State.validate_registry)==nil,'compact claims never initialize or settle preparation')
 local wrong=P.clone(candidatePair);wrong.orch.candidate_namespace='other';wrong.orch.source_namespace='other'
 check(Migration.finish(candidate,wrong,Migration.selection(candidateNormal),State.validate_registry)==nil,'a different peer namespace cannot finish the original migration')
 local firstFinished=P.clone(candidatePair);firstFinished.orch.source_revision+=1;firstFinished.orch.source_sha256=string.rep('b',64)
 check(Migration.finish(candidate,firstFinished,Migration.selection(candidateNormal),State.validate_registry)~=nil,'fresh authenticated already-stable peer source permits second-side finish')
end
do
 local source=empty(1);local pair,normal=evidence(source,1)
 pair.orch.source_schema=2
 local candidate=Migration.prepare(source,pair,Migration.selection(normal),State.validate_registry)
 check(candidate and candidate.migration.orch.source_schema==2 and candidate.migration.orch.source_sha256==pair.orch.source_sha256,'SPAWN preserves exact v2 ORCH source evidence through paired preparation')
 for _,schema in ipairs({1,4}) do
  local unsupported=P.clone(pair);unsupported.orch.source_schema=schema
  check(not Codec.validate_dispatch_compatibility(unsupported),'namespace-free ORCH evidence is limited to supported legacy schemas')
 end
 local current=P.clone(pair);current.orch.protocol=2
 check(not Codec.validate_dispatch_compatibility(current),'v2 source schema does not excuse missing namespace on current protocol')
 local missingPeer=P.clone(pair);missingPeer.spawn.source_namespace=nil
 check(not Codec.validate_dispatch_compatibility(missingPeer),'legacy ORCH compatibility never permits an unidentified SPAWN source')
end
check(Migration.proof(nil,State.validate_registry)==nil,'missing established source is never first use')
check(Migration.proof(empty(2),function()return nil end)==nil,'whole-source validation is mandatory before hashing')
local origin={logical_session_id='session',owner_id='owner',owner_generation=2,host_pane_id='12',alias_nonce='alias',window_key='',window_epoch='epoch',native_session_id='4',window_host_id='7'}
local native={pane_id='55',window_epoch='epoch',window_key='',native_session_id='4',window_host_id='7'}
local binding={session_key='authority/session/4',authority_id='native-authority',host_key='host',native_session=4}
local function issued(op)
 return {schema=2,origin='orchplus',op=op,request_id='provision',action_id='provision-action',authority_namespace='orch-established',logical_session_id='session',admission_seq=1,
  request_serial=1,next_request_serial=2,settled_before=1,consumed=runtime.json.array(),origin_binding=P.clone(origin),controller_pane='44',controller_generation=2,
  worker_id='worker',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token=string.rep('t',16),record_id='record',record_revision=1,capability='report-files-v1'}
end
local function old_request(r)
 local result=P.clone(r);result.schema=1
 for _,field in ipairs({'authority_namespace','admission_seq','request_serial','next_request_serial','settled_before','consumed'}) do result[field]=nil end
 return result
end
local function active()
 local r=empty(1)
 r.owners.session={binding=P.clone(origin),authority='native-authority',host_session=4}
 local record={id='record',backend='local-terminal',mailbox={permitted_root='/private/mailboxes',helper_path='/private/tools/mailbox_target.sh',producer_helper_path='/private/tools/mailbox_worker.sh',worker_identity='worker',verified=true,evidence_ref='fixture',wake='worker-poll-v1',producer={read=true,write=true,hash=true,journal=true,poll=true},capabilities={'report-files-v1','worker-poll-v1','argv-v1','coordinator-control-v1'}}}
 local request=issued('mailbox_provision')
 local operation,intent=Mailbox.prepare(r.mailboxes,request,record,{operation_id='operation',handle='mailbox',host_os='linux',host_shell='sh'})
 assert(operation and intent)
 r.mailboxes=assert(Mailbox.settle(intent,operation,{status='provisioned'}))
 local write=r.mailboxes.generations.mailbox.writes.provision;write.request=old_request(write.request)
 local descriptor=runtime.json.decode(write.bytes);descriptor.capabilities=nil;write.bytes=runtime.json.encode(descriptor)
 local launch={schema=1,origin='orchplus',op='launch',request_id='launch',action_id='launch-action',origin_binding=P.clone(origin),controller_pane='44',controller_generation=2,
  record_id='record',record_revision=1,work_id='work',prompt='assignment',cwd='/work',placement='tab',fresh=true,mailbox_handle='mailbox',
  enrolment={worker_id='worker',worker_generation=1,enrolment_token=string.rep('t',16),assignment_sha256=Codec.sha256('assignment')}}
 local payload={record_id='record',record_revision=1,effective_identity={backend='local-terminal'},capabilities=P.clone(record.mailbox.capabilities),prompt_delivery='submitted_not_accepted',pane_binding=P.clone(native)}
 local built={backend='local-terminal',command='worker',cwd='/work',placement='tab'}
 r.requests['session/launch']={request=launch,body={schema=1,op='launch',request_id='launch',action_id='launch-action',origin_binding=P.clone(origin),controller_generation=2,status='awaiting_acceptance',payload=payload},
  launch=built,launch_sha256=P.fingerprint(built),binding=P.clone(binding),pane_binding=P.clone(native),observer_id='managed-observer',attempt_id='attempt'}
 return r
end
local source=active()
source.request_fences['closed/999999']=string.rep('c',64)
local retiredOrigin=P.clone(origin);retiredOrigin.logical_session_id='closed'
source.tombstones={{binding=retiredOrigin,revision=2,authority='native-authority',host_session=4,evidence='operator_attested_controller_and_launch_executors_stopped_or_retired'}}
local pair,normal=evidence(source,1)
check(pair.spawn.state=='ready' and #normal.workers==1 and normal.workers[1].capabilities==nil,'legacy current identity omits absent descriptor permission rather than backfilling current config')
check(normal.workers[1].enrolment_sha256==Codec.sha256('orchplus-enrolment-v1\n'..string.rep('t',16)),'normal form exposes only domain-separated enrollment digest')
local candidate=assert(Migration.prepare(source,pair,Migration.selection(normal),State.validate_registry))
check(candidate.sessions.session.admission_seq==1 and candidate.admission_cursor==1 and candidate.workers['session/launch'].request==nil and next(candidate.requests)==nil,'migration keeps current worker facts and sorted admission, not completed launch request/body')
check(candidate.sessions.closed==nil and candidate.sessions.session.control.request_floor==1 and candidate.sessions.session.control.next_request_serial==1,'old tombstones do not reconstruct admissions and maximum old fences do not raise issuance floors')
do
 -- C2 persisted empty nested lists as ordinary JSON objects. Inspect those
 -- semantic lists without rewriting the immutable catalog or source bytes.
 local withCatalog=active()
 local request={schema=1,origin='orchplus',op='catalog',request_id='catalog',action_id='catalog-action',
  origin_binding=P.clone(origin),controller_pane='44',controller_generation=2}
 local payload={catalog_version=2,namespace='saved-authority',host_key='host',revision=1,config_revision=1,
  setup={schema=1,state='completed',config_revision=1,readiness={state='not_run',config_revision=0,summary=''}},
  records={
   {id='record',revision=1,eligible=true,capabilities={'argv-v1'},unsupported={}},
   {id='unconfigured',revision=1,eligible=false,capabilities={},unsupported={'Transport is not configured'}},
  }}
 withCatalog.requests['session/catalog']={request=request,body={schema=1,op='catalog',request_id='catalog',action_id='catalog-action',
  origin_binding=P.clone(origin),controller_generation=2,status='catalog',payload=payload}}
 local bytes=Codec.dispatch_source_bytes(withCatalog)
 local proof,problem,projection=Migration.proof(withCatalog,State.validate_registry)
 check(proof and proof.state=='ready' and proof.managed_sha256==pair.spawn.managed_sha256,
  'actual C2 nested empty catalog lists preserve the ready live-worker migration identity')
 check(Codec.dispatch_source_bytes(withCatalog)==bytes,'legacy catalog inspection never rewrites persisted source bytes')
 local catalogPair={schema=1,kind='migration',orch=P.clone(pair.orch),spawn=proof}
 local prepared,why=Migration.prepare(withCatalog,catalogPair,Migration.selection(projection),State.validate_registry)
 check(prepared and prepared.workers['session/launch'].worker_id=='worker'
  and prepared.workers['session/launch'].pane_binding.pane_id==native.pane_id,
  'validated catalog history does not prevent preserving the real current worker during preparation')
 local preSetup=P.clone(withCatalog)
 local oldPayload=preSetup.requests['session/catalog'].body.payload
 oldPayload.catalog_version,oldPayload.setup=nil,nil
 local oldBytes=Codec.dispatch_source_bytes(preSetup)
 local oldProof,_,oldProjection=Migration.proof(preSetup,State.validate_registry)
 check(oldProof and oldProof.state=='ready' and oldProof.source_sha256==Codec.sha256(oldBytes),'pre-setup catalog proves the original source without inventing saved setup metadata')
 local oldPrepared=assert(Migration.prepare(preSetup,{schema=1,kind='migration',orch=P.clone(pair.orch),spawn=oldProof},Migration.selection(oldProjection),State.validate_registry))
 check(oldPrepared.workers['session/launch'].worker_id=='worker' and next(oldPrepared.requests)==nil
  and Codec.dispatch_source_bytes(preSetup)==oldBytes,'pre-setup catalog cutover preserves current worker and leaves original history unchanged')
 local hybrid=P.clone(preSetup);hybrid.requests['session/catalog'].body.payload.setup=P.clone(payload.setup)
 check(Migration.proof(hybrid,State.validate_registry)==nil,'unversioned catalog cannot carry later setup metadata')
 local malformed=P.clone(preSetup);malformed.requests['session/catalog'].body.payload.records[1].capabilities={'invented-capability'}
 check(Migration.proof(malformed,State.validate_registry)==nil,'pre-setup compatibility still rejects invalid persisted capability evidence')
 local full=P.clone(preSetup)
 local fullBody=full.requests['session/catalog'].body
 fullBody.payload.records[1].unsupported={string.rep('"',1900)}
 local fullBytes=Codec.dispatch_source_bytes(full)
 check(#runtime.json.encode(fullBody)<Codec.LIMITS.bridge,'retained legacy response is within its original storage bound')
 local framed=P.clone(fullBody);framed.schema=2;framed.authority_namespace='legacy-inspection';framed.logical_session_id='session'
 framed.admission_seq=1;framed.spawn_namespace='legacy-inspection';framed.authority_revision=0;framed.request_serial=1;framed.category='current_result'
 framed.payload.catalog_version=2;framed.payload.setup=P.clone(payload.setup)
 framed.payload.records[2].capabilities=runtime.json.array()
 local wire,wireError=Codec.encode_dispatch_response(framed)
 check(not wire and wireError.code=='oversize','same catalog cannot be sent as a new framed response; wire bound stays enforced')
 local fullProof=Migration.proof(full,State.validate_registry)
 check(fullProof and fullProof.state=='ready' and fullProof.source_sha256==Codec.sha256(fullBytes),
  'full legacy catalog validates without manufacturing a larger protocol 2 wire frame')
 check(Codec.dispatch_source_bytes(full)==fullBytes,'large catalog inspection preserves original bytes')
 fullBody.payload.records[1].unsupported={string.rep('"',4000)}
 check(Migration.proof(full,State.validate_registry)==nil,'legacy compatibility cannot exceed the original response storage bound')
 for _,mutate in ipairs({
  function(p)p.records[1].unsupported={unexpected='not an array'}end,
  function(p)p.records[2].capabilities={'invented-capability'}end,
  function(p)p.records[1].unsupported=nil end,
 }) do
  local invalid=P.clone(withCatalog);mutate(invalid.requests['session/catalog'].body.payload)
  local before=Codec.dispatch_source_bytes(invalid)
  check(Migration.proof(invalid,State.validate_registry)==nil,'malformed, unsupported or missing catalog evidence remains a migration hold')
  check(Codec.dispatch_source_bytes(invalid)==before,'rejected catalog inspection leaves original evidence intact')
 end
end
local routeChanged=P.clone(source)
routeChanged.requests['session/launch'].attachment={origin_binding=P.clone(origin),controller_pane='45',pane_binding={pane_id='56',window_epoch='new-epoch',window_key='new-window',native_session_id='4',window_host_id='7'},request_id='attached',revision=1,attestation='old_executors_stopped_or_retired'}
local currentRoute=assert(Migration.identity(routeChanged))
check(currentRoute.workers[1].execution_controller_pane=='45' and currentRoute.workers[1].pane_binding.pane_id=='56','current attached route wins over original launch route')
for _,mutate in ipairs({
 function(r)r.requests['session/launch'].body.status='uncertain' end,
 function(r)r.requests['session/launch'].wake={phase='resolved',pane_binding=P.clone(native)} end,
 function(r)r.owners.session.recovery_revision=1 end,
 function(r)r.mailboxes.generations.mailbox.status='intent';r.mailboxes.generations.mailbox.writes.provision.status='uncertain';r.mailboxes.generations.mailbox.writes.provision.result={status='uncertain'} end,
 function(r)r.owners={} end,
}) do
 local pending=P.clone(source);mutate(pending)
 local proof=assert(Migration.proof(pending,State.validate_registry))
 check(proof.state=='blocked' and proof.pending_immutable+proof.blockers>0,'all unresolved old effects, orphan mailboxes and recovery block cutover')
 local claim={schema=1,kind='migration',spawn=proof,orch=P.clone(pair.orch)}
 check(Migration.prepare(pending,claim,Migration.selection(normal),State.validate_registry)==nil,'matching claimed digest cannot bypass live obligations')
end
local corrupt=P.clone(source);corrupt.requests['session/launch'].hidden_history={}
check(Migration.proof(corrupt,State.validate_registry)==nil,'legacy whole-source inspection rejects unrecognized persisted request fields')
for _,mutate in ipairs({
 function(entry)entry.retirement_result=P.clone(entry.body);entry.retirement_result.status='retired' end,
 function(entry)entry.acceptance={event_id=Codec.sha256('wrong-mailbox:report:1'),seq=1,event_sha256=string.rep('a',64)} end,
}) do
 local invalid=P.clone(source);mutate(invalid.requests['session/launch'])
 local bytes=Codec.dispatch_source_bytes(invalid)
 check(Migration.proof(invalid,State.validate_registry)==nil,'launch evidence cannot carry a retirement result or foreign acceptance identity')
 check(Codec.dispatch_source_bytes(invalid)==bytes,'operation discriminator refusal preserves exact legacy evidence')
end
local badPeer={logical_session_ids=runtime.json.array(),mailbox_handles=runtime.json.array()}
check(Migration.prepare(source,pair,badPeer,State.validate_registry)==nil,'peer-selected subset cannot conceal a locally established worker')
local omittedWorker=Migration.selection(normal);table.clear(omittedWorker.mailbox_handles)
check(Migration.prepare(source,pair,omittedWorker,State.validate_registry)==nil,'matching proofs cannot hide an omitted locally established mailbox')
local omittedSession=Migration.selection(normal);table.clear(omittedSession.logical_session_ids)
check(Migration.prepare(source,pair,omittedSession,State.validate_registry)==nil,'matching proofs cannot hide an omitted local admission')
local changedProof=P.clone(pair);changedProof.orch.managed_sha256=string.rep('d',64)
check(Migration.prepare(source,changedProof,Migration.selection(normal),State.validate_registry)==nil,'matching selection does not substitute for full independent identity digest equality')
check(Migration.prepare(source,pair,normal,State.validate_registry)==nil,'native migration no longer accepts a full peer identity normal as selection')
-- Exercise the full reference cardinality and maximum ID width independently of
-- full-normal byte limits; qualification transmits only these reference arrays.
local maximum={sessions={},workers={}}
for i=1,64 do table.insert(maximum.sessions,{logical_session_id=string.rep('s',93)..string.format('%03d',i)}) end
for i=1,256 do table.insert(maximum.workers,{mailbox_handle=string.rep('w',93)..string.format('%03d',i)}) end
local selected=Migration.selection(maximum)
check(#selected.logical_session_ids==64 and #selected.mailbox_handles==256 and Codec.validate_dispatch_migration_selection(selected),'maximum 64-session/256-mailbox selection preserves every sorted bounded reference')
check(#runtime.json.encode(selected)<32768,'maximum-width compact selection fits below 32 KiB without transmitting full identity facts')
table.insert(selected.logical_session_ids,string.rep('s',93)..'065')
check(not Codec.validate_dispatch_migration_selection(selected),'a 65th session reference is refused')
table.remove(selected.logical_session_ids)
table.insert(selected.mailbox_handles,string.rep('w',93)..'257')
check(not Codec.validate_dispatch_migration_selection(selected),'a 257th mailbox reference is refused')
table.remove(selected.mailbox_handles)
selected.mailbox_handles[1],selected.mailbox_handles[2]=selected.mailbox_handles[2],selected.mailbox_handles[1]
check(not Codec.validate_dispatch_migration_selection(selected),'unsorted compact references cannot pass the canonical boundary')
selected=Migration.selection(maximum);selected.mailbox_handles[2]=selected.mailbox_handles[1]
check(not Codec.validate_dispatch_migration_selection(selected),'duplicate compact references cannot disguise omissions')
selected=Migration.selection(normal);selected.identity_facts=normal
check(not Codec.validate_dispatch_migration_selection(selected),'qualification selection rejects copied full identity facts')
return 'dispatch_migration: '..checks..' checks'
