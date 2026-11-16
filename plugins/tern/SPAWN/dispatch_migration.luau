-- Pure paired cutover. Native callers authenticate peer proof/projection BEFORE entry.
-- No KV, initialization, effect execution, or immutable request rewriting occurs here.
local Codec=require('./wire/codec')
local P=require('./bridge_protocol')
local Mailbox=require('./mailbox')
local Config=require('./config')
local M={}
local MAX=9007199254740991
local function failure(code,message) return {ok=false,code=code,message=message} end
local function blocked(message) return nil,failure('migration_blocked',message) end
local function sorted_keys(map)
 local keys={};for key in pairs(map) do table.insert(keys,key) end;table.sort(keys);return keys
end
local function native_binding(b)
 return type(b)=='table' and P.text(b.session_key,2048,false) and P.text(b.authority_id,256,false) and P.text(b.host_key,1024,false) and P.integer(b.native_session,0)
end
local function route(e)
 if e.attachment then return e.attachment.origin_binding,e.attachment.controller_pane,e.attachment.pane_binding end
 if e.request then return e.request.origin_binding,e.request.controller_pane,e.pane_binding end
 return e.origin_binding,e.controller_pane,e.pane_binding
end
local function legacy_request(r)
 if type(r)~='table' or r.schema~=1 or not P.binding(r.origin_binding) then return nil end
 -- Semantic inspection only. These synthetic fields are never persisted/issued.
 local v=P.clone(r);v.schema=2;v.authority_namespace='legacy-inspection';v.logical_session_id=r.origin_binding.logical_session_id;v.admission_seq=1
 if r.op=='status' then v.target_request_serial=1
 elseif r.op~='owner_status' then v.request_serial=1;v.next_request_serial=2;v.settled_before=1;v.consumed=tern.json.array() end
 return if Codec.decode_dispatch_request(tern.json.encode(v)) then v else nil
end
local function legacy_body(body,request)
 if type(body)~='table' or body.schema~=1 or body.origin~='orchplus' and body.origin~=nil then return false end
 if #tern.json.encode(body)>Codec.LIMITS.bridge then return false end
 local b=P.clone(body);b.schema=2;b.origin=nil;b.authority_namespace='legacy-inspection';b.logical_session_id=request.logical_session_id;b.admission_seq=1;b.spawn_namespace='legacy-inspection';b.authority_revision=0
 b.request_serial=request.request_serial;b.category='current_result'
 if b.status=='missing' and request.op=='status' then b.category='unknown_effect' end
 if type(b.payload)=='table' then
  if b.status=='catalog' and b.payload.catalog_version==nil then
   -- Pre-setup catalogs had neither field. Validate only this inspection copy
   -- against current row schemas; never publish or persist invented setup evidence.
   if b.payload.setup~=nil then return false end
   b.payload.catalog_version=2
   b.payload.setup={schema=1,state='not_started',config_revision=b.payload.config_revision,
    readiness={state='not_run',config_revision=b.payload.config_revision,summary=''}}
  end
  if b.status=='catalog' and b.payload.catalog_version==1 then b.payload.catalog_version=2 end
  for _,field in ipairs({'capabilities','records'}) do
   if type(b.payload[field])=='table' and next(b.payload[field])==nil then b.payload[field]=tern.json.array() end
  end
  -- C2's persisted empty record lists lose their JSON array marker. Restore
  -- only those known empty lists in this inspection copy, never source bytes.
  if b.status=='catalog' and type(b.payload.records)=='table' then
   for _,record in ipairs(b.payload.records) do
    if type(record)=='table' then
     for _,field in ipairs({'capabilities','unsupported'}) do
      if type(record[field])=='table' and next(record[field])==nil then record[field]=tern.json.array() end
     end
    end
   end
  end
 end
 local decoded,problem,shapes=Codec.strict_decode(tern.json.encode(b),Codec.LIMITS.logical)
 return not problem and Codec.validate_dispatch_response_body(decoded,shapes)
  and b.op==request.op and b.request_id==request.request_id and b.action_id==request.action_id and P.equal(b.origin_binding,request.origin_binding)
