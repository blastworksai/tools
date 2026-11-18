-- Host-local transport only. ORCH's installed host is an explicitly trusted
-- same-user relay for desktop proofs (including attached remote desktops).
-- Files are delivery, never authority: reducers and current private challenges
-- remain the only admission/effect gate. No native pane or desktop CLI is made.
local Channel=require('./channel/channel')
local Dispatch=require('./dispatch')
local Authority=require('./authority')
local Codec=require('./wire/codec')
local P=Dispatch.protocol
local M={}
local installed
local MAX_LANES=64
local function token(v,n)
 return type(v)=='string' and #v>0 and #v<=n and v:match('^[A-Za-z0-9_.-]+$')~=nil
end
local function origin(r) return r.setup_origin or r.origin_binding or (r.control_origin and r.control_origin.binding) end
local function native_source(source)
 local ok,panes=pcall(tern.pane.list)
 if not ok then return false end
 local count=0
 for _,pane in ipairs(panes) do
  if tostring(pane.pane)==source.host_pane_id then
   if pane.program~='orchplus.orchestrator' then return false end
   count+=1
  end
 end
 return count==1
end
local function source_valid(s,endpoint,lane)
 return P.fields(s,{schema=function(v)return v==1 end,relay_endpoint=function(v)return token(v,24)end,
  relay_boot=function(v)return token(v,64)end,lane_id=function(v)return token(v,24)end,
  host_pane_id=function(v)return type(v)=='string' and v:match('^[1-9]%d*$')~=nil and P.integer(tonumber(v),1)end,
  source_nonce=P.id,origin=function(v)return type(v)=='table' and type(v.native_session_id)=='string' and P.integer(tonumber(v.native_session_id),0)end,
  desktop_proof=function(v)return v=='delegated_native_window'end,host_program=function(v)return v=='orchplus.orchestrator'end})
  and s.relay_endpoint==endpoint and s.lane_id==lane and s.origin.host_pane_id==s.host_pane_id
  and (s.origin.alias_nonce==nil or s.origin.alias_nonce==s.source_nonce)
end
local function binding_parts(value)
 if type(value)~='string' then return nil end
 local endpoint,lane,act,boot=value:match('^([^:]+):([^:]+):([^:]+):([^:]+)$')
 if not endpoint then endpoint,lane,act=value:match('^([^:]+):([^:]+):([^:]+)$') end
 if not token(endpoint,24) or not token(lane,24) or not token(act,32) or (boot~=nil and not token(boot,64)) then return nil end
 return endpoint,lane,act,boot
end
-- Session-wide observation progress is not this execution's identity. Every
-- other field (including nonce, claims and source proof) remains exact; the
-- dispatch reducer still enforces the current consent revision lower bound.
local function same_execution(a,b)
 if type(a)~='table' or type(b)~='table' then return a==b end
 for key,value in pairs(a)do
  if key~='last_authority_revision' and not P.equal(value,b[key]) then return false end
 end
 for key in pairs(b)do
  if key~='last_authority_revision' and a[key]==nil then return false end
 end
 return true
end
local function read_request(r,binding,session)
 local ok,body=pcall(Dispatch.request,r,binding,session,function()end)
 return if ok then body else P.reject(r,'storage_error','Read unavailable; review setup or retry')
end
local function migration_peer(value,source)
 if not P.fields(value,{protocol=function(v)return v==2 end,
  phase=function(v)return v=='legacy' or v=='prepared' or v=='stable'end,
  source_nonce=function(v)return v==source.source_nonce end,host_pane_id=function(v)return v==source.host_pane_id end,
  authority_revision=function(v)return P.integer(v,0)end,source_sha256=P.digest,qualification=true},
  {authority_namespace=function(v)return P.text(v,128,false)end,compatibility=function(v)return type(v)=='table'end,result=function(v)return type(v)=='table'end})
  or not Codec.validate_dispatch_migration_qualification(value.qualification,'orch') then return false end
 local proof=value.qualification.proof
 return value.authority_revision==proof.source_revision and value.source_sha256==proof.source_sha256
  and (value.authority_namespace==nil or value.authority_namespace==proof.candidate_namespace)
