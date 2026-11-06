-- Host-only SPAWN dispatcher. One writer; files/native effects are separate stores.
local P=require('./bridge_protocol')
local Codec=require('./codec')
local Authority=require('./authority')
local Config=require('./config')
local Backend=require('./backend')
local Mailbox=require('./mailbox')
local Capabilities=require('./mailbox_capabilities')
local M={}
local KEY='dispatch-v1'
local LIMIT=4*1024*1024
local RESERVE=256*1024
local boot=string.format('vm-%d-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647))
local loaded=false
local hold=nil
local function orch_claim(value)
 return P.fields(value,{executor=P.id,grant_id=P.id,epoch=function(v)return P.integer(v,1)end})
end
local function deadline(value)
 return type(value)=='number' and value==value and value>=0 and value<=9007199254740991
end
local function key(r) return r.origin_binding.logical_session_id..'/'..r.request_id end
local function same_owner(a,b)
 return a.logical_session_id==b.logical_session_id and a.owner_id==b.owner_id and a.owner_generation==b.owner_generation and a.host_pane_id==b.host_pane_id
end
local function route(entry)
 local a=entry.attachment
 return if a then a.origin_binding else entry.request.origin_binding,if a then a.controller_pane else entry.request.controller_pane,if a then a.pane_binding else entry.pane_binding
end
local function routed(entry,r)
 local origin,pane=route(entry)
 return P.equal(origin,r.origin_binding) and pane==r.controller_pane and entry.request.controller_generation==r.controller_generation
end
-- A launch-family entry owns a worker generation's pane: a fresh launch or an explicit adoption.
local function launched(entry) return entry~=nil and (entry.request.op=='launch' or entry.request.op=='adopt') end
local function retired_executor(root,origin)
 for _,t in ipairs(root.tombstones) do
  if P.equal(t.binding,origin) and t.evidence=='operator_attested_controller_and_launch_executors_stopped_or_retired' and t.host_session~=nil then return t end
 end
 return nil
end
local function executor_origin(root,entry)
 local id=entry.wake and entry.wake.request_id
 local wake=if id then root.requests[entry.request.origin_binding.logical_session_id..'/'..id] else nil
 return if wake then wake.request.origin_binding else entry.request.origin_binding
end
local function outstanding(entry)
 return entry.body.status=='claimed' or entry.body.status=='launching' or entry.body.status=='uncertain' or entry.body.status=='pending' and entry.operation~=nil or entry.wake and (entry.wake.phase=='claimed' or entry.wake.phase=='launching' or entry.wake.phase=='uncertain')
end
-- Waiting notifications are bounded durable obligations, not execution permits.
local function wake_occupancy(root,handle)
 local total,same=0,0
 for _,entry in pairs(root.requests) do
  if entry.wake and (entry.wake.request_id~=nil and entry.wake.phase~='submitted' or entry.wake.phase~='resolved' and entry.wake.phase~='submitted') then
   if not retired_executor(root,executor_origin(root,entry)) then total+=1 end
   if entry.request.handle==handle then same+=1 end
  end
 end
 return total,same
end
local function transport_occupancy(root,handle)
 local total,same=0,0
 for id,g in pairs(root.mailboxes.generations) do
  local occupied=g.active~=nil
  local uncertain=false
  for _,w in pairs(g.writes or {}) do if w.status=='uncertain' then uncertain=true;if not retired_executor(root,w.request.origin_binding) then occupied=true end end end
  if occupied then total+=1 end
  if id==handle and (occupied or uncertain) then same+=1 end
 end
 return total,same
end
local function fence_unstarted_wake(root,entry)
 local r=entry.request
 if r.op~='native_wake' or entry.body.status~='resolved' then return end
 local target=root.requests[r.origin_binding.logical_session_id..'/'..r.target_request_id]
 local w=target and target.wake
 if not w or w.request_id~=r.request_id or w.phase~='resolved' or w.claim then return end
 -- No native execution claim ever existed. Removing the exact reservation also
 -- rejects delayed wakeclaim events before a replacement can be authorized.
 w.request_id=nil
 entry.body=P.body(r,'full',{resource='native_wake_idle',current=1,limit=1,retryable=true,effect_started=false})
end
local function save(root,control)
 if not P.integer(root.revision,0) or root.revision>=9007199254740991 then return false,'Transport revision exhausted; preserve the registry for recovery' end
 root.revision+=1
 local ok,bytes=pcall(tern.json.encode,root)
 if not ok or #bytes>LIMIT-(if control then 0 else RESERVE) then return false,'Transport registry capacity exhausted; unresolved facts retained' end
 local stored,err=pcall(tern.kv.set,KEY,root)
 if not stored then hold='Transport commit failed; effects held. Inspect host storage before explicit recovery.';return false,hold end
 return true
end
-- Mailbox reports failures as {status,error={code}} tables; storage paths need a bounded message.
local function mailbox_error(why)
 if type(why)=='table' and type(why.error)=='table' and type(why.error.code)=='string' then
  local code=why.error.code:sub(1,64)
  if code=='journal_corrupt' then return 'Corrupt mailbox journal (journal_corrupt); restore it, do not reset' end
  return 'Mailbox journal refused ('..code..')'
 end
 return tostring(why):sub(1,512)
end
local function valid(root)
 if not P.fields(root,{version=true,revision=true,namespace=true,owners=true,tombstones=true,request_fences=true,requests=true,mailboxes=true,gates=true,next_id=true}) or root.version~=1 or not P.integer(root.revision,0) or not P.id(root.namespace) or not P.integer(root.next_id,1) or type(root.owners)~='table' or type(root.tombstones)~='table' or type(root.request_fences)~='table' or type(root.requests)~='table' or type(root.gates)~='table' then return nil,'Corrupt dispatch registry; restore it, do not reset' end
 local mail,why=Mailbox.validate(root.mailboxes);if not mail then return nil,mailbox_error(why) end
 for logical,owner in pairs(root.owners) do if not P.id(logical) or not P.fields(owner,{binding=P.binding,authority=true,host_session=true},{recovery_revision=true}) or owner.binding.logical_session_id~=logical then return nil,'Corrupt dispatch owner' end end
 for _,retired in ipairs(root.tombstones) do if type(retired)~='table' or not P.binding(retired.binding) or not P.integer(retired.revision,1) then return nil,'Corrupt retired owner fence' end end
 for _,fingerprint in pairs(root.request_fences) do if not P.digest(fingerprint) then return nil,'Corrupt compacted request fence' end end
 for k,entry in pairs(root.requests) do
  if type(entry)~='table' or type(entry.request)~='table' or type(entry.body)~='table' then return nil,'Corrupt retained request' end
  local request=P.decode(tern.json.encode(entry.request))
  if not request or key(request)~=k or entry.body.request_id~=request.request_id or entry.body.action_id~=request.action_id or not P.equal(entry.body.origin_binding,request.origin_binding) or not P.encode(entry.body) then return nil,'Corrupt retained outcome' end
  if entry.claim and not P.fields(entry.claim,{executor_id=P.id,boot=P.id}) then return nil,'Corrupt execution claim' end
  if entry.orch_claim and not orch_claim(entry.orch_claim) then return nil,'Corrupt ORCH+ action claim' end
  if entry.authorization and (not P.fields(entry.authorization,{nonce=P.id,boot=P.id,bridge=true,binding=true,session=true,deadline=deadline,new=true,phase=true},{base_body=true,window_executor=P.id}) or not P.integer(entry.authorization.bridge,1) or not P.integer(entry.authorization.session,0) or type(entry.authorization.new)~='boolean' or (entry.authorization.phase~='requested' and entry.authorization.phase~='consumed') or type(entry.authorization.binding)~='table' or entry.authorization.base_body and not P.encode(entry.authorization.base_body)) then return nil,'Corrupt live-action authorization' end
  if entry.wake and (not P.fields(entry.wake,{phase=true,pane_binding=P.pane},{claim=true,request_id=P.id}) or entry.wake.claim and not P.fields(entry.wake.claim,{executor_id=P.id,boot=P.id})) then return nil,'Corrupt native wake claim' end
  if entry.attachment and ((request.op~='launch' and request.op~='adopt') or not P.fields(entry.attachment,{origin_binding=P.binding,controller_pane=true,pane_binding=P.pane,request_id=P.id,revision=function(v)return P.integer(v,1)end,attestation=true}) or not same_owner(entry.attachment.origin_binding,request.origin_binding)) then return nil,'Corrupt explicit worker attachment' end
  if entry.launch and (not P.digest(entry.launch_sha256) or P.fingerprint(entry.launch)~=entry.launch_sha256 or type(entry.binding)~='table' or type(entry.observer_id)~='string') then return nil,'Corrupt immutable launch projection' end
  if entry.stop_request_id~=nil and ((request.op~='launch' and request.op~='adopt') or not P.id(entry.stop_request_id)) then return nil,'Corrupt exclusive stop fence' end
  if request.op=='adopt' and entry.pane_binding~=nil and not P.equal(entry.pane_binding,request.pane_binding) then return nil,'Corrupt adopted pane binding' end
  if request.op=='stop' and entry.body.status=='stopped' and (not entry.claim or not entry.orch_claim or not entry.stop_backend or not P.fields(entry.body.payload,{pane_binding=P.pane,observation=function(v)return v=='absent' or v=='exited'end}) or not P.equal(entry.body.payload.pane_binding,request.pane_binding)) then return nil,'Corrupt native stopped evidence' end
  if entry.stop_backend~=nil and (request.op~='stop' or (entry.stop_backend~='native-agent' and entry.stop_backend~='local-terminal' and entry.stop_backend~='ssh-command') or type(entry.binding)~='table') then return nil,'Corrupt native stop projection' end
  if entry.retirement_result~=nil and (request.op~='mailbox_retire' or request.mode~='retire' or not P.equal(entry.retirement_result,P.body(request,'retired'))) then return nil,'Corrupt retained mailbox retirement' end
 end
 for _,entry in pairs(root.requests) do
  if entry.stop_request_id then
   local r=entry.request;local stop=root.requests[r.origin_binding.logical_session_id..'/'..entry.stop_request_id]
   if not stop or stop.request.op~='stop' or stop.request.target_request_id~=r.request_id or stop.request.target_action_id~=r.action_id or not routed(entry,stop.request) or not P.equal(stop.request.pane_binding,select(3,route(entry))) or not entry.launch or stop.stop_backend~=entry.launch.backend then return nil,'Corrupt launch-to-stop fence' end
  end
 end
 for id,g in pairs(root.gates) do
  if not P.id(id) or not P.fields(g,{request=true,records=true,binding=true,boot=P.id},{consumed=true,outcome=true}) then return nil,'Corrupt migration gate' end
  local preview,records=M.import_decode(tern.json.encode(g.request),true)
  if not preview or not P.equal(records,g.records) or type(g.binding)~='table' or type(g.binding.authority_id)~='string' or type(g.binding.session_key)~='string' or g.binding.host_key~=preview.target_host then return nil,'Corrupt migration snapshot binding' end
  if g.consumed~=nil and (g.consumed~=true or type(g.outcome)~='table' or g.outcome.request_id~=preview.request_id) then return nil,'Corrupt consumed import outcome' end
 end
 return root
end
-- Read-only validation for authority migration and destructive maintenance.
-- This does not initialize, recover, rewrite, or authorize bridge state.
M.validate_registry=valid
local function authority_identity(binding)
 return binding.managed_authority_id or binding.authority_id
end
local function load()
 if hold then return nil,hold end
 local ok,root=pcall(tern.kv.get,KEY);if not ok then return nil,'Transport registry unreadable; preserve it' end
 if root==nil then
  local marked,marker=pcall(tern.kv.get,KEY..'-initialized')
  if not marked or marker~=nil then return nil,'Transport registry missing after initialization; restore it' end
  root={version=1,revision=0,namespace=string.format('dispatch-%d-%08x',os.time(),math.random(1,2147483647)),next_id=1,owners={},tombstones={},request_fences={},requests={},mailboxes=Mailbox.empty(),gates={}}
  local saved,err=save(root,false);if not saved then return nil,err end
  local stamped=pcall(tern.kv.set,KEY..'-initialized',root.namespace);if not stamped then hold='Initialization marker failed; effects held';return nil,hold end
 end
 local checked,why=valid(root);if not checked then return nil,why end
 root=P.clone(root)
 if not loaded then
  local changed=false
  for _,entry in pairs(root.requests) do
   fence_unstarted_wake(root,entry)
   if entry.request.op=='stop' and entry.body.status=='resolved' then
    entry.body=P.body(entry.request,'uncertain',nil,{code='target_unavailable',message='Host reload invalidated the native stop authorization; retain ownership'})
   end
   if entry.body.status=='claimed' or entry.body.status=='launching' or entry.body.status=='resolved' and entry.attempt_pending then
    entry.body.status='uncertain';entry.body.error={code='target_unavailable',message='Host reload interrupted a claimed launch; inspect the recorded executor, never replay'};changed=true
   end
   if entry.body.status=='pending' and entry.request.op:sub(1,8)=='mailbox_' and not entry.authorization then
    entry.body=P.body(entry.request,'uncertain',nil,{code='target_unavailable',message='Transport callback was lost; exact request replay performs bounded readback, never blind write retry'})
   end
   if entry.wake and (entry.wake.phase=='claimed' or entry.wake.phase=='launching') then
    entry.wake.phase='uncertain'
    entry.body.payload=entry.body.payload or {};entry.body.payload.wake_status='uncertain'
    entry.body.payload.wake_effect_started=true
   end
   if entry.authorization and entry.authorization.phase=='consumed' then
    entry.body=P.body(entry.request,'uncertain',nil,{code='target_unavailable',message='Host reload interrupted an authorized operation; retain the consumed grant and inspect its outcome'})
   end
  end
  for _,entry in pairs(root.requests) do
   if entry.wake and entry.wake.request_id then
    local native=root.requests[entry.request.origin_binding.logical_session_id..'/'..entry.wake.request_id]
    if native and native.body.status=='uncertain' then entry.wake.phase='uncertain';entry.body.payload=entry.body.payload or {};entry.body.payload.wake_status='uncertain';entry.body.payload.wake_effect_started=true end
   end
   if entry.wake and (entry.body.status=='published' or entry.body.status=='already_published') then
    entry.body.payload=entry.body.payload or {}
    entry.body.payload.wake_status=if entry.wake.phase=='resolved' then 'awaiting_window' else entry.wake.phase
    entry.body.payload.wake_effect_started=entry.wake.phase~='resolved'
    entry.body.payload.wake_target_request_id=entry.request.request_id
    entry.body.payload.wake_target_action_id=entry.request.action_id
   end
  end
  root.mailboxes=Mailbox.recover(root.mailboxes)
  for id,g in pairs(root.gates) do if not g.consumed then root.gates[id]=nil;changed=true end end
  -- Recovery also preserves mailbox operation uncertainty and generation claims.
  local persisted,err=save(root,true);if not persisted then return nil,err end
  loaded=true
 end
 return root
end
local function allocate(root,prefix)
 if root.next_id>=9007199254740991 then return nil end
 local id=prefix..'-'..Codec.sha256(root.namespace..':'..tostring(root.next_id)):sub(1,40)
 root.next_id+=1;return id
end
local function identity(record)
 return {backend=record.backend,provider=record.provider,account_label=record.account_label,identity_status='configured_not_verified',model=record.model,profile=record.profile,variant_id=record.variant_id,capacity_binding=record.capacity_binding,capacity_limit=record.capacity_limit}
end
local function capability(record,snapshot)
 local c=Backend.eligibility(record)
 local reasons={}
 if record.backend=='ssh-command' then table.insert(reasons,'SSH-hop workers are not managed here; run ORCH+ on target host with its same-host SPAWN records') end
 if not c.fresh or not c.input or not c.target then table.insert(reasons,'Explicit fresh launch, target shell and initial input contract required') end
 local caps,why=Capabilities.validate(record)
 if not caps then caps={};table.insert(reasons,why) end
 if not record.enabled or record.review_required then table.insert(reasons,'Record disabled or awaiting owner review') end
 if not P.text(record.cwd,2048,false) then table.insert(reasons,'Managed work requires an explicit configured cwd of at most 2048 UTF-8 bytes') end
 if record.backend~='native-agent' and record.placement=='replace_if_alone' then table.insert(reasons,'Managed terminal replacement placement is unsupported; configure tab or split') end
 if snapshot then
  local shell=Backend.shell_kind(snapshot.host_os,snapshot.host_shell)
  if not shell or record.backend=='native-agent' and shell~='posix' then table.insert(reasons,'Native launch is unsupported on this execution-host shell') end
  if record.backend~='ssh-command' and record.user and shell~='posix' then table.insert(reasons,'OS-user isolation is unsupported on this execution host') end
  if record.backend~='ssh-command' and record.host and string.lower(record.host)~='local' and 'host:'..string.lower(record.host)~=snapshot.host_key then table.insert(reasons,'Configured execution host differs from canonical host authority') end
 end
 return #reasons==0,caps,reasons
end
local function catalog(r,snapshot)
 local cursor=r.cursor
 if cursor and cursor.revision~=snapshot.config_revision then return P.reject(r,'binding_mismatch','Catalog revision changed; select again') end
 local records={};local first=if cursor then cursor.index else 1
 if first>#snapshot.records+1 then return P.reject(r,'invalid_schema','Invalid catalog cursor') end
 local payload={revision=snapshot.config_revision,config_revision=snapshot.config_revision,namespace=snapshot.namespace,host_key=snapshot.host_key,records=records}
 for index=first,#snapshot.records do
  local record=snapshot.records[index];local eligible,caps,reasons=capability(record,snapshot)
  local row={id=record.id,revision=snapshot.config_revision,provider=record.provider,account_label=record.account_label,backend=record.backend,enabled=record.enabled,eligible=eligible,capabilities=caps,unsupported=reasons,capability_evidence='configured_operator_attestation_not_runtime_proof',effective_identity=identity(record),cwd=record.cwd,placement=record.placement,model_variant=record.model,profile_variant=record.profile,selector_evidence=record.selector_evidence,capacity_binding=record.capacity_binding}
  table.insert(records,row)
  payload.next_cursor=if index<#snapshot.records then {revision=snapshot.config_revision,index=index+1} else nil
  local body=P.body(r,'catalog',payload)
  if not P.encode(body) then
   table.remove(records)
   if #records==0 then return P.reject(r,'oversize','A catalog record cannot fit the public bridge') end
   payload.next_cursor={revision=snapshot.config_revision,index=index};break
  end
 end
 return P.body(r,'catalog',payload)
end
local function owner(root,r,binding,session,reserve)
 local id=r.origin_binding.logical_session_id;local prior=root.owners[id]
 if prior then
  if (r.op=='status' or r.op=='attach_worker' and not prior.recovery_revision) and prior.authority==authority_identity(binding) and prior.host_session==session and same_owner(prior.binding,r.origin_binding) then return true end
  if prior.authority~=authority_identity(binding) or prior.host_session~=session or not P.equal(prior.binding,r.origin_binding) then return false,'Occupied SPAWN controller binding; inspect Config and recover the prior owner explicitly' end
  if prior.recovery_revision and r.op~='status' then return false,'Controller recovery is fenced; inspect and finish the explicit owner recovery' end
 else
  if r.op=='attach_worker' then
   local target=root.requests[id..'/'..r.target_request_id]
   local retired=retired_executor(root,if target then select(1,route(target)) else r.previous_origin_binding)
   if not retired or retired.authority~=authority_identity(binding) or retired.host_session~=session or not same_owner(retired.binding,r.origin_binding) or P.equal(retired.binding,r.origin_binding) then return false,'Explicit prior executor recovery is required before attaching this worker' end
   return true
  end
  for _,retired in ipairs(root.tombstones) do
   if retired.binding.logical_session_id==id and P.equal(retired.binding,r.origin_binding) then
    if r.op=='status' and reserve==false then return true end
    return false,'Retired controller binding cannot regain dispatch authority'
   end
  end
  if reserve~=false then root.owners[id]={binding=P.clone(r.origin_binding),authority=authority_identity(binding),host_session=session} end
 end
 return true
end
-- Read-only owner admission view for ORCH+'s guided reload recovery. It reserves no ownership,
-- fences nothing and exposes no binding, nonce or path; recovery itself stays the explicit,
-- operator-attested SPAWN Config fence/confirm (recover_owner).
local function owner_state(root,r,binding,session)
 local id=r.origin_binding.logical_session_id;local prior=root.owners[id]
 if not prior then
  for _,retired in ipairs(root.tombstones) do
   if retired.binding.logical_session_id==id and P.equal(retired.binding,r.origin_binding) then return 'retired' end
  end
  return 'none'
 end
 if prior.authority~=authority_identity(binding) or prior.host_session~=session then return 'other_authority' end
 if prior.recovery_revision then return 'fenced' end
 if P.equal(prior.binding,r.origin_binding) then return 'current' end
 return if same_owner(prior.binding,r.origin_binding) then 'previous_incarnation' else 'other_owner'
end
local function find_record(snapshot,id,revision)
 if not snapshot.ready or snapshot.config_revision~=revision then return nil,'Configuration changed or awaits review' end
 for _,r in ipairs(snapshot.records) do if r.id==id then return r end end
 return nil,'Configured record does not exist'
end
local function finish(root,entry,body,control)
 if not P.encode(body) then body=P.reject(entry.request,'oversize','Encoded operation result exceeds the bridge bound; retained transport evidence requires inspection') end
 entry.body=body
 local ok,why=save(root,control)
 return if ok then body else P.reject(entry.request,'storage_error',why)
end
local function launch_payload(entry)
 local r=entry.request
 return {record_id=r.record_id,record_revision=r.record_revision,effective_identity=entry.identity,capabilities=entry.capabilities,pane_binding=entry.pane_binding,prompt_delivery=if entry.pane_binding then 'submitted_not_accepted' else 'not_submitted'}
end
-- Shared by fresh launch and explicit adoption: the validated record/mailbox enrolment and the exact
-- private transport preface followed by the unchanged assignment bytes. Failure returns nil,code,message.
local function enrolment_brief(root,r,snapshot)
 local record,why=find_record(snapshot,r.record_id,r.record_revision)
 if not record then return nil,'binding_mismatch',why end
 local eligible,caps,reasons=capability(record,snapshot)
 if not eligible then return nil,'unsupported_capability',table.concat(reasons,'; ') end
 if r.op=='launch' and (r.cwd~=record.cwd or r.placement~=record.placement) then return nil,'binding_mismatch','Requested cwd/placement is not the configured allowance' end
 if r.op=='adopt' and record.backend~='native-agent' then return nil,'unsupported_capability','Adoption delivers the assignment by native ask; only native-agent records can enrol an existing agent pane' end
 if Codec.sha256(r.prompt)~=r.enrolment.assignment_sha256 then return nil,'content_conflict','Assignment digest differs from literal assignment bytes' end
 local box=Mailbox.get(root.mailboxes,r.mailbox_handle)
 if box and box.backend=='ssh-command' then return nil,'unsupported_capability','Retained SSH mailbox cannot launch workers here; run ORCH+ on target host' end
 if not box or box.phase~='provisioned' or box.record_id~=r.record_id or box.record_revision~=r.record_revision then return nil,'binding_mismatch','Mailbox is not provisioned for this record revision' end
 local expected={logical_session_id=r.origin_binding.logical_session_id,worker_id=r.enrolment.worker_id,worker_generation=r.enrolment.worker_generation,launch_request_id=r.request_id,work_id=r.work_id,enrolment_token=r.enrolment.enrolment_token}
 if not P.equal(box.binding,expected) then return nil,'binding_mismatch','Mailbox enrolment differs from immutable launch' end
 if not P.equal(box.capabilities,caps) then return nil,'binding_mismatch','Provisioned capabilities differ from the configured launch contract' end
 local e=r.enrolment
 local handover=if e.handover_id then {handover_id=e.handover_id,handover_sha256=Codec.sha256(e.handover_id..':'..e.handover_token)} else nil
 if not P.equal(box.handover,handover) then return nil,'binding_mismatch','Provisioned handover digest differs from the immutable launch handover pair' end
 if r.enrolment.coordinator_owner_id and not table.find(caps,'coordinator-control-v1') then return nil,'unsupported_capability','Coordinator launch requires explicitly configured and provisioned coordinator-control-v1' end
 local location=Mailbox.location(root.mailboxes,r.mailbox_handle)
 local brief='Literal assignment follows: SHA-256 covers ONLY its exact '..tostring(#r.prompt)..' UTF-8 bytes, excluding this transport preface.\n'
  ..'report-files-v1: '..tern.json.encode({mailbox_handle=r.mailbox_handle,binding=expected,root=location.root,producer_helper=location.producer_helper,assignment_sha256=r.enrolment.assignment_sha256,handover_id=r.enrolment.handover_id,handover_token=r.enrolment.handover_token,capabilities=caps})..'\n'
  ..'Helper argv: POSIX sh,producer_helper,root,mailbox_handle,enrolment_token,mode; Windows powershell.exe -NoProfile -File producer_helper -Root: root -Handle: mailbox_handle -Owner: enrolment_token -Mode: mode. Each colon-ended name and its literal value are separate argv elements. init only new journals; replay restores. report reads {kind,payload,action_id?,action_revision?,handover_id?,handover_token?} stdin; supplies BE/seq/event_id. Emit ACCEPTED {assignment_sha256}, with paired handover only if supplied. Copy handover_id and handover_token verbatim from the report-files-v1 JSON above; never retype them. The helper verifies them against the provisioned handover digest and refuses a mismatch before publishing, naming the field; then report ACCEPTED again with the exact values. Check receipts/consume at checkpoints. With native-ask-v1, end the initial turn immediately after ACCEPTED and return idle before awaiting ACK/control; native notifications require idle. On notifications drain available receipts/replies, then return idle when awaiting more control; never keep the turn open polling or calling wait for another notification. Only worker-poll-v1 uses bounded wait while awaiting control. reply_ack precedes effects; claim/resolve retain uncertainty. Never reset or retry uncertain effects.\n'
 if r.enrolment.coordinator_owner_id then
  brief..='COORDINATOR TRANSPORT ROLE: '..tern.json.encode({owner_id=r.enrolment.coordinator_owner_id,owner_generation=r.enrolment.coordinator_generation})..'\n'
   ..'Acknowledge the exact assignment bytes with ACCEPTED first, but do not perform coordinator work yet. Await control using the enrolled transport rule above, then drain receipts and consume the typed coordinator_activation reply for this exact owner/generation. The consumer durably records reply_ack before returning it; claim that exact reply before coordinator work. Retain its action ID/revision and activation token. Never independently orchestrate Tern. When the assigned task finishes or typed retirement requests stop, quiesce and report COORDINATOR_RELEASE with that owner/generation/token, quiescent:true and the activation (or issued retirement) action ID/revision. Idle alone is not task completion. Continue draining committed replies and receipts, including a delayed coordinator_retirement, without starting fresh work; native stop and mailbox retirement belong to ORCH+/SPAWN. The role and token are protocol fencing, not OS/account isolation.\n'
   ..'Before final retirement, resolve each claimed control message through the helper once its work is actually quiescent; keep the grant IDs/token in your working context. Drain all final report receipts and committed reply acknowledgements. Unclaimed, claimed or uncertain execution journal entries prevent mailbox retirement and must never be erased or falsely marked resolved. SPAWN clears only the exact settled producer journal after observing native stop.\n'
 end
 brief..='ASSIGNMENT_BYTES_BEGIN\n'..r.prompt
 return record,caps,brief
end
local function launch_prepare(root,entry,binding,snapshot)
 local r=entry.request
 local record,caps,brief=enrolment_brief(root,r,snapshot)
 if not record then return finish(root,entry,P.reject(r,caps,brief),false) end
 local built,build_error=Backend.build(record,snapshot,{fresh=true,prompt=brief,cwd=r.cwd,placement=r.placement})
 if not built then return finish(root,entry,P.reject(r,'unsupported_capability',build_error),false) end
 entry.launch=built;entry.identity=identity(record);entry.capabilities=caps;entry.binding=P.clone(binding)
 entry.launch_sha256=P.fingerprint(built)
 entry.observer_id='managed-'..Codec.sha256(key(r));entry.attempt_pending=true
 local persisted,persist_error=save(root,false)
 if not persisted then return P.reject(r,'storage_error',persist_error) end
 local attempt,attempt_error=Authority.managed_reserve(binding,r.record_revision,r.record_id,entry.observer_id)
 if not attempt then entry.attempt_pending=nil;return finish(root,entry,P.reject(r,'target_unavailable',attempt_error),false) end
 entry.attempt_id=attempt.id;entry.attempt_pending=nil
 return finish(root,entry,P.body(r,'resolved',launch_payload(entry)),false)
end
-- Explicit verified attach: never starts an agent. The exact owner-attested idle native agent pane
-- receives the same preface and assignment once through native ask (see dispatch_window).
local function adopt_prepare(root,entry,binding,snapshot)
 local r=entry.request;local p,b=r.pane_binding,r.origin_binding
 if p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id then
  return finish(root,entry,P.reject(r,'binding_mismatch','Adopted pane must belong to the exact controller window, native session and host'),false)
 end
 for _,other in pairs(root.requests) do
  if other~=entry and launched(other) and other.request.origin_binding.logical_session_id==b.logical_session_id and other.body.status~='rejected' then
   local stop=if other.stop_request_id then root.requests[b.logical_session_id..'/'..other.stop_request_id] else nil
   local bound=select(3,route(other)) or (if other.request.op=='adopt' then other.request.pane_binding else nil)
   if bound and P.equal(bound,p) and not (stop and stop.body.status=='stopped') then
    return finish(root,entry,P.reject(r,'binding_mismatch','This exact pane is already bound to a managed worker generation; it is never adopted twice'),false)
   end
  end
 end
 local record,caps,brief=enrolment_brief(root,r,snapshot)
 if not record then return finish(root,entry,P.reject(r,caps,brief),false) end
 entry.launch={backend='native-agent',adopt=true,prompt=brief};entry.launch_sha256=P.fingerprint(entry.launch)
 entry.identity=identity(record);entry.capabilities=caps;entry.binding=P.clone(binding)
 entry.observer_id='managed-'..Codec.sha256(key(r))
 return finish(root,entry,P.body(r,'resolved',launch_payload(entry)),false)
end
local function accept(root,entry)
 local r=entry.request;local target=root.requests[r.origin_binding.logical_session_id..'/'..r.target_request_id]
 if not launched(target) then return finish(root,entry,P.reject(r,'binding_mismatch','Launch request not found'),true) end
 local t=target.request;local e=t.enrolment
 if not routed(target,r) or t.action_id~=r.target_action_id or not P.equal(select(3,route(target)),r.pane_binding) or e.worker_id~=r.worker_id or e.worker_generation~=r.worker_generation or e.enrolment_token~=r.enrolment_token or t.work_id~=r.work_id or e.handover_id~=r.handover_id or e.handover_token~=r.handover_token then return finish(root,entry,P.reject(r,'binding_mismatch','Acceptance differs from launch contract'),true) end
 if r.event_id~=Codec.sha256(t.mailbox_handle..':report:'..string.format('%.0f',r.seq)) then return finish(root,entry,P.reject(r,'binding_mismatch','Acceptance event ID differs from its mailbox sequence'),true) end
 local receipt={event_id=r.event_id,seq=r.seq,event_sha256=r.event_sha256}
 if target.acceptance and not P.equal(target.acceptance,receipt) then return finish(root,entry,P.reject(r,'content_conflict','Acceptance event changed'),true) end
 if target.body.status~='awaiting_acceptance' and target.body.status~='accepted' then return finish(root,entry,P.reject(r,'binding_mismatch','Launch has no confirmed pane association'),true) end
 target.acceptance=receipt;target.body=P.body(t,'accepted',launch_payload(target))
 return finish(root,entry,P.body(r,'accepted',{target_request_id=t.request_id,pane_binding=target.pane_binding}),true)
end
local function stop_target(root,r)
 local target=root.requests[r.origin_binding.logical_session_id..'/'..r.target_request_id]
 if not launched(target) or target.body.status~='accepted' or not target.acceptance or not target.launch then return nil end
 local t=target.request;local e=t.enrolment;local p=r.pane_binding;local b=r.origin_binding
 if not routed(target,r) or t.action_id~=r.target_action_id or not P.equal(select(3,route(target)),p) or e.worker_id~=r.worker_id or e.worker_generation~=r.worker_generation or e.enrolment_token~=r.enrolment_token or t.work_id~=r.work_id then return nil end
 if p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id then return nil end
 return target
end
local function stop_prepare(root,entry)
 local r=entry.request;local target=stop_target(root,r)
 if not target then return finish(root,entry,P.reject(r,'binding_mismatch','Stop differs from the exact accepted managed launch'),true) end
 if target.stop_request_id and target.stop_request_id~=r.request_id then return finish(root,entry,P.reject(r,'binding_mismatch','This launch already has an exclusive stop intent; reconcile that request, never repeat stop'),true) end
 if target.request.enrolment.coordinator_owner_id and not table.find(target.capabilities or {},'coordinator-control-v1') then return finish(root,entry,P.reject(r,'unsupported_capability','The issued coordinator launch did not provision coordinator-control-v1'),true) end
 for _,other in pairs(root.requests) do
  if other.wake and other.request.launch_request_id==r.target_request_id and other.request.origin_binding.logical_session_id==r.origin_binding.logical_session_id and other.wake.phase~='submitted' then return finish(root,entry,P.reject(r,'target_unavailable','Native wake notification remains unresolved; drain it before stop'),true) end
 end
 target.stop_request_id=r.request_id
 entry.binding=P.clone(target.binding);entry.stop_backend=target.launch.backend
 return finish(root,entry,P.body(r,'resolved'),true)
end
local function retire_launch(root,entry)
 local r=entry.request
 local launch=root.requests[r.origin_binding.logical_session_id..'/'..r.launch_request_id]
 local stop=if launch and launch.stop_request_id then root.requests[r.origin_binding.logical_session_id..'/'..launch.stop_request_id] else nil
 if not stop or stop.body.status~='stopped' or stop_target(root,stop.request)~=launch then return nil,'Exact native stop evidence is missing' end
 local t=launch.request;local e=t.enrolment
 if t.mailbox_handle~=r.handle or not routed(launch,r) or t.work_id~=r.work_id or e.worker_id~=r.worker_id or e.worker_generation~=r.worker_generation or e.worker_generation~=r.expected_generation or e.enrolment_token~=r.enrolment_token then return nil,'Mailbox retirement differs from the stopped launch' end
 return launch
end
local function settle_reservation(root,entry)
 local launch,why=retire_launch(root,entry)
 if not launch then return finish(root,entry,P.body(entry.request,'uncertain',nil,{code='binding_mismatch',message=why}),true) end
 -- Adoption reserved no managed launch attempt; a fresh launch settles its exact reservation.
 if launch.request.op~='adopt' then
  local ok,err=Authority.managed_retire(launch.binding,launch.attempt_id,launch.observer_id,launch.request.record_id,tonumber(launch.pane_binding.pane_id))
  if not ok then return finish(root,entry,P.body(entry.request,'uncertain',nil,{code='storage_error',message=tostring(err):sub(1,512)}),true) end
 end
 local body=entry.retirement_result;entry.retirement_result=nil
 return finish(root,entry,body,true)
end
local function attach_worker(root,entry,binding,session)
 local r=entry.request
 local target=root.requests[r.origin_binding.logical_session_id..'/'..r.target_request_id]
 if not launched(target) or not target.pane_binding or target.stop_request_id or (target.body.status~='accepted' and target.body.status~='awaiting_acceptance') then return finish(root,entry,P.reject(r,'binding_mismatch','Attachment requires the retained launched worker without a stop intent'),true) end
 local t=target.request;local e=t.enrolment;local p=r.pane_binding;local b=r.origin_binding
 if not same_owner(t.origin_binding,b) or not P.equal(t.origin_binding,r.previous_origin_binding) or not P.equal(target.pane_binding,r.previous_pane_binding) or t.action_id~=r.target_action_id or t.work_id~=r.work_id or e.worker_id~=r.worker_id or e.worker_generation~=r.worker_generation or e.enrolment_token~=r.enrolment_token or p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id then return finish(root,entry,P.reject(r,'binding_mismatch','Attachment differs from immutable launch or explicitly selected current pane'),true) end
 for _,other in pairs(root.requests) do
  if other~=entry and other.request.origin_binding.logical_session_id==b.logical_session_id and outstanding(other) and not retired_executor(root,executor_origin(root,other)) then return finish(root,entry,P.reject(r,'target_unavailable','Inspect original outcomes, then fence and confirm stopped executors in SPAWN Config before attachment; unknown outcomes are not retried'),true) end
 end
 -- Revoke old unconsumed challenges. Never transfer an earlier effect claim.
 for _,other in pairs(root.requests) do
  if other~=entry and other.request.origin_binding.logical_session_id==b.logical_session_id and not P.equal(other.request.origin_binding,b) then fence_unstarted_wake(root,other) end
  if other~=entry and other.request.origin_binding.logical_session_id==b.logical_session_id and not P.equal(other.request.origin_binding,b) and other.authorization then
   local a=other.authorization
   other.authorization_fence={nonce=a.nonce,phase=a.phase,bridge=a.bridge,executor=a.window_executor}
   other.authorization=nil
   other.body=if a.phase=='requested' then (a.base_body or P.reject(other.request,'authorization_revoked','Explicit attachment fenced the old window challenge')) else P.body(other.request,'uncertain')
  end
 end
 target.attachment={origin_binding=P.clone(b),controller_pane=r.controller_pane,pane_binding=P.clone(p),request_id=r.request_id,revision=root.revision+1,attestation=r.attestation}
 root.owners[b.logical_session_id]={binding=P.clone(b),authority=authority_identity(binding),host_session=session}
 return finish(root,entry,P.body(r,'attached',{pane_binding=P.clone(p),previous_origin_binding=P.clone(r.previous_origin_binding),previous_pane_binding=P.clone(r.previous_pane_binding)}),true)
end
local function transport_body(r,result)
 local payload=result.payload
 if result.status=='full' and not payload then payload={resource=result.resource,current=result.current,limit=result.limit} end
 if result.status=='gap' and not payload then payload={expected_seq=result.expected_seq} end
 return P.body(r,result.status,payload,result.error)
end
local function wake_launch(root,r)
 if r.op~='mailbox_publish_ack' and (r.op~='mailbox_publish_reply' or r.part~='manifest') then return nil end
 local launch=root.requests[r.origin_binding.logical_session_id..'/'..r.launch_request_id]
 local route=Mailbox.location(root.mailboxes,r.handle)
 if not launch or launch.stop_request_id or not launched(launch) or not launch.pane_binding or not launch.launch or launch.launch.backend~='native-agent' or not route or route.wake~='native-ask-v1' then return nil end
 if launch.body.status~='accepted' and not (r.op=='mailbox_publish_ack' and launch.body.status=='awaiting_acceptance') then return nil end
 local t=launch.request;local e=t.enrolment
 if not routed(launch,r) or t.mailbox_handle~=r.handle or t.work_id~=r.work_id or e.worker_id~=r.worker_id or e.worker_generation~=r.worker_generation or e.worker_generation~=r.expected_generation or e.enrolment_token~=r.enrolment_token then return nil end
 return launch
end
local function publication_wake(root,entry,body)
 if body.status~='published' and body.status~='already_published' then return body end
 local canonical=entry
 for _,other in pairs(root.requests) do
  local a,b=other.request,entry.request
  if other.wake and a.handle==b.handle and a.op==b.op and ((a.op=='mailbox_publish_ack' and a.ack_sha256==b.ack_sha256) or (a.op=='mailbox_publish_reply' and a.reply_seq==b.reply_seq and a.reply_sha256==b.reply_sha256 and a.part=='manifest')) then canonical=other;break end
 end
 if not canonical.wake then
  local launch=wake_launch(root,entry.request)
  if launch then canonical.wake={phase='resolved',pane_binding=P.clone(select(3,route(launch)))} end
 end
 if canonical.wake then
  body.payload=body.payload or {}
  body.payload.wake_status=if canonical.wake.phase=='resolved' then 'awaiting_window' else canonical.wake.phase
  body.payload.wake_effect_started=canonical.wake.phase~='resolved'
  body.payload.wake_target_request_id=canonical.request.request_id
  body.payload.wake_target_action_id=canonical.request.action_id
 end
 return body
end
local function wake_target(root,r)
 if r.op~='native_wake' then return nil end
 local target=root.requests[r.origin_binding.logical_session_id..'/'..r.target_request_id]
 if not target or not target.wake or target.request.action_id~=r.target_action_id or (target.body.status~='published' and target.body.status~='already_published') then return nil end
 local launch=root.requests[r.origin_binding.logical_session_id..'/'..target.request.launch_request_id]
 if not launch or launch.stop_request_id or not routed(launch,r) then return nil end
 if not launch.attachment and not P.equal(target.wake.pane_binding,launch.pane_binding) then return nil end
 return target,launch
end
local function prepare_wake(root,entry)
 local r=entry.request;local target,launch=wake_target(root,r)
 if not target then return finish(root,entry,P.reject(r,'binding_mismatch','Wake requires the exact retained durable native publication and current attached worker'),true) end
 local w=target.wake
 if w.request_id and w.request_id~=r.request_id then return finish(root,entry,P.reject(r,'binding_mismatch','Notification already owns a wake request; reconcile that exact request'),true) end
 if w.phase=='submitted' then return finish(root,entry,P.body(r,'submitted'),true) end
 if w.phase~='resolved' or w.claim then return finish(root,entry,P.reject(r,'target_unavailable','Earlier wake may have started; never grant another notification'),true) end
 local wakes,same=wake_occupancy(root,target.request.handle)
 local transports,same_transport=transport_occupancy(root,target.request.handle)
 if same>0 or same_transport>0 or wakes+transports>=4 then return finish(root,entry,P.body(r,'full',{resource='native_wake_operations',current=if same+same_transport>0 then same+same_transport else wakes+transports,limit=if same+same_transport>0 then 1 else 4,retryable=true,effect_started=false}),true) end
 w.request_id=r.request_id;w.pane_binding=P.clone(select(3,route(launch)))
 return finish(root,entry,P.body(r,'resolved',{wake_status='awaiting_window',wake_effect_started=false}),true)
end
-- A requested challenge is consumable only on this host VM before its deadline: M.authorize
-- refuses an expired or earlier-VM nonce. Expiry is registry time alone; it never depends on the
-- requesting window or bridge still existing.
local function live_challenge(a)
 return a~=nil and a.phase=='requested' and a.boot==boot and a.deadline>=tern.now()
end
-- A launch-family request never reached native execution in two cases, so its never-used mailbox
-- may retire without a native stop (contract C2; ORCH+ `dispatch/withdraw_fenced` is the other side):
-- 1. SPAWN rejected it: every stored launch or adoption rejection precedes the native call (an
--    adoption `refused` result precedes its ask).
-- 2. It was only staged: no execution or ORCH+ claim was ever recorded and its requested challenge
--    expired or belongs to an earlier host VM, so it can never be consumed. The accepting
--    retirement fences it (see `mailbox`), turning it into case 1 before M.stage can re-nonce it.
-- Neither case bound a pane or ran a producer.
local function unexecuted_launch(entry)
 if not launched(entry) or entry.pane_binding~=nil or entry.attachment~=nil or entry.stop_request_id~=nil or entry.acceptance~=nil then return false end
 if entry.body.status=='rejected' then return true end
 local a=entry.authorization
 return entry.claim==nil and entry.orch_claim==nil and a~=nil and a.phase=='requested' and not live_challenge(a)
end
local function mailbox(root,entry,snapshot,changed)
 local r=entry.request;local record=nil
 if entry.retirement_result then return settle_reservation(root,entry) end
 local launched=root.requests[r.origin_binding.logical_session_id..'/'..tostring(r.launch_request_id)]
 -- Retiring the unused mailbox of a rejected launch binds to no pane, so it needs no attachment.
 local unused=r.op=='mailbox_retire' and r.mode=='retire' and unexecuted_launch(launched)
 if launched and (launched.request.op=='launch' or launched.request.op=='adopt') and not routed(launched,r) and not unused then return finish(root,entry,P.reject(r,'binding_mismatch','Worker requires explicit attachment to this controller window'),true) end
 for _,other in pairs(root.requests) do
  if other~=entry and r.handle and other.request.handle==r.handle and other.body.status=='uncertain' and retired_executor(root,other.request.origin_binding) then return finish(root,entry,P.reject(r,'target_unavailable','Stopped executor outcome remains unknown for this generation; inspect its original immutable request'),true) end
 end
 local wakes,same=wake_occupancy(root,r.handle)
 local transports=transport_occupancy(root,r.handle)
 if same>0 or wakes+transports>=4 and not entry.operation then
  if entry.operation then return finish(root,entry,P.body(r,'uncertain'),true) end
  return finish(root,entry,P.body(r,'full',{resource='native_wake_operations',current=if same>0 then same else wakes+transports,limit=if same>0 then 1 else 4,retryable=true,effect_started=false}),true)
 end
 if wake_launch(root,r) then
  local count,duplicate=0,false
  for _,other in pairs(root.requests) do
   local q=other.request
   if other.wake and q.handle==r.handle then
    if other.wake.phase~='submitted' then count+=1 end
    if q.op==r.op and (r.op=='mailbox_publish_ack' and q.ack_sha256==r.ack_sha256 or r.op=='mailbox_publish_reply' and q.reply_sha256==r.reply_sha256 and q.reply_seq==r.reply_seq) then duplicate=true end
   end
  end
  if count>=32 and not duplicate and not entry.operation then return finish(root,entry,P.body(r,'full',{resource='wake_obligations',current=count,limit=32,retryable=true,effect_started=false}),true) end
 end
 if r.op=='mailbox_retire' and r.mode=='retire' then
  local issued=root.requests[r.origin_binding.logical_session_id..'/'..r.launch_request_id]
  if issued and not unused then
   local target,why=retire_launch(root,entry)
   if not target then return finish(root,entry,P.reject(r,'binding_mismatch',why),true) end
  elseif issued and unused and issued.authorization and issued.body.status~='rejected' then
   -- Fence the never-consumable challenge in this same save so the launch is terminal-rejected
   -- and M.stage can never re-nonce and authorize it while its mailbox retires.
   local a=issued.authorization
   issued.authorization_fence={nonce=a.nonce,phase=a.phase,bridge=a.bridge,executor=a.window_executor}
   issued.authorization=nil
   issued.body=P.reject(issued.request,'authorization_revoked','Unused mailbox retirement fenced the unconsumed launch challenge')
  end
 end
 if r.op=='mailbox_provision' then
  local err;record,err=find_record(snapshot,r.record_id,r.record_revision)
  if not record then return finish(root,entry,P.reject(r,'binding_mismatch',err),false) end
  if not entry.operation then
   local eligible,_,reasons=capability(record,snapshot)
   if not eligible then return finish(root,entry,P.reject(r,'unsupported_capability',table.concat(reasons,'; ')),false) end
  end
  -- Refuse an enrolment whose fixed binding cannot carry a maximum chunk page.
  -- Check actual escaped outer JSON, not a decoded-size estimate.
  local probe=P.clone(r);probe.op='mailbox_read';probe.request_id=string.rep('x',96);probe.action_id=string.rep('x',96)
  local selector={stream='report',slot=9007199254740991,part='chunk',index=32}
  local page={object_b64=string.rep('A',5464),object_sha256=string.rep('a',64),object_bytes=4096,selector=selector,complete=true,next_selector=selector}
  if not P.encode(P.body(probe,'read',page)) then return finish(root,entry,P.reject(r,'oversize','Origin binding cannot carry bounded mailbox chunk pages; shorten opaque binding metadata before provisioning'),false) end
 end
 local operation_id=allocate(root,'op');local handle=if r.op=='mailbox_provision' then allocate(root,'mailbox') else nil
 if not operation_id then return finish(root,entry,P.reject(r,'storage_error','Operation counter exhausted'),true) end
 local settlement=nil
 if r.op=='mailbox_retire' then settlement=P.clone(r);settlement.settled=r.mode=='retire' end
 local op,next_registry,result=Mailbox.prepare(root.mailboxes,r,record,{operation_id=operation_id,handle=handle,host_os=snapshot.host_os,host_shell=snapshot.host_shell,settlement=settlement})
 if not op then
  local body=transport_body(r,result)
  if entry.operation and entry.body.status=='uncertain' and (result.status=='full' or result.status=='incomplete' or result.status=='missing') then
   body.status='uncertain';body.error={code='target_unavailable',message='Reconciliation is inconclusive; the original operation remains uncertain'}
  end
  if result.status=='full' and not entry.operation then
   body.payload=body.payload or {};body.payload.retryable=true;body.payload.effect_started=false
  end
  return finish(root,entry,publication_wake(root,entry,body),true)
 end
 local issued=root.requests[r.origin_binding.logical_session_id..'/'..r.launch_request_id]
 if issued and (issued.request.op=='launch' or issued.request.op=='adopt') then
  local enrolment=issued.request.enrolment
  op.binding.assignment_sha256=enrolment.assignment_sha256
  op.binding.handover_id=enrolment.handover_id;op.binding.handover_token=enrolment.handover_token
  op.binding.capabilities=P.clone(issued.capabilities)
 elseif r.op=='mailbox_read' and r.selector.stream=='report' then
  return finish(root,entry,P.reject(r,'binding_mismatch','Report reads require the issued immutable launch contract'),true)
 end
 -- Only a matching durable native stop authorizes private producer cleanup.
 -- Ordinary retirement/compaction retains the existing empty-journal contract.
 if r.op=='mailbox_retire' and r.mode=='retire' and issued and issued.stop_request_id then
  local stopped,why=retire_launch(root,entry)
  if not stopped then return finish(root,entry,P.reject(r,'binding_mismatch',why),true) end
  op.retire_producer=true
 end
 root.mailboxes=next_registry;entry.operation=op.id or operation_id
 entry.body=P.body(r,'pending',{operation_id=operation_id})
 local stored,why=save(root,r.op~='mailbox_provision')
 if not stored then return P.reject(r,'storage_error',why) end
 Mailbox.execute(op,function(outcome)
  local latest,load_error=load();if not latest then changed(P.reject(r,'storage_error',load_error));return end
  local current=latest.requests[key(r)]
  if not current or current.operation~=entry.operation or not P.equal(current.request,r) then return end
  local current_owner=latest.owners[r.origin_binding.logical_session_id]
  if not current_owner or current_owner.recovery_revision or not P.equal(current_owner.binding,r.origin_binding) then return end
  local next_mail,settled=Mailbox.settle(latest.mailboxes,op,outcome)
  if not next_mail then changed(P.reject(r,'storage_error',mailbox_error(settled)));return end
  latest.mailboxes=next_mail
  if settled.status=='full' and settled.payload and settled.payload.retryable==true and settled.payload.effect_started==false then
   -- The child has exited and the generation claim was settled as a proven
   -- pre-effect admission refusal. Exact replay needs a new live window grant.
   current.operation=nil
  end
  if r.op=='mailbox_retire' and (settled.status=='compacted' or settled.status=='retired') then
   for request_key,old in pairs(latest.requests) do
    local q=old.request
    if q.handle==r.handle and request_key~=key(r) and old.body.status~='pending' and old.body.status~='uncertain' and (not old.wake or old.wake.phase=='submitted') then
     local discard=false
     if q.op=='mailbox_publish_reply' then discard=q.reply_seq<=r.reply_floor
     elseif q.op=='mailbox_publish_ack' then
      local ack=Codec.strict_decode(tern.base64.decode(q.ack_b64),2048)
      discard=ack~=nil and ack.seq<=r.report_floor
     elseif q.op=='mailbox_read' then discard=true
     elseif q.op=='mailbox_retire' then discard=q.settlement_revision<=r.settlement_revision end
     if discard then
      if q.op~='mailbox_read' then latest.request_fences[request_key]=P.fingerprint(q) end
      if old.wake and old.wake.request_id then
       local wake_key=q.origin_binding.logical_session_id..'/'..old.wake.request_id
       local completed=latest.requests[wake_key]
       if completed and completed.body.status=='submitted' then latest.request_fences[wake_key]=P.fingerprint(completed.request);latest.requests[wake_key]=nil end
      end
      latest.requests[request_key]=nil
     end
    end
   end
  end
  if r.op=='mailbox_retire' and settled.status=='retired' then
   local issued=latest.requests[r.origin_binding.logical_session_id..'/'..r.launch_request_id]
   if issued and issued.stop_request_id then
    current.retirement_result=transport_body(r,settled)
    local stored,why=save(latest,true)
    if not stored then changed(P.reject(r,'storage_error',why));return end
    changed(settle_reservation(latest,current));return
   end
  end
  local body=finish(latest,current,publication_wake(latest,current,transport_body(r,settled)),true)
  changed(body)
 end)
 return entry.body
end
-- An unconsumed challenge whose deadline passed or whose host VM restarted can
-- never be consumed, so no effect started for it.
-- Status reads project that definitive pre-effect evidence read-only; stage
-- still re-nonces an identical request, and a live challenge stays pending.
local function staged_outcome(entry)
 local a=entry.authorization
 if not a or a.phase~='requested' or live_challenge(a) then return entry.body end
 if a.base_body then return P.clone(a.base_body) end
 return P.body(entry.request,'full',{resource='window_authorization',current=1,limit=1,retryable=true,effect_started=false})
end
-- Public writes first wait for a fresh, exact window-observed ORCH+ action.
-- The nonce is issued only AFTER asynchronous host-membership verification.
function M.stage(r,binding,session,bridge)
 -- owner_status is a read-only admission view: answered for any same-session binding, never staged or authorized.
 if r.op=='owner_status' then return M.request(r,binding,session,function()end) end
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 local admitted,err=owner(root,r,binding,session,false)
 if not admitted then return P.reject(r,'binding_mismatch',err) end
 local fence=root.request_fences[key(r)]
 if fence then return if fence==P.fingerprint(r) then P.body(r,'already_compacted') else P.reject(r,'content_conflict','Compacted request ID reused') end
 local entry=root.requests[key(r)]
 if entry and not P.equal(entry.request,r) then return P.reject(r,'content_conflict','Request ID reused with changed content') end
 if entry and entry.authorization then
  local a=entry.authorization
  if a.phase=='consumed' then return entry.body end
  -- Duplicate/status panels must not replace a live nonce or steal its bridge.
  if a.boot==boot and a.deadline>=tern.now() then return entry.body end
 elseif entry then
  local retry=entry.body.status=='full' and entry.body.payload and entry.body.payload.retryable==true and entry.body.payload.effect_started==false and not entry.operation
  if r.op=='native_wake' then if not retry then return entry.body end
  elseif r.op:sub(1,8)~='mailbox_' or not retry and entry.body.status~='uncertain' then return entry.body end
 end
 local old=if entry and entry.authorization then entry.authorization else nil
 local fresh=if old then old.new else entry==nil
 local base=if old then old.base_body else if entry then P.clone(entry.body) else nil
 local nonce=allocate(root,'grant');if not nonce then return P.reject(r,'storage_error','Authorization counter exhausted') end
 entry=entry or {request=P.clone(r)}
 entry.authorization={nonce=nonce,boot=boot,bridge=bridge,binding=P.clone(binding),session=session,deadline=tern.now()+30000,new=fresh,phase='requested',base_body=base}
 root.requests[key(r)]=entry
 return finish(root,entry,P.body(r,'pending',{authorization_required=true}),true)
end
function M.authorize(r,nonce,bridge,changed,claim,executor_id)
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 local entry=root.requests[key(r)];local a=if entry then entry.authorization else nil
 local mismatch=if not a then 'SPAWN authorization challenge is missing or already consumed'
  elseif not P.equal(entry.request,r) then 'SPAWN authorization request differs from staged immutable request'
  elseif a.nonce~=nonce then 'SPAWN authorization nonce differs from current challenge'
  elseif a.boot~=boot then 'SPAWN authorization challenge belongs to an earlier host VM'
  elseif a.bridge~=bridge then 'SPAWN authorization challenge belongs to another bridge pane'
  elseif a.phase~='requested' then 'SPAWN authorization challenge was already consumed'
  elseif a.deadline<tern.now() then 'SPAWN authorization challenge expired before host consumption'
  else nil
 if mismatch then return P.reject(r,'binding_mismatch',mismatch) end
 if not orch_claim(claim) or claim.executor~=r.origin_binding.window_epoch or not P.id(executor_id) then return P.reject(r,'binding_mismatch','Exact ORCH+ action claim and observing SPAWN executor required') end
 if a.base_body and a.base_body.status=='full' and (not entry.orch_claim or claim.grant_id==entry.orch_claim.grant_id) then return P.reject(r,'binding_mismatch','Capacity retry requires a new exact live ORCH+ action grant') end
 local snapshot,snapshot_error=Authority.managed_snapshot(a.binding)
 if not snapshot then
  a.deadline=0
  return finish(root,entry,if a.base_body then P.clone(a.base_body) else P.reject(r,'storage_error',snapshot_error),true)
 end
 local admitted,owner_error=owner(root,r,a.binding,a.session)
 if not admitted then return P.reject(r,'binding_mismatch',owner_error) end
 entry.orch_claim=P.clone(claim);a.window_executor=executor_id
 a.phase='consumed'
 local saved,err=save(root,true);if not saved then return P.reject(r,'storage_error',err) end
 return M.request(r,a.binding,a.session,changed,nonce,snapshot)
end

function M.request(r,binding,session,changed,authorization_nonce,authorized_snapshot)
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 if r.op=='owner_status' then return P.body(r,'owner_status',{owner=owner_state(root,r,binding,session)}) end
 local admitted,owner_error=owner(root,r,binding,session,r.op~='catalog' and r.op~='status')
 if not admitted then return P.reject(r,'binding_mismatch',owner_error) end
 local snapshot,snapshot_error=authorized_snapshot,nil
 if not snapshot then snapshot,snapshot_error=Authority.managed_snapshot(binding) end
 if not snapshot then return P.reject(r,'storage_error',snapshot_error) end
 if r.op=='status' then
  local target=root.requests[r.origin_binding.logical_session_id..'/'..r.target_request_id]
  if target and not same_owner(target.request.origin_binding,r.origin_binding) then return P.reject(r,'binding_mismatch','Target belongs to another owner') end
  return P.body(r,if target then 'found' else 'missing',if target then {outcome=staged_outcome(target)} else nil)
 end
 local fence=root.request_fences[key(r)]
 if fence then
  if fence~=P.fingerprint(r) then return P.reject(r,'content_conflict','Compacted request ID reused with different content') end
  return P.body(r,'already_compacted')
 end
 local authorized=false
 local authorized_claim=nil
 local prior=root.requests[key(r)]
 if prior then
  if not P.equal(prior.request,r) then return P.reject(r,'content_conflict','Request ID reused with changed content') end
  if prior.authorization then
   local a=prior.authorization
   if a.phase~='consumed' or a.boot~=boot or a.nonce~=authorization_nonce then return P.reject(r,'binding_mismatch','This staged request requires its fresh window grant') end
   prior.body=a.base_body or P.body(r,'resolved');prior.authorization=nil
   authorized=true;authorized_claim=prior.orch_claim
   if a.new then prior=nil;root.requests[key(r)]=nil end
  end
 end
 if prior then
  if authorized and r.op=='native_wake' and prior.body.status=='full' and prior.body.payload and prior.body.payload.effect_started==false then return prepare_wake(root,prior) end
  if authorized and prior.body.status=='full' and prior.body.payload and prior.body.payload.retryable==true and prior.body.payload.effect_started==false and not prior.operation and r.op:sub(1,8)=='mailbox_' then
   -- A retained pre-effect refusal is a durable retry authorization for this
   -- exact request, unlike an uncertain outcome or a partially published write.
   return mailbox(root,prior,snapshot,changed)
  end
  if authorized and prior.body.status=='uncertain' and r.op:sub(1,8)=='mailbox_' then
   -- Mailbox.prepare converts an uncertain immutable operation to readback-only
   -- reconciliation. A missing final file is still uncertainty, not retry permission.
   return mailbox(root,prior,snapshot,changed)
  end
  return prior.body
 end
 if r.op~='catalog' and not authorized then return P.reject(r,'binding_mismatch','Public mutations require an exact fresh window authorization') end
 if r.op=='mailbox_read' then
  for k,old in pairs(root.requests) do if old.request.op=='mailbox_read' and old.request.handle==r.handle then
   if (old.body.status=='pending' and old.operation~=nil) or old.body.status=='uncertain' then
    local refused={request=P.clone(r),orch_claim=authorized_claim};root.requests[key(r)]=refused
    return finish(root,refused,P.body(r,'full',{resource='mailbox_read',current=1,limit=1,retryable=true,effect_started=false}),true)
   end
   root.requests[k]=nil
  end end
 end
 local entry={request=P.clone(r),body=P.body(r,'resolved'),orch_claim=authorized_claim};root.requests[key(r)]=entry
 if r.op=='catalog' then return finish(root,entry,catalog(r,snapshot),false)
 elseif r.op=='launch' then return launch_prepare(root,entry,binding,snapshot)
 elseif r.op=='adopt' then return adopt_prepare(root,entry,binding,snapshot)
 elseif r.op=='accept' then return accept(root,entry)
 elseif r.op=='stop' then return stop_prepare(root,entry)
 elseif r.op=='native_wake' then return prepare_wake(root,entry)
 elseif r.op=='attach_worker' then return attach_worker(root,entry,binding,session)
 else return mailbox(root,entry,snapshot,changed) end
end
local function execution_in(root,r,bridge)
 local entry=root.requests[if r.op=='status' then r.origin_binding.logical_session_id..'/'..r.target_request_id else key(r)]
 if entry and entry.authorization and entry.authorization.phase=='requested' and entry.authorization.boot==boot and entry.authorization.bridge==bridge and entry.authorization.deadline>=tern.now() and P.equal(entry.request.origin_binding,r.origin_binding) then
  local base=entry.authorization.base_body
  return {schema=1,kind='authorize',request=entry.request,nonce=entry.authorization.nonce,previous_claim=if base and base.status=='full' then entry.orch_claim else nil}
 end
 local admitted=root.owners[r.origin_binding.logical_session_id]
 if not admitted or admitted.recovery_revision or not P.equal(admitted.binding,r.origin_binding) then return nil end
 if entry and entry.request.op=='launch' and (if r.op=='status' then P.equal(entry.request.origin_binding,r.origin_binding) else P.equal(entry.request,r)) and (entry.body.status=='resolved' or entry.body.status=='claimed' or entry.body.status=='launching') then
  if entry.launch and entry.launch.backend=='ssh-command' then return nil end
  return {schema=1,kind='launch',request=entry.request,phase=entry.body.status,claim=entry.claim,launch=entry.launch,orch_claim=entry.orch_claim}
 end
 if entry and entry.request.op=='adopt' and entry.launch and (if r.op=='status' then P.equal(entry.request.origin_binding,r.origin_binding) else P.equal(entry.request,r)) and (entry.body.status=='resolved' or entry.body.status=='claimed' or entry.body.status=='launching') then
  return {schema=1,kind='adopt',request=entry.request,phase=entry.body.status,claim=entry.claim,prompt=entry.launch.prompt,orch_claim=entry.orch_claim}
 end
 if entry and entry.request.op=='stop' and (if r.op=='status' then P.equal(entry.request.origin_binding,r.origin_binding) else P.equal(entry.request,r)) and stop_target(root,entry.request) and (entry.body.status=='resolved' or entry.body.status=='claimed' or entry.body.status=='launching') then
  return {schema=1,kind='stop',request=entry.request,phase=entry.body.status,claim=entry.claim,backend=entry.stop_backend,orch_claim=entry.orch_claim}
 end
 local target,launch=nil,nil
 if entry and entry.request.op=='native_wake' then target,launch=wake_target(root,entry.request) end
 local w=if target then target.wake else nil
 local owner_record=root.owners[r.origin_binding.logical_session_id]
 if w and launch and w.request_id==entry.request.request_id and owner_record and not owner_record.recovery_revision and P.equal(owner_record.binding,r.origin_binding) and P.equal(entry.request.origin_binding,r.origin_binding) and (w.phase=='resolved' or w.phase=='claimed' or w.phase=='launching') then
  return {schema=1,kind='wake',request=entry.request,phase=w.phase,claim=w.claim,pane_binding=w.pane_binding,orch_claim=entry.orch_claim}
 end
 return nil
end
function M.execution(r,bridge)
 if not P.integer(bridge,1) then return nil end
 local root=load();if not root then return nil end
 return execution_in(root,r,bridge)
end
-- Bridge lifecycle evidence for the ORCH+ window (reuse/close), never execution authority: the
-- live execution projection of the bridge's current request, and whether the registry still
-- names this bridge pane in a still-consumable window challenge. An expired or earlier-VM
-- challenge pins nothing, so it no longer holds the pane once its deadline passes, whether or not
-- its window survives. A granted launch, adoption, stop or wake stays live through its execution
-- projection until its native outcome is recorded. An unreadable registry or invalid pane reports
-- held, so the bridge is never closed or reused.
function M.bridge_lease(r,bridge)
 if not P.integer(bridge,1) then return nil,true end
 local root=load();if not root then return nil,true end
 local held=false
 for _,entry in pairs(root.requests) do
  local a=entry.authorization
  if live_challenge(a) and a.bridge==bridge then held=true;break end
 end
 return (if r then execution_in(root,r,bridge) else nil),held
end
function M.claim(r,executor_id,operation,result)
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 local entry=root.requests[key(r)]
 if not entry or not P.equal(entry.request,r) or not P.id(executor_id) then return P.reject(r,'binding_mismatch','Execution request differs') end
 local current_owner=root.owners[r.origin_binding.logical_session_id]
 if not current_owner or current_owner.recovery_revision or not P.equal(current_owner.binding,r.origin_binding) then return P.reject(r,'binding_mismatch','Controller was fenced or retired; do not execute') end
 -- Legacy effects remain inspectable, but no old SSH launch may start or replay.
 if (operation=='claim' or operation=='begin') and entry.launch and entry.launch.backend=='ssh-command' then return P.reject(r,'unsupported_capability','Retained SSH launch cannot start here; run ORCH+ on target host and settle existing effects with the original build before cutover') end
 if operation=='claim' then
  if entry.body.status~='resolved' or entry.claim then return entry.body end
  entry.claim={executor_id=executor_id,boot=boot};return finish(root,entry,P.body(r,'claimed',launch_payload(entry)),false)
 end
 if not entry.claim or entry.claim.executor_id~=executor_id or entry.claim.boot~=boot then return P.reject(r,'binding_mismatch','Execution claim no longer belongs to this VM') end
 if operation=='begin' then
  if entry.body.status~='claimed' then return entry.body end
  local snapshot=Authority.managed_snapshot(entry.binding)
  if not snapshot or snapshot.config_revision~=r.record_revision then return finish(root,entry,P.reject(r,'binding_mismatch','Configuration changed before native execution'),true) end
  local record,why=find_record(snapshot,r.record_id,r.record_revision)
  if not record then return finish(root,entry,P.reject(r,'binding_mismatch',why),true) end
  local eligible,_,reasons=capability(record,snapshot)
  if not eligible then return finish(root,entry,P.reject(r,'unsupported_capability',table.concat(reasons,'; ')),true) end
  return finish(root,entry,P.body(r,'launching',launch_payload(entry)),true)
 end
 if operation~='result' or entry.body.status~='launching' then return entry.body end
 if not P.fields(result,{status=function(v)return v=='submitted' or v=='uncertain' or (r.op=='adopt' and v=='refused')end},{pane_binding=P.pane,message=function(v)return P.text(v,512,true)end}) then return P.reject(r,'invalid_schema','Invalid launch result') end
 if r.op=='adopt' then
  -- Refusal is reported before the native ask (busy, non-agent or out-of-scope pane): no effect started.
  if result.status=='refused' then return finish(root,entry,P.reject(r,'target_unavailable',result.message or 'Adoption refused before native delivery; nothing was sent'),true) end
  if result.status=='submitted' and P.equal(result.pane_binding,r.pane_binding) then
   entry.pane_binding=P.clone(r.pane_binding)
   return finish(root,entry,P.body(r,'awaiting_acceptance',launch_payload(entry)),true)
  end
  return finish(root,entry,P.body(r,'uncertain',launch_payload(entry),{code='target_unavailable',message=result.message or 'Native ask may have been delivered; never repeat it'}),true)
 end
 if result.status=='submitted' and result.pane_binding and result.pane_binding.window_epoch==r.origin_binding.window_epoch and result.pane_binding.window_key==r.origin_binding.window_key and result.pane_binding.native_session_id==r.origin_binding.native_session_id and result.pane_binding.window_host_id==r.origin_binding.window_host_id then
  entry.pane_binding=P.clone(result.pane_binding)
  local observed,observe_error=Authority.managed_observe(entry.binding,entry.attempt_id,entry.observer_id,{phase='Starting',pane=tonumber(result.pane_binding.pane_id)})
  if not observed then return finish(root,entry,P.body(r,'uncertain',launch_payload(entry),{code='storage_error',message=tostring(observe_error):sub(1,512)}),true) end
  return finish(root,entry,P.body(r,'awaiting_acceptance',launch_payload(entry)),true)
 end
 return finish(root,entry,P.body(r,'uncertain',launch_payload(entry),{code='target_unavailable',message=result.message or 'Native effect outcome uncertain; do not retry'}),true)
end
function M.stop_claim(r,executor_id,operation,result)
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 local entry=root.requests[key(r)];local owner_record=root.owners[r.origin_binding.logical_session_id]
 local target=stop_target(root,r)
 if r.op~='stop' or not entry or not P.equal(entry.request,r) or not P.id(executor_id) or not target or target.stop_request_id~=r.request_id or not owner_record or owner_record.recovery_revision or not P.equal(owner_record.binding,r.origin_binding) then return P.reject(r,'binding_mismatch','Stop claim does not match the exclusive accepted launch') end
 if operation=='claim' then
  if entry.body.status~='resolved' or entry.claim then return entry.body end
  entry.claim={executor_id=executor_id,boot=boot}
  return finish(root,entry,P.body(r,'claimed'),true)
 end
 if not entry.claim or entry.claim.executor_id~=executor_id or entry.claim.boot~=boot then return P.reject(r,'binding_mismatch','Stop executor changed; retain ownership') end
 if operation=='begin' then
  if entry.body.status~='claimed' then return entry.body end
  if not Authority.managed_snapshot(entry.binding) then return finish(root,entry,P.body(r,'uncertain',nil,{code='target_unavailable',message='Execution host authority changed before stop'}),true) end
  return finish(root,entry,P.body(r,'launching'),true)
 end
 if operation~='result' or entry.body.status~='launching' then return entry.body end
 if P.fields(result,{status=function(v)return v=='stopped'end,pane_binding=P.pane,observation=function(v)return v=='absent' or v=='exited'end}) and P.equal(result.pane_binding,r.pane_binding) then
  return finish(root,entry,P.body(r,'stopped',{pane_binding=P.clone(r.pane_binding),observation=result.observation}),true)
 end
 if not P.fields(result,{status=function(v)return v=='uncertain'end,message=function(v)return P.text(v,512,false)end}) then return P.reject(r,'invalid_schema','Invalid exact native stop outcome') end
 return finish(root,entry,P.body(r,'uncertain',nil,{code='target_unavailable',message=result.message}),true)
end
function M.wake_claim(r,executor_id,operation,result,claim)
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 local entry=root.requests[key(r)];local owner_record=root.owners[r.origin_binding.logical_session_id]
 local target,launch=wake_target(root,r)
 if not entry or not P.equal(entry.request,r) or not target or target.wake.request_id~=r.request_id or not P.id(executor_id) or not owner_record or owner_record.recovery_revision or not P.equal(owner_record.binding,r.origin_binding) then return P.reject(r,'binding_mismatch','Wake action is not owned by this controller') end
 if not orch_claim(claim) or not P.equal(claim,entry.orch_claim) then return P.reject(r,'binding_mismatch','Wake event does not match the current exact ORCH+ grant') end
 local w=target.wake
 if not P.equal(w.pane_binding,select(3,route(launch))) then return P.reject(r,'binding_mismatch','Wake publication no longer matches its explicitly attached worker') end
 if operation=='wakedefer' then
  if w.phase~='resolved' and w.phase~='claimed' and w.phase~='launching' then return entry.body end
  if w.claim and (w.claim.executor_id~=executor_id or w.claim.boot~=boot) then return P.reject(r,'binding_mismatch','Only the exact never-started executor can defer wake') end
  w.phase='resolved';w.claim=nil;w.request_id=nil
  target.body=publication_wake(root,target,target.body)
  return finish(root,entry,P.body(r,'full',{resource='native_wake_idle',current=1,limit=1,retryable=true,effect_started=false}),true)
 elseif operation=='wakeclaim' then
  if w.phase~='resolved' or w.claim then return entry.body end
  w.claim={executor_id=executor_id,boot=boot};w.phase='claimed'
 elseif not w.claim or w.claim.executor_id~=executor_id or w.claim.boot~=boot then return P.reject(r,'binding_mismatch','Wake execution claim differs')
 elseif operation=='wakebegin' then
  if w.phase~='claimed' then return entry.body end
  w.phase='launching'
 elseif operation=='wakeresult' then
  if w.phase~='launching' then return entry.body end
  if not P.fields(result,{status=function(v)return v=='submitted' or v=='uncertain'end}) then return P.reject(r,'invalid_schema','Invalid wake outcome') end
  w.phase=result.status
 else return P.reject(r,'invalid_schema','Unknown wake operation') end
 target.body=publication_wake(root,target,target.body)
 return finish(root,entry,P.body(r,w.phase,{wake_status=w.phase,wake_effect_started=true}),true)
end
-- Migration is a separate closed schema, never an ORCH+ runtime exception.
function M.import_decode(bytes,preview)
 local r=Codec.strict_decode(bytes,P.LIMIT)
 local fields={schema=function(v)return v==1 end,origin=function(v)return v=='spawn-migration'end,op=function(v)return v=='import_config'end,request_id=P.id,source_client=function(v)return P.text(v,256,false)end,target_host=function(v)return P.text(v,1024,false)end,source_revision=function(v)return P.integer(v,0)end,source_sha256=P.digest,records_json=function(v)return P.text(v,P.LIMIT,false)end}
 if not preview then fields.migration_gate_id=P.id end
 if not P.fields(r,fields) or Codec.sha256(r.records_json)~=r.source_sha256 then return nil,'Invalid migration snapshot/hash' end
 local records=Codec.strict_decode(r.records_json,P.LIMIT);local canonical,why=Config.validate_records(records)
 if not canonical then return nil,why end
 for _,record in ipairs(canonical) do
  local values={record.command or '',record.fresh_executable or ''}
  for _,value in ipairs(record.arguments or {}) do table.insert(values,value) end
  for _,value in ipairs(record.fresh_arguments or {}) do table.insert(values,value) end
  for _,value in ipairs(values) do
   local lowered=string.lower(value)
   if lowered:find('%-%-password') or lowered:find('%-%-api%-key') or lowered:find('%-%-access%-token') or lowered:find('%-%-refresh%-token') or lowered:find('%-%-secret') or lowered:find('%-%-token') or lowered:find('[%w_]*api_key=') or lowered:find('[%w_]*secret=') or lowered:find('[%w_]*password=') then return nil,'Literal credential-bearing launch arguments are forbidden in migration snapshots; use reviewed private references' end
  end
 end
 return r,canonical
end
function M.open_import(binding,bytes)
 local r,records=M.import_decode(bytes,true);if not r then return nil,records end
 if r.target_host~=binding.host_key then return nil,'Snapshot target host differs from this Config host' end
 local root,why=load();if not root then return nil,why end
 local id=allocate(root,'import');if not id then return nil,'Gate counter exhausted' end
 local complete=P.clone(r);complete.migration_gate_id=id
 if #tern.json.encode(complete)>P.LIMIT then return nil,'Import request exceeds the bridge bound after adding its gate; shorten the exact snapshot before opening a gate' end
 root.gates[id]={request=r,records=records,binding=P.clone(binding),boot=boot}
 local ok,err=save(root,false);return if ok then id else nil,err
end
function M.cancel_import(id)
 local root,why=load();if not root then return false,why end
 local g=root.gates[id];if not g or g.consumed then return false,'Gate missing or already consumed' end
 root.gates[id]=nil;return save(root,true)
end
function M.import_config(r)
 local root,why=load();if not root then return {schema=1,op=r.op,request_id=r.request_id,status='rejected',error={code='storage_error',message=why}} end
 local gate=root.gates[r.migration_gate_id];local expected=P.clone(r);expected.migration_gate_id=nil
 local body={schema=1,op=r.op,request_id=r.request_id,status='rejected',source_sha256=r.source_sha256}
 if not gate or not P.equal(gate.request,expected) or not gate.consumed and gate.boot~=boot then body.error={code='binding_mismatch',message='Owner-opened exact import gate required'};return body end
 if gate.consumed and gate.outcome.status~='uncertain' then return gate.outcome end
 if not gate.consumed then
  -- Persist consumption intent before entering the independent config store.
  gate.consumed=true;gate.outcome=body;body.status='uncertain'
  local stored,err=save(root,true);if not stored then body.error={code='storage_error',message=err};return body end
 end
 -- Exact uncertain replay reconciles the authority receipt, or completes an import
 -- whose durable intent never reached that store. managed_import checks its receipt
 -- before the current revision and never overwrites conflicting records.
 local snapshot=Authority.managed_snapshot(gate.binding)
 local result,import_error=Authority.managed_import(gate.binding,if snapshot then snapshot.config_revision else -1,'bridge-'..r.request_id,gate.records)
 body.status=if result then (if result.replayed then 'already_imported' else 'imported') else 'conflict'
 body.payload=result;body.error=if import_error then {code='content_conflict',message=tostring(import_error):sub(1,512)} else nil
 gate.outcome=body;local saved,save_error=save(root,true)
 if not saved then return {schema=1,op=r.op,request_id=r.request_id,status='uncertain',error={code='storage_error',message=save_error}} end
 return body
end
function M.recovery_view(binding)
 local root,why=load();if not root then return nil,why end
 local rows={}
 for logical,owner_record in pairs(root.owners) do
  if owner_record.authority==authority_identity(binding) then
   local outcomes={}
   for _,entry in pairs(root.requests) do
    if entry.request.origin_binding.logical_session_id==logical then
     table.insert(outcomes,{request_id=entry.request.request_id,op=entry.request.op,phase=entry.body.status,pane=entry.pane_binding,claim=entry.claim,wake=entry.wake,authorization=if entry.authorization then {phase=entry.authorization.phase,bridge=entry.authorization.bridge,executor=entry.authorization.window_executor} else entry.authorization_fence})
    end
   end
   table.insert(rows,{logical_session_id=logical,binding=owner_record.binding,revision=root.revision,fenced=owner_record.recovery_revision~=nil,outcomes=outcomes})
  end
 end
 return rows
end
function M.recover_owner(binding,logical,revision,confirm)
 local root,why=load();if not root then return false,why end
 local current=root.owners[logical]
 if not current or current.authority~=authority_identity(binding) or revision~=root.revision then return false,'Owner/revision changed; inspect the current recovery view' end
 if not confirm then
  current.recovery_revision=root.revision+1
  for _,entry in pairs(root.requests) do
   if entry.request.origin_binding.logical_session_id==logical then
    fence_unstarted_wake(root,entry)
    if (entry.request.op=='launch' or entry.request.op=='adopt' or entry.request.op=='stop' or entry.request.op=='native_wake') and (entry.body.status=='resolved' or entry.body.status=='claimed' or entry.body.status=='launching') then
     entry.body.status='uncertain';entry.body.error={code='target_unavailable',message='Owner recovery fenced this executor; externally verify it is stopped or retired'}
    elseif entry.body.status=='pending' and entry.operation then
     entry.body=P.body(entry.request,'uncertain',nil,{code='target_unavailable',message='Recovery fenced this transport executor; preserve its unknown outcome'})
    end
    if entry.wake and (entry.wake.phase=='claimed' or entry.wake.phase=='launching') then
     entry.wake.phase='uncertain';entry.body.payload=entry.body.payload or {};entry.body.payload.wake_status='uncertain'
    end
    if entry.authorization then
     local a=entry.authorization
     entry.authorization_fence={nonce=a.nonce,phase=a.phase,bridge=a.bridge,executor=a.window_executor}
     entry.authorization=nil
     entry.body=if a.phase=='requested' then (if a.base_body then P.clone(a.base_body) else P.reject(entry.request,'authorization_revoked','Controller recovery revoked the unconsumed authorization')) else P.body(entry.request,'uncertain',nil,{code='target_unavailable',message='Recovery fenced a consumed authorization; inspect its retained executor'})
    end
   end
  end
 else
  if not current.recovery_revision then return false,'Fence the previous owner before confirming recovery' end
  -- This is recorded operator attestation, never machine proof or an automatic TTL.
  table.insert(root.tombstones,{binding=P.clone(current.binding),revision=root.revision+1,authority=current.authority,host_session=current.host_session,evidence='operator_attested_controller_and_launch_executors_stopped_or_retired'})
  for _,g in pairs(root.mailboxes.generations) do
   if g.binding.logical_session_id==logical and g.active then
    local write=g.writes[g.active.key]
    if write then write.status='uncertain';write.result={status='uncertain'} end
    g.active=nil
   end
  end
  root.owners[logical]=nil
 end
 return save(root,true)
end
M.protocol=P
return M