end
local ENTRY={request=true,body=true,claim=true,orch_claim=true,authorization=true,authorization_fence=true,wake=true,attachment=true,launch=true,launch_sha256=true,identity=true,capabilities=true,binding=true,observer_id=true,attempt_id=true,attempt_pending=true,pane_binding=true,acceptance=true,stop_request_id=true,stop_backend=true,retirement_result=true,operation=true,stopped=true,mailbox_live=true}
local function legacy_complete(root)
 -- The caller's store validator handles required maps and base schemas. This scan
 -- closes legacy gaps before the source bytes are allowed to become evidence.
 for _,o in pairs(root.owners) do
  if not P.text(o.authority,256,false) or not P.integer(o.host_session,0) or o.recovery_revision~=nil and not P.integer(o.recovery_revision,0) then return false end
 end
 local n=0;for k,t in pairs(root.tombstones) do
  n+=1
  if not P.integer(k,1) or not P.fields(t,{binding=P.binding,revision=function(v)return P.integer(v,1)end},{authority=true,host_session=true,evidence=true})
   or t.authority~=nil and not P.text(t.authority,256,false) or t.host_session~=nil and not P.integer(t.host_session,0) or t.evidence~=nil and not P.text(t.evidence,256,false) then return false end
 end
 for i=1,n do if root.tombstones[i]==nil then return false end end
 for key,digest in pairs(root.request_fences) do if type(key)~='string' or not P.digest(digest) then return false end end
 for _,e in pairs(root.requests) do
  if not P.fields(e,{request=true,body=true},ENTRY) then return false end
  local r=legacy_request(e.request)
  if not r or not legacy_body(e.body,r) then return false end
  if e.binding~=nil and not native_binding(e.binding) then return false end
  if e.launch~=nil then
   local l=e.launch
   if (r.op~='launch' and r.op~='adopt') or not P.fields(l,{backend=true},{command=true,cwd=true,placement=true,prompt=true,capabilities=true,adopt=true})
    or l.backend~='native-agent' and l.backend~='local-terminal' and l.backend~='ssh-command' then return false end
   if r.op=='adopt' then
    if l.adopt~=true or l.backend~='native-agent' or not P.text(l.prompt,32768,false) or l.command~=nil then return false end
   elseif l.adopt~=nil or not P.text(l.command,64000,false) or not P.text(l.cwd,32768,false) or not ({tab=true,split=true,replace_if_alone=true})[l.placement] then return false end
   if l.prompt~=nil and not P.text(l.prompt,32768,false) then return false end
   if l.capabilities~=nil then
    if type(l.capabilities)~='table' then return false end
    for k,c in pairs(l.capabilities) do if k~=1 or c~='argv-v1' then return false end end
   end
  end
  if e.pane_binding~=nil and not P.pane(e.pane_binding) then return false end
  if e.observer_id~=nil and not P.text(e.observer_id,256,false) or e.attempt_id~=nil and not P.text(e.attempt_id,256,false) or e.attempt_pending~=nil and type(e.attempt_pending)~='boolean' then return false end
  if e.operation~=nil and not P.id(e.operation) or e.stop_request_id~=nil and not P.id(e.stop_request_id) then return false end
  if e.mailbox_live~=nil and type(e.mailbox_live)~='boolean' or e.stopped~=nil and e.stopped~='absent' and e.stopped~='exited' then return false end
  if e.retirement_result~=nil then
   if r.op~='mailbox_retire' or r.mode~='retire' or not legacy_body(e.retirement_result,r) or e.retirement_result.status~='retired' then return false end
  end
  if e.authorization~=nil then
   local a=e.authorization
   if not P.fields(a,{nonce=P.id,boot=P.id,bridge=true,binding=native_binding,session=true,deadline=true,new=true,phase=true},{base_body=true,window_executor=P.id})
    or not P.integer(a.bridge,1) or not P.integer(a.session,0) or type(a.deadline)~='number' or a.deadline~=a.deadline or a.deadline<0 or a.deadline>MAX or type(a.new)~='boolean'
    or a.phase~='requested' and a.phase~='consumed' or a.base_body~=nil and not legacy_body(a.base_body,r) then return false end
  end
  if e.authorization_fence~=nil and not P.fields(e.authorization_fence,{nonce=P.id,phase=true,bridge=true},{executor=P.id}) then return false end
  if e.wake~=nil then
   local w=e.wake
   if not P.fields(w,{phase=true,pane_binding=P.pane},{claim=true,request_id=P.id}) or not ({resolved=true,claimed=true,launching=true,uncertain=true,submitted=true})[w.phase]
    or w.claim~=nil and not P.fields(w.claim,{executor_id=P.id,boot=P.id}) then return false end
  end
  if e.attachment~=nil and not P.fields(e.attachment,{origin_binding=P.binding,controller_pane=true,pane_binding=P.pane,request_id=P.id,revision=function(v)return P.integer(v,1)end,attestation=true}) then return false end
  if e.acceptance~=nil then
   if not P.fields(e.acceptance,{event_id=P.id,seq=function(v)return P.integer(v,1)end,event_sha256=P.digest})
    or (r.op~='launch' and r.op~='adopt') or e.acceptance.event_id~=Codec.sha256(r.mailbox_handle..':report:'..string.format('%.0f',e.acceptance.seq)) then return false end
  end
  if e.stop_request_id then
   local stop=root.requests[r.logical_session_id..'/'..e.stop_request_id]
   if not stop or stop.request.op~='stop' or stop.request.target_request_id~=r.request_id or stop.request.target_action_id~=r.action_id then return false end
  end
 end
 for id,g in pairs(root.gates) do
  if not P.id(id) or not P.fields(g,{request=true,records=true,binding=native_binding,boot=P.id},{consumed=true,outcome=true}) then return false end
  local r=g.request
  if not P.fields(r,{schema=true,origin=true,op=true,request_id=P.id,source_client=true,target_host=true,source_revision=true,source_sha256=P.digest,records_json=true})
   or r.schema~=1 or r.origin~='spawn-migration' or r.op~='import_config' or not P.integer(r.source_revision,0) or not P.text(r.records_json,8192,false)
   or Codec.sha256(r.records_json)~=r.source_sha256 or g.binding.host_key~=r.target_host then return false end
  local records=Codec.strict_decode(r.records_json,8192)
  if not records or not Config.validate_records(records) or not P.equal(records,g.records) then return false end
  if g.consumed~=nil and (g.consumed~=true or type(g.outcome)~='table' or g.outcome.request_id~=r.request_id) then return false end
 end
 return true