end
function M.install()
 if installed then return installed end
 local boot=string.format('spawn-%d-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647))
 local endpoint,open_error=Channel.open({plugin_id='spawn',plugin_data=tern.plugin.data,incarnation=boot,
  fs=tern.fs,json=tern.json,base64=tern.base64})
 local self={boot=boot,error=open_error,lanes={},processed={},outgoing={},serial=0}
 installed=self
 local function fail(code) self.error={code=code,operation='dispatch'} end
 local function send(binding,route,bytes,settlement)
  if not endpoint then return false end
  local key=binding..'\n'..route
  local attempt=self.outgoing[key]
  if attempt and attempt.frame.body~=bytes then
   if not attempt.unwritten then fail('outgoing_conflict');return false end
   self.outgoing[key]=nil;attempt=nil
  end
  if not attempt then
   if self.serial>=9007199254740991 then fail('sequence_exhausted');return false end
   self.serial+=1
   attempt={frame={peer='orchplus',route=route,binding=binding,id='r-'..tostring(self.serial),body=bytes}}
   self.outgoing[key]=attempt
  end
  -- Retries retain the exact immutable identity, including after a partial
  -- write. Settlement may upgrade allocation priority, never message bytes.
  attempt.frame.priority=if settlement then 'settlement' else nil
  local receipt,err=endpoint.send(attempt.frame)
  if not receipt then attempt.unwritten=err and err.code=='backpressure';self.error=err;return false end
  self.outgoing[key]=nil
  return receipt
 end
 local function response(lane)
  if lane.forget_bytes then return lane.forget_bytes end
  if not lane.body then return '' end
  return P.encode(lane.body)
 end
 local function current_projection(lane)
  local current=if lane.request then Dispatch.current(lane.request.logical_session_id) else nil
  if lane.migration_response then
   current=if current then P.clone(current) else {}
   current.migration_response=lane.migration_response
  end
  if current and lane.control_response and lane.body==lane.control_response_body then current.control_response=lane.control_response end
  return current
 end
local function migration_result(lane,pending,value,problem,disposition,code)
  local source=Dispatch.current(nil)
  if value and (not source or not source.qualification
   or not P.equal(source.qualification.proof,value.proof) or not P.equal(source.qualification.selection,value.selection)) then
   value=nil;problem='Managed source changed before its result could be observed; inspect again explicitly'
   disposition=if pending.started then 'uncertain' else 'refused'
   code=if pending.operation=='bootstrap' then 'bootstrap_uncertain' else 'source_unavailable'
  end
  local response
  if value then
   response={ok=true,value=value}
   lane.migration_observation={qualification=P.clone(source.qualification),
    peer_origin=if pending.peer then {host_pane_id=pending.peer.host_pane_id,source_nonce=pending.peer.source_nonce} else nil}
   lane.migration_uncertain=nil
  else
   response={ok=false,error=tostring(problem or 'Migration source is unavailable'):sub(1,512),disposition=disposition or 'refused'}
   if code=='source_absent' or code=='source_unavailable' or code=='bootstrap_refused' or code=='bootstrap_uncertain' then response.code=code end
   if response.disposition~='uncertain' and lane.migration_uncertain==pending then lane.migration_uncertain=nil end
  end
  lane.migration_response={request_json=pending.request_json,operation=pending.operation,response=response,source=source}
 end
 local function migration_stage(lane,value,r)
  if not r.setup_origin or r.op~='catalog' or r.cursor~=nil or not P.fields(value,
   {schema=function(v)return v==1 end,request_json=true,operation=function(v)return v=='source' or v=='bootstrap' or v=='inspect' or v=='prepare' or v=='finish'end},
   {expected=true,peer=true,creation=true}) then return false,'invalid_migration' end
  if value.operation=='source' then
   if value.expected~=nil or value.peer~=nil or value.creation~=nil then return false,'invalid_migration' end
  elseif value.operation=='bootstrap' then
   if value.expected~=nil or value.peer~=nil or not P.bootstrap_creation(value.creation)
    or value.creation.source_nonce~=lane.source.source_nonce then return false,'invalid_migration' end
  elseif value.creation~=nil or not migration_peer(value.peer,lane.source) or not Codec.validate_dispatch_compatibility(
   {schema=1,kind='migration',orch=value.peer.qualification.proof,spawn=value.expected}) then return false,'invalid_migration' end
  local absent=lane.migration_response and lane.migration_response.operation=='source'
   and lane.migration_response.response.ok==false and lane.migration_response.response.code=='source_absent'
  local pending={request=r,request_json=value.request_json,operation=value.operation,expected=value.expected,peer=value.peer,creation=value.creation,
   nonce=string.format('migration-%08x-%08x',math.random(1,2147483647),math.random(1,2147483647)),deadline=tern.now()+30000,
   reconcile=lane.migration_uncertain}
  lane.request=r;lane.request_json=value.request_json;lane.body=nil;lane.setup_read=nil
  lane.control_response=nil;lane.control_response_body=nil;lane.migration_response=nil;lane.migration=nil
  if value.operation=='bootstrap' then
   if lane.migration_uncertain or not absent then
    migration_result(lane,pending,nil,'Read the absent source from this Create flow before initializing; retain any earlier uncertain intent',
     if lane.migration_uncertain then 'uncertain' else 'refused',if lane.migration_uncertain then 'bootstrap_uncertain' else 'bootstrap_refused')
    return true
   end
  elseif value.operation~='source' then
   local observed=lane.migration_observation
   if lane.migration_uncertain or not observed or not P.equal(observed.qualification.proof,value.expected)
    or observed.peer_origin and (observed.peer_origin.host_pane_id~=value.peer.host_pane_id or observed.peer_origin.source_nonce~=value.peer.source_nonce) then
    migration_result(lane,pending,nil,'Inspect the exact current sources before this phase; an earlier transition may require reconciliation',
     if lane.migration_uncertain then 'uncertain' else 'refused')
    return true
   end
  end
  lane.migration=pending
  return true
 end
 local function migration_apply(lane,value)
  if not P.fields(value,{request_json=true,nonce=P.id,executor_id=P.id,relay_execution=true},{peer=true,creation=true}) then return false,'invalid_callback' end
  local pending=lane.migration
  if not pending or pending.request_json~=value.request_json or pending.nonce~=value.nonce then return false,'stale_callback' end
  if pending.operation=='source' then
   if value.peer~=nil or value.creation~=nil then return false,'invalid_callback' end
  elseif pending.operation=='bootstrap' then
   if value.peer~=nil or not P.bootstrap_creation(value.creation) or not P.equal(value.creation,pending.creation) then return false,'stale_bootstrap_creation' end
  elseif value.creation~=nil or not migration_peer(value.peer,lane.source) or not P.equal(value.peer,pending.peer) then return false,'stale_migration_peer' end
  -- Consume before invoking the sole writer. Delivery retries never run a phase
  -- again, including exceptions and an ambiguous write after candidate capture.
  lane.migration=nil
  if pending.deadline<tern.now() then
   migration_result(lane,pending,nil,'The native migration observation expired; inspect again explicitly',if pending.reconcile then 'uncertain' else 'refused')
   return true
  end
  local called,result,problem,disposition,code
  if pending.operation=='source' then
   called,result,problem,code=pcall(Dispatch.admin_source_readonly)
   if called and result and pending.reconcile and (not pending.reconcile.transition_source
    or not P.equal(result.proof,pending.reconcile.transition_source)) then
    result=nil;problem='The prior transition is not positively reconciled to its captured candidate; retain the original intent'
    disposition='uncertain'
   end
   if not result and pending.reconcile then
    disposition='uncertain'
    if code=='source_absent' then code='source_unavailable' end
   end
  elseif pending.operation=='bootstrap' then
   pending.started=true;lane.migration_uncertain=pending
   called,result,problem,disposition,code=pcall(Dispatch.admin_bootstrap,pending.creation,function(proof)
    pending.transition_source=P.clone(proof)
   end)
  else
   pending.started=pending.operation~='inspect'
   if pending.started then lane.migration_uncertain=pending end
   called,result,problem,disposition=pcall(Dispatch.admin_apply,pending.operation,pending.expected,value.peer.qualification,function(proof)
    pending.transition_source=P.clone(proof)
   end)
  end
  if not called then
   problem='Migration observation failed; inspect the original source before any further phase';result=nil
   disposition=if pending.started or pending.reconcile then 'uncertain' else 'refused'
   code=if pending.operation=='bootstrap' then 'bootstrap_uncertain' elseif pending.operation=='source' then 'source_unavailable' else nil
  end
  migration_result(lane,pending,result,problem,disposition,code)
  return true
 end
 local function execution(lane)
  local migration=lane.migration
  if migration then return {schema=2,kind='migration',request=migration.request,request_json=migration.request_json,
   operation=migration.operation,nonce=migration.nonce,boot=boot,deadline=migration.deadline,expected=migration.expected,peer=migration.peer,creation=migration.creation} end
  if lane.setup_read then
   local setup=lane.setup_read
   if setup.deadline<tern.now() then
    lane.setup_read=nil;lane.body=P.reject(setup.request,'target_unavailable','Live setup observation expired; refresh setup')
   else return {schema=2,kind='setup_catalog',request=setup.request,request_json=lane.request_json,
    observation_id=setup.observation_id,boot=boot,deadline=setup.deadline} end
  end
  return if lane.request then Dispatch.execution(lane.request,tonumber(lane.source.host_pane_id),lane.digest) else nil
 end
 local function source_bytes(lane,code)
  local s=lane.source
  return tern.json.encode({schema=1,relay_endpoint=s.relay_endpoint,relay_boot=s.relay_boot,lane_id=s.lane_id,
   host_pane_id=s.host_pane_id,source_nonce=s.source_nonce,peer_boot=boot,error=code,consumed_execution=lane.consumed_execution,
   revoked_execution=lane.revoked_execution,released=lane.released,bind_request=lane.bind_request})
 end
 local function settle_revocation(lane)
  if not lane.revoked_execution then return true end
  if not send(lane.key,'spawn.source',lane.revocation_bytes,true) then return false end
  lane.revoked_execution=nil;lane.revocation_bytes=nil
  return true
 end
 local function publish_execution(lane,live,bytes)
  local pending=lane.pending_execution
  if not pending then
   pending={value=if live then P.clone(live) else nil,bytes=bytes}
   lane.pending_execution=pending
  end
  -- Even an allocation failure retains the attempted challenge and its identity.
  -- Publish those exact bytes before retiring it; a proof may arrive first, but
  -- the receiver must eventually reconcile the corresponding immutable frame.
  local receipt=send(lane.key,'spawn.execution',pending.bytes)
  if not receipt then return false end
  lane.sent['spawn.execution']=pending.bytes
  lane.execution_receipt={id=receipt.id,incarnation=boot}
  lane.published_execution=pending.value;lane.execution_retired=false
  lane.pending_execution=nil
  return true
 end
 local function retire_control(lane,live)
  local old=lane.published_execution
  if lane.execution_retired or not old or old.kind~='control_authorize' then return true end
  local expired=type(old.deadline)=='number' and old.deadline<tern.now()
  local superseded=lane.request_json~=old.request_json or live~=nil and not same_execution(live,old)
  if not expired and not superseded then return true end
  if not Dispatch.revoke_control(old,tonumber(lane.source.host_pane_id),lane.digest) then return false end
  lane.execution_retired=true
  lane.revoked_execution=P.clone(lane.execution_receipt)
  lane.revocation_bytes=source_bytes(lane)
  return settle_revocation(lane)
 end
 local function project(lane)
  if lane.released then return true end
  if lane.consumed_execution or not settle_revocation(lane) then return false end
  for _,record in pairs(self.processed)do
   -- A published challenge must not overtake its own input settlement: its
   -- native callback would otherwise collide with this still-processed stage.
   if record.key==lane.key or record.lane==lane then return false end
  end
  if lane.pending_execution and not publish_execution(lane) then return false end
  local live=if not lane.held and native_source(lane.source) then execution(lane) else nil
  if not retire_control(lane,live) then return false end
  if lane.execution_retired then live=if not lane.held and native_source(lane.source) then execution(lane) else nil end
  -- Source/projection unavailability alone cannot retire the retained challenge.
  if not lane.execution_retired and live==nil and lane.published_execution
   and lane.published_execution.kind=='control_authorize' then live=lane.published_execution end
  local current=current_projection(lane)
  if lane.request and lane.body and (lane.request.op=='mailbox_inventory' and lane.body.status=='pending'
   or lane.request.op=='mailbox_allocation' and lane.body.status=='uncertain' and lane.body.error and lane.body.error.code=='allocation_pending')
   and not lane.held and native_source(lane.source) then
   local session=tonumber(lane.source.origin.native_session_id)
   local binding=Authority.binding(session)
   if binding then lane.body=read_request(lane.request,binding,session)
   else lane.body=P.reject(lane.request,'target_unavailable','Inventory execution-host authority is unavailable') end
  end
  if lane.request and lane.request.op=='attach_worker' and lane.request.attestation=='same_terminal_process_no_pending_effects' and lane.body and lane.body.status=='pending' and not lane.held and native_source(lane.source) then
   local session=tonumber(lane.source.origin.native_session_id)
   local binding=Authority.binding(session)
   if binding then lane.body=Dispatch.stage(lane.request,binding,session,tonumber(lane.source.host_pane_id),lane.request_json,lane.digest)
   else lane.body=P.reject(lane.request,'target_unavailable','Terminal continuation execution-host authority is unavailable') end
  end
  local execution_bytes=if same_execution(live,lane.published_execution) and lane.sent['spawn.execution']~=nil
   then lane.sent['spawn.execution'] else if live then 'SPAWN_EXECUTION v2 '..tern.json.encode(live) else ''
  local values={['spawn.response']=response(lane),['spawn.execution']=execution_bytes,
   ['spawn.current']=if current then tern.json.encode(current) else ''}
  if values['spawn.response']==nil then fail('invalid_response');return false end
  -- Stable route order, bounded one lane per turn. Empty bodies clear a stale
  -- projection; no snapshot or file is written when the bytes did not change.
  for _,route in ipairs({'spawn.response','spawn.execution','spawn.current'}) do
   local bytes=values[route]
   if lane.sent[route]~=bytes then
    if #bytes>65536 then fail('projection_oversize');return false end
    if route=='spawn.execution' then
     if not publish_execution(lane,live,bytes) then return false end
    else
     if not send(lane.key,route,bytes) then return false end
     lane.sent[route]=bytes
    end
   end
  end
  return true
 end
 local function handle(lane,act,bytes,message)
  local source=lane.source
  if not native_source(source) then return false,'source_unavailable' end
  local bridge=tonumber(source.host_pane_id)
  local value,r
  lane.forget_bytes=nil
  if act=='discard_capability' or act=='discard_preview' or act=='discard_session' then
   -- Dedicated forget protocol: its own closed schema, never the legacy dispatch request decoder.
   local request=Codec.decode_forget_request(bytes)
   local o=source.origin
   if not request or request.op~=act then return false,'invalid_action' end
   for _,name in ipairs({'owner_id','owner_generation','host_pane_id','alias_nonce','window_key','native_session_id','window_host_id'}) do
    if request.owner[name]~=o[name] then return false,'origin_changed' end
   end
   if request.controller_pane~=source.host_pane_id or request.logical_session_id~=o.logical_session_id then return false,'origin_changed' end
   local session=tonumber(o.native_session_id)
   local binding,err=Authority.binding(session)
   local body
   if not binding then body=Dispatch.forget_unavailable(request,err) else body=Dispatch.forget(request,binding,session) end
   lane.request=nil;lane.request_json=nil;lane.body=nil;lane.setup_read=nil;lane.control_response=nil;lane.control_response_body=nil
   lane.forget_bytes=Codec.encode_forget_response(body)
   if not lane.forget_bytes then return false,'invalid_response' end
   return true
  end
  if act=='migration' then
   value=Codec.strict_decode(bytes,65536)
   if type(value)~='table' or type(value.request_json)~='string' then return false,'invalid_migration' end
   r=P.decode(value.request_json)
  elseif act:sub(1,6)=='spawn.' then
   value=Codec.strict_decode(bytes,65536)
   if type(value)~='table' or type(value.request_json)~='string' then return false,'invalid_callback' end
   if lane.execution_retired or not P.fields(value.relay_execution,{id=P.id,incarnation=P.id})
    or not P.equal(value.relay_execution,lane.execution_receipt)
    or not same_execution(execution(lane),lane.published_execution) then return false,'stale_execution' end
   r=P.decode(value.request_json)
  else r=P.decode(bytes) end
  if not r or not P.equal(origin(r),source.origin) then return false,'origin_changed' end
  if act=='migration' then
   local ok,why=migration_stage(lane,value,r);if not ok then return false,why end
  elseif act=='spawn.migration' then
   local ok,why=migration_apply(lane,value);if not ok then return false,why end
  elseif act=='spawn.setup_catalog' then
   if not P.fields(value,{request_json=true,observation_id=P.id,relay_execution=true}) then return false,'invalid_callback' end
   local pending=lane.setup_read
   if not r.setup_origin or not pending or pending.observation_id~=value.observation_id or pending.deadline<tern.now()
    or lane.request_json~=value.request_json or not P.equal(pending.request,r) then return false,'stale_callback' end
   lane.setup_read=nil;lane.body=read_request(r,nil,tonumber(source.origin.native_session_id))
  elseif act=='spawn.control_authorize' then
   if not P.fields(value,{request_json=true,nonce=P.id,executor_id=P.id,peer=true,relay_execution=true}) then return false,'invalid_callback' end
   local current=execution(lane)
   if not current or current.kind~='control_authorize' or current.request_json~=value.request_json or current.nonce~=value.nonce then return false,'stale_callback' end
   lane.body=Dispatch.control_authorize(r,value.nonce,bridge,value.executor_id,value.peer,lane.digest)
   Dispatch.qualification(r)
   lane.control_response=nil;lane.control_response_body=nil
   if lane.body and lane.body.category=='current_admission' then
    local progress=Dispatch.current(r.logical_session_id)
    if progress then lane.control_response={request_id=r.request_id,action_id=r.action_id,spawn_namespace=progress.spawn_namespace,session_progress=progress.session_progress};lane.control_response_body=lane.body end
   end
  elseif act=='spawn.authorize' then
   if not P.fields(value,{request_json=true,nonce=P.id,executor_id=P.id,orch_claim=true,proof=true,relay_execution=true},{native_observation=true}) then return false,'invalid_callback' end
   local current=execution(lane)
   if not current or current.kind~='authorize' or current.request_json~=value.request_json or current.nonce~=value.nonce then return false,'stale_callback' end
   lane.request=r;lane.request_json=value.request_json;lane.setup_read=nil
   lane.body=Dispatch.authorize(r,value.nonce,bridge,function(body)
    if lane.request_json==value.request_json then lane.body=body end
   end,value.orch_claim,value.executor_id,value.proof,lane.digest,value.native_observation)
  elseif act=='spawn.claim' or act=='spawn.begin' or act=='spawn.result' or act=='spawn.wakeclaim' or act=='spawn.wakebegin' or act=='spawn.wakeresult' or act=='spawn.wakedefer' then
   if not P.fields(value,{request_json=true,executor_id=P.id,orch_claim=true,proof=true,relay_execution=true},{result=true,spawn_claim=true,authorization_nonce=P.id}) then return false,'invalid_callback' end
   local current=execution(lane)
   if not current or current.request_json~=value.request_json then return false,'stale_callback' end
   if act=='spawn.claim' or act=='spawn.begin' or act=='spawn.wakeclaim' or act=='spawn.wakebegin' then
    if not P.id(current.nonce) or value.authorization_nonce~=current.nonce
     or type(current.deadline)~='number' or not (current.deadline>=tern.now() and current.deadline<math.huge) then return false,'stale_callback' end
   end
   lane.request=r;lane.request_json=value.request_json;lane.setup_read=nil
   local delivery=if act=='spawn.result' or act=='spawn.wakeresult' then message else nil
   if r.op=='launch' or r.op=='adopt' or r.op=='enrol' then lane.body=Dispatch.claim(r,value.executor_id,act:sub(7),value.result,value.proof,value.spawn_claim,lane.digest,delivery)
   elseif r.op=='stop' then lane.body=Dispatch.stop_claim(r,value.executor_id,act:sub(7),value.result,value.proof,value.spawn_claim,lane.digest,delivery)
   elseif r.op=='native_wake' then lane.body=Dispatch.wake_claim(r,value.executor_id,act:sub(7),value.result,value.orch_claim,value.proof,value.spawn_claim,lane.digest,delivery)
   else return false,'invalid_callback' end
  elseif act==r.op then
   lane.request=r;lane.request_json=bytes;lane.setup_read=nil;lane.control_response=nil;lane.control_response_body=nil
   if r.setup_origin then
    lane.setup_read={request=r,deadline=tern.now()+30000,observation_id=string.format('setup-%08x-%08x',math.random(1,2147483647),math.random(1,2147483647))}
    lane.body=P.body(r,'pending')
   else
    local session=tonumber(source.origin.native_session_id)
    local binding,err=Authority.binding(session)
    if not binding then lane.body=P.reject(r,'binding_mismatch',err)
    elseif r.op=='status' or r.op=='owner_status' or r.op=='mailbox_inventory' or r.op=='mailbox_allocation' then lane.body=read_request(r,binding,session)
    else
     lane.body=Dispatch.stage(r,binding,session,bridge,bytes,lane.digest)
     if r.compatibility and r.compatibility.kind=='migration' then Dispatch.qualification(r) end
    end
   end
  else return false,'invalid_action' end
  if lane.body and lane.body.error and lane.body.error.code=='storage_error'
   and act~='spawn.setup_catalog' and act~='status' and act~='owner_status' and act~='mailbox_inventory' and act~='mailbox_allocation' then return false,'storage_error' end
  if act=='spawn.result' or act=='spawn.wakeresult' then
   local retained=Dispatch.retain_relay_result(act,bytes,message)
   if not retained then return false,'result_unretained' end
  end
  if value then lane.consumed_execution=P.clone(value.relay_execution) end
  return true
 end
 local function durable_response(lane,settlement)
  if not settle_revocation(lane) then return false end
  local bytes=response(lane)
  if not bytes then fail('invalid_response');return false end
  if lane.sent['spawn.response']~=bytes then
   if not send(lane.key,'spawn.response',bytes,settlement) then return false end
   lane.sent['spawn.response']=bytes
  end
  if lane.migration_response then
   local current=current_projection(lane)
   local current_bytes=tern.json.encode(current)
   if #current_bytes>65536 then fail('projection_oversize');return false end
   if lane.sent['spawn.current']~=current_bytes then
    if not send(lane.key,'spawn.current',current_bytes,true) then return false end
    lane.sent['spawn.current']=current_bytes
   end
  end
  if lane.consumed_execution then
   if not send(lane.key,'spawn.source',source_bytes(lane),true) then return false end
   lane.execution_retired=lane.published_execution~=nil and lane.published_execution.kind=='control_authorize'
    and P.equal(lane.consumed_execution,lane.execution_receipt)
   lane.consumed_execution=nil
  end
  return true
 end
 local function drain(record)
  if record.hold_input then
   if record.outgoing and send(record.key,'spawn.source',record.outgoing,record.settlement) then record.outgoing=nil end
   return
  end
  -- Native outcomes and their exact inbound identity were committed together.
  -- ACK first, then persist settlement, before publishing any consumable result.
  if record.native_result and not record.acknowledged then
   local ok,err=endpoint.ack(record.message)
   if not ok then self.error=err;return end
   record.acknowledged=true
  end
  if record.native_result and not record.delivery_settled then
   local ok=Dispatch.settle_result_deliveries({record.message})
   if not ok then fail('delivery_settlement_held');return end
   record.delivery_settled=true
  end
  if record.outgoing then
   if not send(record.key,'spawn.source',record.outgoing,record.settlement) then return end
   record.outgoing=nil
  end
  if record.lane and not durable_response(record.lane,record.settlement) then return end
  if not record.acknowledged then
   local ok,err=endpoint.ack(record.message)
   if not ok then self.error=err;return end
   record.acknowledged=true
  end
  self.processed[record.message_key]=nil
  if record.release_lane then self.release_drain_at=self.release_drain_at or tern.now() end
  if record.lane then project(record.lane) end
 end
 local function inert(lane)
  if lane.migration and lane.migration.deadline<tern.now() then lane.migration=nil end
  if lane.migration_uncertain then return false end
  -- These are positive SPAWN-domain checks, independent of source liveness.
  if lane.setup_read or lane.consumed_execution or lane.revoked_execution or lane.pending_execution or execution(lane)
   or not Dispatch.relay_releasable(lane.digest) then return false end
  for _,record in pairs(self.processed)do
   if record.key==lane.key or record.lane==lane then return false end
  end
  for _,attempt in pairs(self.outgoing)do
   if attempt.frame.binding==lane.key then return false end
  end
  return true
 end
 local function collect(incarnation)
  local roots={}
  for key,lane in pairs(self.lanes)do
   -- Absence/reload selects old candidates; only inert() plus the carrier's
   -- positive file observation permits collection. Never retire live current
   -- lanes merely to make space, or emit an unsolicited release proof.
   if (lane.released or (incarnation and (lane.incarnation~=incarnation or not native_source(lane.source))))
    and inert(lane) then table.insert(roots,key) end
  end
  if #roots==0 then return end
  local quiet,err=endpoint.quiescent('orchplus',roots)
  if err then self.error=err;return end
  for _,key in ipairs(roots)do
   if quiet and quiet[key]==true then self.lanes[key]=nil end
  end
 end
 local function receive(message)
  local ep,id,act,target_boot=binding_parts(message.binding)
  local key=if ep then ep..':'..id else 'spawn-host'
  local message_key=message.incarnation..':'..message.id
  local prior=self.processed[message_key]
  local function remember(record)
   record.message=message;record.message_key=message_key
   record.native_result=act=='spawn.result' or act=='spawn.wakeresult'
   self.processed[message_key]=record
   drain(record)
  end
  local function reject(code)
   fail(code)
   local hold_input=act=='spawn.result' or act=='spawn.wakeresult'
   if hold_input and message.peer=='orchplus' and message.route=='spawn.request' then
    -- Preserve exact delayed outcome bytes in the existing authority graph
    -- before settling transport. This never applies the result or grants work.
    local called,retained=pcall(Dispatch.retain_relay_result,act,message.body,message)
    if called and retained==true then hold_input=false end
   end
   local record={key=key,settlement=true,hold_input=hold_input,outgoing=tern.json.encode({schema=1,kind='held',
    relay_endpoint=ep,lane_id=id,peer_boot=boot,error=code,
    rejected_message={id=message.id,incarnation=message.incarnation}})}
   remember(record)
  end
  if prior then drain(prior);return end
  if message.peer~='orchplus' or message.route~='spawn.request' then reject('invalid_peer');return end
  if not ep then reject('invalid_binding');return end
  local lane=self.lanes[key]
  -- A pending proof owns this lane's source route until its immutable send
  -- settles. Keep later inputs in the carrier rather than replacing that proof.
  if lane and lane.revoked_execution then return end
  if lane then
   local waiting=false
   for _,pending in pairs(self.processed)do
    if pending.key==key or pending.lane==lane then
     -- Completed handling may publish before its input ACK succeeds. Keep the
     -- next same-incarnation, boot-pinned input in its original carrier while
     -- that record drains, including key-only bind/rejection records. Native
     -- result settlement and deliberately held input remain hard fences.
     if pending.hold_input or pending.native_result and not pending.delivery_settled
      or message.incarnation~=lane.incarnation or target_boot~=boot then reject('callback_pending');return end
     waiting=true
    end
   end
   if waiting then return end
  end
  if act=='bind' and target_boot==nil then
   local source=Codec.strict_decode(message.body,8192)
   if not source_valid(source,ep,id) or not native_source(source) then reject('invalid_source');return end
   local digest=Codec.sha256(message.incarnation..'\n'..Codec.dispatch_source_bytes(source))
   if lane and (lane.digest~=digest or lane.released or lane.held) then reject('endpoint_conflict');return end
   if not lane then
    local n=0;for _ in pairs(self.lanes)do n+=1 end
    if n>=MAX_LANES then
     collect(message.incarnation)
     n=0;for _ in pairs(self.lanes)do n+=1 end
     if n>=MAX_LANES then reject('backpressure');return end
    end
    lane={key=key,source=source,incarnation=message.incarnation,digest=digest,sent={}}
    self.lanes[key]=lane
   end
   lane.bind_request={id=message.id,incarnation=message.incarnation}
   local record={key=key,outgoing=source_bytes(lane)}
   remember(record)
  elseif not lane or lane.released or lane.incarnation~=message.incarnation then reject('endpoint_unbound')
  elseif target_boot~=boot then reject('stale_endpoint')
  elseif lane.held then reject('uncertain_callback')
  elseif act=='release' then
   if message.body~='{}' or not native_source(lane.source) then reject('invalid_release');return end
   if not inert(lane) then reject('release_held');return end
   lane.released=true
   local record={key=key,release_lane=lane,settlement=true,outgoing=source_bytes(lane)}
   remember(record)
  else
   local called,ok,code=pcall(handle,lane,act,message.body,message)
   if not called or code=='storage_error' then
    -- The authority retains its uncertain effect. Settle delivery with an
    -- explicit durable held advisory, never replay this callback to learn more.
    lane.held=true;reject(if called then 'storage_error' else 'uncertain_callback');return
   end
   if not ok then reject(code);return end
   local record={key=key,lane=lane,settlement=act:sub(1,6)=='spawn.'}
   remember(record)
  end
 end
 function self.poll()
  if not endpoint then return end
  if not self.announced then
   self.announced=send('spawn-host','spawn.source',tern.json.encode({schema=1,kind='host_boot',peer_boot=boot}),true)~=false
  end
  local _,settle_error=endpoint.settle(4)
  if settle_error then self.error=settle_error end
  -- Probe every persisted fence before receive() can remove an orphan ACK.
  -- Missing ACK permits retry; unknown proof or failed persistence holds cleanup.
  local pending=Dispatch.result_deliveries()
  if not pending then fail('delivery_recovery_held');return end
  local observed={}
  for _,message in ipairs(pending)do
   local acked,ack_error=endpoint.acknowledged(message)
   if ack_error then self.error=ack_error;return end
   if acked then table.insert(observed,message) end
  end
  if #observed>0 then
   if not Dispatch.settle_result_deliveries(observed) then fail('delivery_settlement_held');return end
   for _,message in ipairs(observed)do
    local record=self.processed[message.incarnation..':'..message.id]
    if record then record.acknowledged=true;record.delivery_settled=true end
   end
  end
  -- Drain retained settlement ahead of fresh inputs even when later files
  -- precede their unacknowledged input. This only publishes retained outputs
  -- and ACKs, including exact native-result settlement; no handler is rerun.
  local ready={}
  for key,record in pairs(self.processed)do
   if not record.hold_input then table.insert(ready,key) end
  end
  table.sort(ready)
  for i=1,math.min(4,#ready)do
   self.delivery_cursor=(self.delivery_cursor or 0)%#ready+1
   local record=self.processed[ready[self.delivery_cursor]]
   if record then drain(record) end
  end
  local messages,err=endpoint.receive(4)
  if err then self.error=err end
  for _,message in ipairs(messages or {})do
   local ok=pcall(receive,message)
   if not ok then fail('handler_failed') end
  end
  -- Released tombstones reject late events until both sides' immutable files
  -- drain. Batch this expensive positive scan, never once per lane/timer tick.
  if self.release_drain_at and tern.now()>=self.release_drain_at then
   collect(nil)
   self.release_drain_at=nil
   for _,lane in pairs(self.lanes)do
    if lane.released then self.release_drain_at=tern.now()+10000;break end
   end
  end
  local keys={};for key in pairs(self.lanes)do table.insert(keys,key)end;table.sort(keys)
  if #keys>0 then self.cursor=(self.cursor or 0)%#keys+1;project(self.lanes[keys[self.cursor]]) end
 end
 local function tick()
  local ok=pcall(self.poll)
  if not ok then fail('poll_failed') end
  tern.timer(250,tick)
 end
 tern.timer(250,tick)
 return self
end
return M