end
local function current_complete(root)
 if root.authority_namespace~=nil and not Codec.validate_dispatch_authority({authority_namespace=root.authority_namespace,authority_revision=root.revision}) then return false end
 if root.authority_namespace==nil and (root.admission_cursor~=0 or next(root.sessions)~=nil or next(root.workers)~=nil) then return false end
 local admissions={}
 for _,s in pairs(root.sessions) do
  if not P.text(s.authority,256,false) or not P.integer(s.host_session,0) or type(s.controller_pane)~='string' or #s.controller_pane>32 or not s.controller_pane:match('^%d+$') or admissions[s.admission_seq] then return false end
  admissions[s.admission_seq]=true
 end
 for _,w in pairs(root.workers) do
  if not P.fields(w,{kind=true,logical_session_id=P.id,worker_id=P.id,worker_generation=true,launch_request_id=P.id,launch_action_id=P.id,work_id=P.id,enrolment_token=P.token,assignment_sha256=P.digest,mailbox_handle=P.id,
    record_id=true,record_revision=true,origin_binding=P.binding,controller_pane=true,controller_generation=true,phase=true,backend=true,binding=native_binding,mailbox_live=true},
    {delivery=function(v)return v=='native_ask' or v=='clipboard'end,pane_binding=P.pane,acceptance=true,attempt_id=true,observer_id=true,handover_id=P.id,handover_token=P.token,coordinator_owner_id=P.id,coordinator_generation=true,attachment=true,stopped=true,stop_request_id=P.id,capabilities=true,wakes=true})
   or w.kind~='launch' and w.kind~='adopt' and w.kind~='enrol' or (w.kind=='enrol')~=(w.delivery~=nil) or not P.text(w.record_id,256,false) or not P.integer(w.record_revision,0) or not P.integer(w.controller_generation,1)
   or w.phase~='accepted' and w.phase~='awaiting_acceptance' and w.phase~='uncertain' or w.backend~='native-agent' and w.backend~='local-terminal' and w.backend~='ssh-command'
   or (w.handover_id==nil)~=(w.handover_token==nil) or (w.coordinator_owner_id==nil)~=(w.coordinator_generation==nil)
   or w.coordinator_generation~=nil and not P.integer(w.coordinator_generation,1) then return false end
  if w.acceptance~=nil and not P.fields(w.acceptance,{event_id=P.id,seq=function(v)return P.integer(v,1)end,event_sha256=P.digest}) then return false end
  if w.attachment~=nil and not P.fields(w.attachment,{origin_binding=P.binding,controller_pane=true,pane_binding=P.pane}) then return false end
  if w.wakes~=nil and type(w.wakes)~='table' then return false end
 end
 local allowed=table.clone(ENTRY);allowed.request_json=true;allowed.wakes=true;allowed.relay_binding=P.digest;allowed.relay_consent=true;allowed.relay_result=true;allowed.native_result=true
 for _,e in pairs(root.requests) do
  if not P.fields(e,{request=true,request_json=true,body=true},allowed) or e.wakes~=nil and type(e.wakes)~='table' then return false end
 end
 return root.migration==nil or Codec.validate_dispatch_compatibility(root.migration) and root.migration.kind=='migration'
  and root.migration.spawn.candidate_namespace==root.namespace and root.migration.orch.candidate_namespace==root.authority_namespace
end
local function checked(root,validate)
 if type(root)~='table' or type(validate)~='function' then return nil,failure('state_missing','An established source and its whole-store validator are required.') end
 local ok,valid=pcall(validate,root)
 if not ok or not valid then return nil,failure('state_corrupt','The complete managed source failed validation.') end
 if root.version~=1 and root.version~=2 then return nil,failure('state_corrupt','Unsupported managed source schema.') end
 if root.version==1 then
  local complete,valid_legacy=pcall(legacy_complete,root)
  if not complete or not valid_legacy then return nil,failure('state_corrupt','The legacy source has invalid or unsupported persisted evidence.') end
 else
  local complete,valid_current=pcall(current_complete,root)
  if not complete or not valid_current then return nil,failure('state_corrupt','The current source contains invalid identity or prepared-obligation evidence.') end
 end
 return true
end
local function unsettled(e)
 local phase=e.body.status
 return phase=='pending' or phase=='resolved' or phase=='claimed' or phase=='launching' or phase=='uncertain' or e.retirement_result~=nil or e.attempt_pending==true
  or e.authorization~=nil or e.authorization_fence~=nil or e.wake~=nil and (e.wake.phase~='submitted' or e.wake.request_id~=nil)
end
local function legacy_worker(e)
 local r=e.request;local enrollment=r.enrolment
 return {kind=r.op,logical_session_id=r.origin_binding.logical_session_id,worker_id=enrollment.worker_id,worker_generation=enrollment.worker_generation,
  launch_request_id=r.request_id,launch_action_id=r.action_id,work_id=r.work_id,enrolment_token=enrollment.enrolment_token,assignment_sha256=enrollment.assignment_sha256,
  mailbox_handle=r.mailbox_handle,record_id=r.record_id,record_revision=r.record_revision,origin_binding=P.clone(r.origin_binding),controller_pane=r.controller_pane,controller_generation=r.controller_generation,
  pane_binding=P.clone(e.pane_binding),acceptance=P.clone(e.acceptance),phase=e.body.status,backend=e.launch.backend,binding=P.clone(e.binding),attempt_id=e.attempt_id,observer_id=e.observer_id,
  handover_id=enrollment.handover_id,handover_token=enrollment.handover_token,coordinator_owner_id=enrollment.coordinator_owner_id,coordinator_generation=enrollment.coordinator_generation,
  attachment=if e.attachment then {origin_binding=P.clone(e.attachment.origin_binding),controller_pane=e.attachment.controller_pane,pane_binding=P.clone(e.attachment.pane_binding)} else nil,
  stopped=e.stopped,mailbox_live=true}
end
-- Requires the full local source to have passed its validator. Never hashes peer identities as ours.
function M.identity(root)
 local normal={schema=1,sessions=tern.json.array(),workers=tern.json.array()}
 local pending,blockers=0,0
 local workers={};local sessions={};local legacy=root.version==1
 for key,e in pairs(root.requests) do
  if not legacy then blockers+=1 elseif unsettled(e) then pending+=1 end
  local r=e.request
  if legacy and (r.op=='launch' or r.op=='adopt') and e.launch and e.pane_binding and (e.body.status=='accepted' or e.body.status=='awaiting_acceptance') then
   local generation=root.mailboxes.generations[r.mailbox_handle]
   if e.mailbox_live~=false and (not generation or generation.status~='retired') then workers[key]=legacy_worker(e) end
  end
 end
 if not legacy then for key,w in pairs(root.workers) do workers[key]=w;if w.wakes and next(w.wakes) or w.stop_request_id or w.phase=='uncertain' then blockers+=1 end end end
 if legacy then
  for _,e in pairs(root.requests) do
   if e.request.op=='stop' and e.body.status=='stopped' then
    local w=workers[e.request.origin_binding.logical_session_id..'/'..e.request.target_request_id]
    if w then
     if not P.equal(select(3,route(w)),e.body.payload.pane_binding) then blockers+=1 else w.stopped=e.body.payload.observation end
    end
   end
  end
 end
 for logical,s in pairs(if legacy then root.owners else root.sessions) do
  local binding=if legacy then s.binding else s.control.binding
  local pane=if legacy then nil else s.controller_pane
  if legacy then
   for _,e in pairs(root.requests) do local origin,controller=route(e);if P.equal(origin,binding) then if pane and pane~=controller then blockers+=1 end;pane=controller end end
   if s.recovery_revision~=nil then blockers+=1 end
  elseif s.control.recovery~=nil or s.control.phase~='open' then blockers+=1 end
  if binding and not pane then blockers+=1 end
  local identity={logical_session_id=logical}
  if binding and pane then identity.binding=P.clone(binding);identity.controller_pane=pane end
  sessions[logical]=identity
 end
 for _,logical in ipairs(sorted_keys(sessions)) do table.insert(normal.sessions,sessions[logical]) end
 local selected={}
 for handle,g in pairs(root.mailboxes.generations) do
  if g.active or g.frozen then blockers+=1 end
  for _,w in pairs(g.writes) do
   if w.status~='settled' or w.result and w.result.status=='uncertain' then
    if w.request.schema==1 then pending+=1 else blockers+=1 end
   end
  end
  if g.status=='retired' then if not legacy then blockers+=1 end;continue end
  local b=g.binding;local key=b.logical_session_id..'/'..b.launch_request_id;local w=workers[key]
  if not w or not sessions[b.logical_session_id] or g.status~='provisioned' then blockers+=1;continue end
  local matches=w.mailbox_handle==handle and w.record_id==g.record_id and w.record_revision==g.record_revision and w.mailbox_live~=false and native_binding(w.binding)
  for _,field in ipairs({'logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token'}) do if w[field]~=b[field] then matches=false end end
  if g.handover then
   if w.handover_id~=g.handover.handover_id or not P.token(w.handover_token) or Codec.sha256(w.handover_id..':'..w.handover_token)~=g.handover.handover_sha256 then matches=false end
  elseif w.handover_id~=nil or w.handover_token~=nil then matches=false end
  if not matches then blockers+=1;continue end
  selected[key]=true
  local origin,pane,native=route(w)
  local identity={logical_session_id=b.logical_session_id,worker_id=b.worker_id,worker_generation=b.worker_generation,launch_request_id=b.launch_request_id,work_id=b.work_id,
   enrolment_sha256=Codec.sha256('orchplus-enrolment-v1\n'..b.enrolment_token),mailbox_handle=handle,record_id=g.record_id,record_revision=g.record_revision,binding_digest=g.binding_digest,mailbox_live=true,
   manifest_sha256=g.manifest_sha256,execution_origin=P.clone(origin),execution_controller_pane=pane,pane_binding=P.clone(native),stopped=w.stopped}
  if g.handover then identity.handover_id=g.handover.handover_id;identity.handover_sha256=g.handover.handover_sha256 end
  local caps=Mailbox.provisioned_capabilities(root.mailboxes,handle)
  if caps then table.sort(caps);identity.capabilities=caps end
  table.insert(normal.workers,identity)
 end
 for key in pairs(workers) do if not selected[key] then blockers+=1 end end
 for _,g in pairs(root.gates) do if not g.consumed or not g.outcome or g.outcome.status=='uncertain' then blockers+=1 end end
 if not legacy then for _ in pairs(root.controls) do blockers+=1 end end
 table.sort(normal.workers,function(a,b)return a.mailbox_handle<b.mailbox_handle end)
 local digest,why=Codec.dispatch_managed_digest(tern.json.encode(normal))
 if not digest then return nil,why,pending,blockers+1 end
 return normal,nil,pending,blockers
end
function M.proof(root,validate)
 local valid,why=checked(root,validate);if not valid then return nil,why end
 local ok,normal,problem,pending,blockers=pcall(M.identity,root)
 if not ok then return nil,failure('state_corrupt','The source contains malformed current identity references.') end
 if not normal then return nil,problem end
 local digest=Codec.dispatch_managed_digest(tern.json.encode(normal))
 return {source_schema=root.version,source_revision=root.revision,source_namespace=root.namespace,candidate_namespace=root.namespace,
  source_sha256=Codec.sha256(Codec.dispatch_source_bytes(root)),protocol=if root.version==1 then 1 else 2,
  state=if pending==0 and blockers==0 then 'ready' else 'blocked',phase=if root.version==1 then 'prepared' else 'stable',managed_sha256=digest,pending_immutable=pending,blockers=blockers},nil,normal
end
-- Only bounded references cross the native boundary. Full identity facts stay local.
function M.selection(normal)
 local selection={logical_session_ids=tern.json.array(),mailbox_handles=tern.json.array()}
 for _,session in ipairs(normal.sessions) do table.insert(selection.logical_session_ids,session.logical_session_id) end
 for _,worker in ipairs(normal.workers) do table.insert(selection.mailbox_handles,worker.mailbox_handle) end
 return selection
end
local function agreement(own,normal,compatibility,peer_selection)
 if not Codec.validate_dispatch_compatibility(compatibility) or compatibility.kind~='migration' or not P.equal(own,compatibility.spawn)
  or not Codec.validate_dispatch_migration_selection(peer_selection) or not P.equal(M.selection(normal),peer_selection) then return false end
 local peer=compatibility.orch
 return own.state=='ready' and peer.state=='ready' and own.pending_immutable==0 and own.blockers==0 and peer.pending_immutable==0 and peer.blockers==0
  and own.managed_sha256==peer.managed_sha256
end
function M.prepare(root,compatibility,peer_selection,validate)
 local own,why,normal=M.proof(root,validate);if not own then return nil,why end
 if root.migration~=nil or not agreement(own,normal,compatibility,peer_selection) then return blocked('Both exact native source proofs, complete selections and independently derived identities must agree before preparation.') end
 if root.revision==MAX then return blocked('The source revision is exhausted.') end
 if root.version==2 then
  if root.authority_namespace~=nil or root.admission_cursor~=0 or next(root.sessions)~=nil or next(root.workers)~=nil or next(root.requests)~=nil or next(root.controls)~=nil or next(root.mailboxes.generations)~=nil then
   return blocked('Only an explicitly initialized empty unpaired current source can establish its first authority namespace.')
  end
  local candidate=P.clone(root);candidate.authority_namespace=compatibility.orch.candidate_namespace;candidate.migration=P.clone(compatibility);candidate.revision+=1
  local valid,problem=checked(candidate,validate);if not valid then return nil,problem end
  return candidate,nil
 end
 local candidate={version=2,namespace=root.namespace,revision=root.revision+1,next_id=root.next_id,authority_namespace=compatibility.orch.candidate_namespace,
  admission_cursor=0,sessions={},workers={},requests={},controls={},gates=P.clone(root.gates),mailboxes=P.clone(root.mailboxes),migration=P.clone(compatibility)}
 for _,identity in ipairs(normal.sessions) do
  local logical=identity.logical_session_id;local old=root.owners[logical]
  candidate.admission_cursor+=1
  candidate.sessions[logical]={admission_seq=candidate.admission_cursor,authority=old.authority,host_session=old.host_session,controller_pane=identity.controller_pane,
   control={phase='open',binding=P.clone(identity.binding),generation_floor=identity.binding.owner_generation-1,request_floor=1,next_request_serial=1,last_authority_revision=compatibility.orch.source_revision}}
 end
 for _,identity in ipairs(normal.workers) do
  local key=identity.logical_session_id..'/'..identity.launch_request_id
  local worker=legacy_worker(root.requests[key]);worker.capabilities=P.clone(identity.capabilities);worker.stopped=identity.stopped
  candidate.workers[key]=worker
 end
 -- Retired generations have no live peer worker and no remaining old effect.
 for handle,g in pairs(candidate.mailboxes.generations) do if g.status=='retired' then candidate.mailboxes.generations[handle]=nil end end
 local valid,problem=checked(candidate,validate);if not valid then return nil,problem end
 local projected,diagnostic=M.identity(candidate)
 if not projected or not P.equal(projected,normal) then return nil,diagnostic or failure('invalid_candidate','The candidate changed a current managed identity.') end
 return candidate,nil
end
function M.finish(root,compatibility,peer_selection,validate)
 local own,why,normal=M.proof(root,validate);if not own then return nil,why end
 if root.version~=2 or not root.migration or not Codec.validate_dispatch_compatibility(root.migration) or root.migration.kind~='migration'
  or not Codec.dispatch_compatibility_ready(compatibility) or not agreement(own,normal,compatibility,peer_selection)
  or compatibility.orch.candidate_namespace~=root.authority_namespace or compatibility.orch.candidate_namespace~=root.migration.orch.candidate_namespace
  or root.revision==MAX then return blocked('Both fresh native current candidates must agree before the prepared obligation can settle.') end
 local candidate=P.clone(root);candidate.migration=nil;candidate.revision+=1
 local valid,problem=checked(candidate,validate);if not valid then return nil,problem end
 return candidate,nil
end
return M
