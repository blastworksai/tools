-- Current managed authority state. All mutation is committed by dispatch's sole writer.
local P=require('./bridge_protocol')
local Codec=require('./wire/codec')
local Config=require('./config')
local Mailbox=require('./mailbox')
local Capabilities=require('./mailbox_capabilities')
local TerminalIdentity=require('./terminal_identity')
local M={}
local views=setmetatable({},{__mode='k'})
function M.control_request(r) return r.op=='admit_session' or r.op=='reconcile_session' or r.op=='close_session' end
local function deadline(value)
 return type(value)=='number' and value==value and value>=0 and value<=9007199254740991
end
local function launch_family(op: string): boolean
 return op=='launch' or op=='adopt' or op=='enrol'
end
function M.valid_native_result(r,result)
 if r.op=='native_wake' then return P.fields(result,{status=function(v)return v=='submitted' or v=='uncertain'end}) end
 if r.op=='stop' then
  return (P.fields(result,{status=function(v)return v=='stopped'end,pane_binding=P.pane,observation=function(v)return v=='absent' or v=='exited'end}) and P.equal(result.pane_binding,r.pane_binding))
   or P.fields(result,{status=function(v)return v=='uncertain'end,message=function(v)return P.text(v,512,false)end})
 end
 return launch_family(r.op) and P.fields(result,{status=function(v)return v=='submitted' or v=='uncertain' or r.op=='enrol' and r.delivery=='clipboard' and v=='copied' or (r.op=='adopt' or r.op=='enrol') and v=='refused'end},{pane_binding=P.pane,message=function(v)return P.text(v,512,true)end})
end
-- Retained delivery evidence is not an authorized native outcome.
function M.decode_relay_result(act,bytes)
 if act~='spawn.result' and act~='spawn.wakeresult' or not P.text(bytes,65536,false) then return nil end
 local value=Codec.strict_decode(bytes,65536)
 if not P.fields(value,{request_json=function(v)return P.text(v,P.LIMIT,false)end,executor_id=P.id,orch_claim=true,proof=true,result=true,spawn_claim=true},{authorization_nonce=P.id,relay_execution=function(v)return P.fields(v,{id=P.id,incarnation=P.id})end}) then return nil end
 local r=P.decode(value.request_json)
 if not r or not Codec.validate_spawn_claim(value.spawn_claim,true) or value.executor_id~=value.spawn_claim.executor_id
  or not Codec.validate_dispatch_projection(value.proof,r,value.request_json,0,value.orch_claim,value.spawn_claim) then return nil end
 if (act=='spawn.wakeresult')~=(r.op=='native_wake') or not M.valid_native_result(r,value.result) then return nil end
 return value,r
end
local function channel_token(v,n)
 return type(v)=='string' and #v>0 and #v<=n and v:match('^[A-Za-z0-9_.-]+$')~=nil
end
function M.valid_result_delivery(message,request_json,result,native,claim)
 if not P.fields(message,{peer=function(v)return v=='orchplus'end,recipient=function(v)return v=='spawn'end,
  incarnation=function(v)return channel_token(v,80)end,id=function(v)return channel_token(v,80)end,
  route=function(v)return v=='spawn.request'end,binding=function(v)return P.text(v,160,false)end,
  body=function(v)return P.text(v,65536,false)end,slot=function(v)return P.integer(v,1) and v<=24 end}) then return false end
 local r=P.decode(request_json);if not r then return false end
 local act=if r.op=='native_wake' then 'spawn.wakeresult' else 'spawn.result'
 local endpoint,lane,addressed_act,boot=message.binding:match('^([^:]+):([^:]+):([^:]+):([^:]+)$')
 if not channel_token(endpoint,24) or not channel_token(lane,24) or addressed_act~=act or not channel_token(boot,64) then return false end
 local value=M.decode_relay_result(act,message.body)
 return value~=nil and value.request_json==request_json and P.equal(value.result,result)
  and P.equal(value.spawn_claim,native) and P.equal(value.orch_claim,claim)
end
function M.route(entry)
 local a=entry.attachment
 return if a then a.origin_binding else entry.request.origin_binding,if a then a.controller_pane else entry.request.controller_pane,if a then a.pane_binding else entry.pane_binding
end
function M.routed(entry,r)
 local origin,pane=M.route(entry)
 return P.equal(origin,r.origin_binding) and pane==r.controller_pane and origin.owner_generation==r.controller_generation
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
-- Mailbox reports failures as {status,error={code}} tables; storage paths need a bounded message.
function M.mailbox_error(why)
 if type(why)=='table' and type(why.error)=='table' and type(why.error.code)=='string' then
  local code=why.error.code:sub(1,64)
  if code=='journal_corrupt' then return 'Corrupt mailbox journal (journal_corrupt); restore it, do not reset' end
  return 'Mailbox journal refused ('..code..')'
 end
 return tostring(why):sub(1,512)
end
local function legacy_request(r)
 if type(r)~='table' or r.schema~=1 or not P.binding(r.origin_binding) then return nil end
 local candidate=P.clone(r)
 candidate.schema=2;candidate.authority_namespace='legacy-inspection';candidate.logical_session_id=r.origin_binding.logical_session_id;candidate.admission_seq=1
 if r.op=='status' then candidate.target_request_serial=1
 elseif r.op~='owner_status' then candidate.request_serial=1;candidate.next_request_serial=2;candidate.settled_before=1;candidate.consumed=tern.json.array() end
 return if P.decode(tern.json.encode(candidate)) then r else nil
end
local function legacy_valid(root)
 if not P.fields(root,{version=true,revision=true,namespace=true,owners=true,tombstones=true,request_fences=true,requests=true,mailboxes=true,gates=true,next_id=true}) or root.version~=1 or not P.integer(root.revision,0) or not P.id(root.namespace) or not P.integer(root.next_id,1) then return nil,'Corrupt legacy managed source' end
 for _,name in ipairs({'owners','tombstones','request_fences','requests','gates'}) do if type(root[name])~='table' then return nil,'Corrupt legacy managed source' end end
 if not Mailbox.validate(root.mailboxes) then return nil,'Corrupt legacy mailbox source' end
 for logical,o in pairs(root.owners) do if not P.id(logical) or not P.fields(o,{binding=P.binding,authority=true,host_session=true},{recovery_revision=true}) or o.binding.logical_session_id~=logical then return nil,'Corrupt legacy owner' end end
 for _,t in ipairs(root.tombstones) do if type(t)~='table' or not P.binding(t.binding) or not P.integer(t.revision,1) then return nil,'Corrupt legacy owner fence' end end
 for _,fingerprint in pairs(root.request_fences) do if not P.digest(fingerprint) then return nil,'Corrupt legacy request fence' end end
 for k,e in pairs(root.requests) do
  local r=type(e)=='table' and legacy_request(e.request)
  if not r or k~=r.origin_binding.logical_session_id..'/'..r.request_id or type(e.body)~='table' or e.body.schema~=1 or e.body.request_id~=r.request_id or e.body.action_id~=r.action_id or not P.equal(e.body.origin_binding,r.origin_binding) then return nil,'Corrupt legacy immutable request' end
  if e.claim and not P.fields(e.claim,{executor_id=P.id,boot=P.id}) then return nil,'Corrupt legacy execution claim' end
  if e.orch_claim and not Codec.validate_dispatch_claim(e.orch_claim) then return nil,'Corrupt legacy ORCH claim' end
  if e.launch and (not P.digest(e.launch_sha256) or P.fingerprint(e.launch)~=e.launch_sha256 or type(e.binding)~='table') then return nil,'Corrupt legacy launch' end
 end
 return root
end
-- Read-only whole-registry validation; no initialization, recovery or authority writes.
function M.validate_registry(root)
 if type(root)=='table' and root.version==1 then return legacy_valid(root) end
 if not P.fields(root,{version=true,revision=true,namespace=true,admission_cursor=true,sessions=true,workers=true,requests=true,mailboxes=true,gates=true,next_id=true,controls=true},{authority_namespace=true,migration=true}) or root.version~=2 or not P.integer(root.revision,0) or not P.id(root.namespace) or not P.integer(root.next_id,1) or not P.integer(root.admission_cursor,0) then return nil,'Corrupt dispatch registry; restore it, do not reset' end
 for _,name in ipairs({'sessions','workers','requests','gates','controls'}) do if type(root[name])~='table' then return nil,'Corrupt current managed map' end end
 if next(root.controls)~=nil or root.authority_namespace~=nil and not P.text(root.authority_namespace,128,false) or root.migration and not Codec.validate_dispatch_compatibility(root.migration) then return nil,'Corrupt paired authority control' end
 local admissions={}
 local deliveries={};local delivery_count=0
 local mail,why=Mailbox.validate(root.mailboxes);if not mail then return nil,M.mailbox_error(why) end
 for logical,s in pairs(root.sessions) do
  if not P.id(logical) or not P.fields(s,{admission_seq=true,control=true,authority=true,host_session=true,controller_pane=true},{closing_origin=Codec.validate_dispatch_control_origin}) or not P.integer(s.admission_seq,1) or s.admission_seq>root.admission_cursor or not root.authority_namespace or admissions[s.admission_seq] or not Codec.validate_dispatch_control(s.control) or s.control.binding and s.control.binding.logical_session_id~=logical or s.closing_origin and (s.control.phase~='closing' or s.closing_origin.close_id~=s.control.close_id or s.closing_origin.binding.logical_session_id~=logical) then return nil,'Corrupt active session control' end
  if not P.text(s.authority,256,false) or not P.integer(s.host_session,0) or not P.text(s.controller_pane,32,false) or not s.controller_pane:match('^%d+$') then return nil,'Corrupt native session authority' end
  admissions[s.admission_seq]=true
 end
 for k,w in pairs(root.workers) do
  if not P.fields(w,{kind=launch_family,logical_session_id=P.id,worker_id=P.id,worker_generation=function(v)return P.integer(v,1)end,launch_request_id=P.id,launch_action_id=P.id,work_id=P.id,enrolment_token=P.token,assignment_sha256=P.digest,mailbox_handle=P.id,record_id=function(v)return P.text(v,96,false)end,record_revision=function(v)return P.integer(v,0)end,origin_binding=P.binding,controller_pane=true,controller_generation=function(v)return P.integer(v,1)end,phase=true,backend=true,binding=true,mailbox_live=function(v)return type(v)=='boolean'end},{delivery=function(v)return v=='native_ask' or v=='clipboard'end,pane_binding=P.pane,acceptance=true,capabilities=true,attempt_id=true,observer_id=true,handover_id=P.id,handover_token=P.token,coordinator_owner_id=P.id,coordinator_generation=true,attachment=true,stop_request_id=P.id,stopped=function(v)return v=='absent' or v=='exited'end,wakes=true,terminal_process=TerminalIdentity.valid,launch_incarnation=function(v)return type(v)=='string' and #v>0 and #v<=256 end}) or k~=w.logical_session_id..'/'..w.launch_request_id or not root.sessions[w.logical_session_id] or type(w.binding)~='table' then return nil,'Corrupt current worker' end
  if (w.kind=='enrol')~=(w.delivery~=nil) or w.kind=='enrol' and (w.handover_id~=nil or w.coordinator_owner_id~=nil or w.attempt_id~=nil or w.backend~=(if w.delivery=='native_ask' then 'native-agent' else 'local-terminal')) then return nil,'Corrupt enrollment delivery facts' end
  if w.origin_binding.logical_session_id~=w.logical_session_id or not P.text(w.controller_pane,32,false) or not w.controller_pane:match('^%d+$') or not P.text(w.phase,32,false) or (w.backend~='native-agent' and w.backend~='local-terminal' and w.backend~='ssh-command') or w.acceptance~=nil and type(w.acceptance)~='table' then return nil,'Corrupt current worker facts' end
  if w.capabilities~=nil and (type(w.capabilities)~='table' or not Capabilities.valid_set(w.backend,if table.find(w.capabilities,'native-ask-v1') then 'native-ask-v1' else 'worker-poll-v1',w.capabilities)) then return nil,'Corrupt provisioned capability facts' end
  if w.attachment and not P.fields(w.attachment,{origin_binding=P.binding,controller_pane=true,pane_binding=P.pane}) then return nil,'Corrupt current worker route' end
  if w.wakes then
   if type(w.wakes)~='table' then return nil,'Corrupt current wake obligations' end
   for id,p in pairs(w.wakes) do
    if not P.fields(p,{request_id=P.id,action_id=P.id,op=true,handle=P.id,launch_request_id=P.id,origin_binding=P.binding,wake=true},{ack_sha256=P.digest,reply_sha256=P.digest,reply_seq=true,part=true}) or id~=p.request_id or p.launch_request_id~=w.launch_request_id or not P.fields(p.wake,{phase=true,pane_binding=P.pane},{claim=true,request_id=P.id}) or p.wake.claim and not Codec.validate_spawn_claim(p.wake.claim,true) then return nil,'Corrupt live worker wake' end
   end
  end
 end
 local serials={}
 for k,entry in pairs(root.requests) do
  if not P.fields(entry,{request=true,request_json=true,body=true},{claim=true,orch_claim=true,authorization=true,wake=true,attachment=true,launch=true,launch_sha256=true,binding=true,observer_id=true,stop_request_id=true,stop_backend=true,retirement_result=true,identity=true,capabilities=true,attempt_pending=true,attempt_id=true,pane_binding=true,acceptance=true,operation=true,authorization_fence=true,stopped=true,mailbox_live=true,wakes=true,relay_binding=P.digest,relay_consent=true,relay_result=true,native_result=true,terminal_process=TerminalIdentity.valid,launch_incarnation=function(v)return type(v)=='string' and #v>0 and #v<=256 end}) or type(entry.request)~='table' or type(entry.body)~='table' then return nil,'Corrupt retained request' end
  local request=P.decode(entry.request_json)
  if not request or not P.equal(request,entry.request) or request.setup_origin or M.control_request(request) or request.logical_session_id..'/'..request.request_id~=k or entry.body.request_id~=request.request_id or entry.body.action_id~=request.action_id or not P.equal(entry.body.origin_binding,request.origin_binding) or not P.encode(entry.body) then return nil,'Corrupt retained outcome' end
  if entry.relay_consent~=nil and (entry.relay_binding==nil or not P.fields(entry.relay_consent,{nonce=P.id,boot=P.id,bridge=function(v)return P.integer(v,1)end,deadline=deadline,executor_id=P.id}) or tostring(entry.relay_consent.bridge)~=request.origin_binding.host_pane_id) then return nil,'Corrupt consumed relay consent' end
  if entry.relay_result~=nil then
   if not P.fields(entry.relay_result,{act=true,bytes=true}) then return nil,'Corrupt retained relay outcome evidence' end
   local evidence,evidence_request=M.decode_relay_result(entry.relay_result.act,entry.relay_result.bytes)
   if not evidence or evidence.request_json~=entry.request_json or not P.equal(evidence_request,request)
    or request.op~='native_wake' and not P.equal(evidence.spawn_claim,entry.claim) then return nil,'Uncorrelated retained relay outcome evidence' end
  end
  if entry.native_result~=nil and (not P.fields(entry.native_result,{claim=function(v)return Codec.validate_spawn_claim(v,true)end,result=true},{delivery=true})
   or not M.valid_native_result(request,entry.native_result.result) or request.op~='native_wake' and not P.equal(entry.native_result.claim,entry.claim)
   or entry.native_result.delivery~=nil and not M.valid_result_delivery(entry.native_result.delivery,entry.request_json,entry.native_result.result,entry.native_result.claim,entry.orch_claim)) then return nil,'Corrupt applied native outcome evidence' end
  if entry.native_result and entry.native_result.delivery then
   local delivery=entry.native_result.delivery
   local delivery_key=delivery.incarnation..':'..delivery.id
   delivery_count+=1
   if delivery_count>24 or deliveries[delivery_key] then return nil,'Corrupt native delivery fence capacity or identity' end
   deliveries[delivery_key]=true
  end
  local s=root.sessions[request.logical_session_id]
  if not s or s.admission_seq~=request.admission_seq or request.authority_namespace~=root.authority_namespace or not request.request_serial then return nil,'Orphaned issued request' end
  local serial=request.logical_session_id..'/'..tostring(request.request_serial)
  if serials[serial] then return nil,'Duplicate outstanding issued serial' end
  serials[serial]=true
  if entry.claim and not Codec.validate_spawn_claim(entry.claim,true) then return nil,'Corrupt execution claim' end
  if entry.orch_claim and not Codec.validate_dispatch_claim(entry.orch_claim) then return nil,'Corrupt ORCH+ action claim' end
  if entry.authorization and (not P.fields(entry.authorization,{nonce=P.id,boot=P.id,bridge=true,binding=true,session=true,deadline=deadline,new=true,phase=true},{base_body=true,window_executor=P.id}) or not P.integer(entry.authorization.bridge,1) or not P.integer(entry.authorization.session,0) or type(entry.authorization.new)~='boolean' or (entry.authorization.phase~='requested' and entry.authorization.phase~='consumed') or type(entry.authorization.binding)~='table' or entry.authorization.base_body and not P.encode(entry.authorization.base_body)) then return nil,'Corrupt live-action authorization' end
  if entry.wake and (not P.fields(entry.wake,{phase=true,pane_binding=P.pane},{claim=true,request_id=P.id}) or entry.wake.claim and not Codec.validate_spawn_claim(entry.wake.claim,true)) then return nil,'Corrupt native wake claim' end
  if entry.attachment and (not launch_family(request.op) or not P.fields(entry.attachment,{origin_binding=P.binding,controller_pane=true,pane_binding=P.pane})) then return nil,'Corrupt current worker attachment' end
  if entry.launch and (not P.digest(entry.launch_sha256) or P.fingerprint(entry.launch)~=entry.launch_sha256 or type(entry.binding)~='table' or type(entry.observer_id)~='string') then return nil,'Corrupt immutable launch projection' end
  if request.op=='enrol' and (entry.launch and not P.fields(entry.launch,{backend=function(v)return v==(if request.delivery=='native_ask' then 'native-agent' else 'local-terminal')end,enrol=function(v)return v==true end,prompt=function(v)return type(v)=='string' and v~='' and not v:find('\0',1,true)end}) or entry.attempt_id~=nil or entry.attempt_pending~=nil) then return nil,'Corrupt enrollment-only execution projection' end
  if entry.stop_request_id~=nil and (not launch_family(request.op) or not P.id(entry.stop_request_id)) then return nil,'Corrupt exclusive stop fence' end
  if (request.op=='adopt' or request.op=='enrol') and entry.pane_binding~=nil and not P.equal(entry.pane_binding,request.pane_binding) then return nil,'Corrupt enrolled pane binding' end
  if request.op=='stop' and entry.body.status=='stopped' and (not entry.claim or not entry.orch_claim or not entry.stop_backend or not P.fields(entry.body.payload,{pane_binding=P.pane,observation=function(v)return v=='absent' or v=='exited'end}) or not P.equal(entry.body.payload.pane_binding,request.pane_binding)) then return nil,'Corrupt native stopped evidence' end
  if entry.stop_backend~=nil then
   if request.op~='stop' or (entry.stop_backend~='native-agent' and entry.stop_backend~='local-terminal' and entry.stop_backend~='ssh-command') or type(entry.binding)~='table' then return nil,'Corrupt native stop projection' end
  end
  if entry.retirement_result~=nil and (request.op~='mailbox_retire' or request.mode~='retire' or entry.retirement_result.status~='retired' or not P.encode(entry.retirement_result)) then return nil,'Corrupt retained mailbox retirement' end
 end
 for _,entry in pairs(root.requests) do
  if entry.stop_request_id then
   local r=entry.request;local stop=root.requests[r.origin_binding.logical_session_id..'/'..entry.stop_request_id]
   if not stop or stop.request.op~='stop' or stop.request.target_request_id~=r.request_id or stop.request.target_action_id~=r.action_id or not M.routed(entry,stop.request) or not P.equal(stop.request.pane_binding,select(3,M.route(entry))) or not entry.launch or stop.stop_backend~=entry.launch.backend then return nil,'Corrupt launch-to-stop fence' end
  end
 end
 for id,g in pairs(root.gates) do
  if not P.id(id) or not P.fields(g,{request=true,records=true,binding=true,boot=P.id},{consumed=true,outcome=true}) then return nil,'Corrupt migration gate' end
  local preview,records=M.import_decode(tern.json.encode(g.request),true)
  local canonical=Config.validate_records(g.records)
  if not preview or not canonical or not P.equal(records,canonical) or type(g.binding)~='table' or type(g.binding.authority_id)~='string' or type(g.binding.session_key)~='string' or g.binding.host_key~=preview.target_host then return nil,'Corrupt migration snapshot binding' end
  g.records=canonical
  if g.consumed~=nil and (g.consumed~=true or type(g.outcome)~='table' or g.outcome.request_id~=preview.request_id) then return nil,'Corrupt consumed import outcome' end
 end
 return root
end
function M.owner(root,logical)
 local s=root.sessions[logical];if not s or not s.control.binding then return nil end
 return {binding=s.control.binding,authority=s.authority,host_session=s.host_session,recovery_revision=if s.control.recovery then s.control.last_authority_revision else nil}
end
function M.retired_executor(root,origin)
 local s=root.sessions[origin.logical_session_id]
 return s~=nil and origin.owner_generation<=s.control.generation_floor
end
function M.compatibility(root)
 if not root.authority_namespace or root.migration then return nil end
 return {schema=1,kind='current',protocol=2,authority_namespace=root.authority_namespace,spawn_namespace=root.namespace}
end
function M.worker(root,logical,id)
 local key=logical..'/'..id
 if root.requests[key] then return root.requests[key] end
 local w=root.workers[key];if not w then return nil end
 local cache=views[root];if not cache then cache={};views[root]=cache end
 if cache[key] then return cache[key] end
 local e={worker_id=w.worker_id,worker_generation=w.worker_generation,enrolment_token=w.enrolment_token,assignment_sha256=w.assignment_sha256,handover_id=w.handover_id,handover_token=w.handover_token,coordinator_owner_id=w.coordinator_owner_id,coordinator_generation=w.coordinator_generation}
 local r={op=w.kind,delivery=w.delivery,request_id=w.launch_request_id,action_id=w.launch_action_id,logical_session_id=w.logical_session_id,origin_binding=w.origin_binding,controller_pane=w.controller_pane,controller_generation=w.controller_generation,record_id=w.record_id,record_revision=w.record_revision,work_id=w.work_id,mailbox_handle=w.mailbox_handle,enrolment=e}
 local entry={request=r,body={status=w.phase},pane_binding=w.pane_binding,acceptance=w.acceptance,launch={backend=w.backend},binding=w.binding,attempt_id=w.attempt_id,observer_id=w.observer_id,capabilities=w.capabilities,attachment=w.attachment,stop_request_id=w.stop_request_id,stopped=w.stopped,mailbox_live=w.mailbox_live,wakes=w.wakes,terminal_process=w.terminal_process,launch_incarnation=w.launch_incarnation}
 cache[key]=entry;return entry
end
local function worker(entry)
 local r=entry.request;local e=r.enrolment
 return {kind=r.op,delivery=r.delivery,logical_session_id=r.logical_session_id,worker_id=e.worker_id,worker_generation=e.worker_generation,launch_request_id=r.request_id,launch_action_id=r.action_id,work_id=r.work_id,enrolment_token=e.enrolment_token,assignment_sha256=e.assignment_sha256,mailbox_handle=r.mailbox_handle,record_id=r.record_id,record_revision=r.record_revision,origin_binding=P.clone(r.origin_binding),controller_pane=r.controller_pane,controller_generation=r.controller_generation,pane_binding=P.clone(entry.pane_binding),acceptance=P.clone(entry.acceptance),phase=entry.body.status,backend=entry.launch.backend,capabilities=P.clone(entry.capabilities),binding=P.clone(entry.binding),attempt_id=entry.attempt_id,observer_id=entry.observer_id,handover_id=e.handover_id,handover_token=e.handover_token,coordinator_owner_id=e.coordinator_owner_id,coordinator_generation=e.coordinator_generation,attachment=P.clone(entry.attachment),stop_request_id=entry.stop_request_id,stopped=entry.stopped,mailbox_live=entry.mailbox_live~=false,wakes=entry.wakes,terminal_process=P.clone(entry.terminal_process),launch_incarnation=entry.launch_incarnation}
end
function M.flush(root)
 for key,entry in pairs(views[root] or {}) do if root.workers[key] then root.workers[key]=worker(entry) end end
end
function M.each_worker(root)
 local all={}
 for key,w in pairs(root.workers) do all[key]=M.worker(root,w.logical_session_id,w.launch_request_id) end
 for key,e in pairs(root.requests) do if launch_family(e.request.op) then all[key]=e end end
 return all
end
function M.preserve_worker(root,entry)
 if launch_family(entry.request.op) and entry.launch and entry.pane_binding then root.workers[entry.request.logical_session_id..'/'..entry.request.request_id]=worker(entry) end
end
function M.publication(root,logical,id)
 local existing=root.requests[logical..'/'..id];if existing then return existing end
 for _,w in pairs(root.workers) do
  local p=w.logical_session_id==logical and w.wakes and w.wakes[id]
  if p then return {request=p,body={status='published'},wake=p.wake} end
 end
 return nil
end
function M.publications(root)
 local entries={}
 for key,e in pairs(root.requests) do if e.wake then entries[key]=e end end
 for _,w in pairs(root.workers) do
  for id,p in pairs(w.wakes or {}) do entries[w.logical_session_id..'/'..id]={request=p,body={status='published'},wake=p.wake} end
 end
 return entries
end
function M.complete_wake(root,logical,id)
 for key,w in pairs(root.workers) do
  if w.logical_session_id==logical and w.wakes then
   w.wakes[id]=nil;if next(w.wakes)==nil then w.wakes=nil end
   if views[root] and views[root][key] then views[root][key].wakes=w.wakes end
  end
 end
end
local function settled(entry)
 local phase=entry.body.status
 return phase~='pending' and phase~='claimed' and phase~='launching' and phase~='resolved' and phase~='uncertain' and not entry.authorization and not entry.retirement_result and not entry.relay_result and not (entry.native_result and entry.native_result.delivery)
end
function M.relay_releasable(root,relay_binding)
 if not P.digest(relay_binding) or root.version~=2 or root.migration then return false end
 for _,entry in pairs(root.requests) do
  if entry.relay_binding==relay_binding and (not settled(entry) or entry.body.error and entry.body.error.code=='claim_mismatch') then return false end
 end
 return true
end
function M.acknowledge(root,r)
 local s=root.sessions[r.logical_session_id];local c=s.control
 if M.control_request(r) and (r.settled_before<c.request_floor or r.next_request_serial<c.next_request_serial) then return nil,'stale_revision' end
 local consumed={};for _,serial in ipairs(r.consumed) do consumed[serial]=true end
 -- Validate the entire page before reclaiming anything. An ACK cannot hide a live effect.
 for _,e in pairs(root.requests) do
  local q=e.request
  if q.logical_session_id==r.logical_session_id and q.admission_seq==r.admission_seq and (q.request_serial<r.settled_before or consumed[q.request_serial]) and not settled(e) then return nil,'unknown_effect' end
 end
 for key,e in pairs(root.requests) do
  local q=e.request
  if q.logical_session_id==r.logical_session_id and q.admission_seq==r.admission_seq and (q.request_serial<r.settled_before or consumed[q.request_serial]) then
   M.preserve_worker(root,e)
   -- A pending native wake is a CURRENT delivery obligation. Keep just its immutable
   -- publication binding until the native wake settles, not the consumed response.
   if e.wake and e.wake.phase~='submitted' then
    local w=M.worker(root,q.logical_session_id,q.launch_request_id)
    if not w then return nil,'unknown_effect' end
    local stored=root.workers[q.logical_session_id..'/'..q.launch_request_id]
    if not stored then M.preserve_worker(root,w);stored=root.workers[q.logical_session_id..'/'..q.launch_request_id] end
    stored.wakes=stored.wakes or {};stored.wakes[q.request_id]={request_id=q.request_id,action_id=q.action_id,op=q.op,handle=q.handle,launch_request_id=q.launch_request_id,origin_binding=P.clone(q.origin_binding),ack_sha256=q.ack_sha256,reply_sha256=q.reply_sha256,reply_seq=q.reply_seq,part=q.part,wake=P.clone(e.wake)}
    w.wakes=stored.wakes
   end
   if q.op=='stop' then
    local w=M.worker(root,q.logical_session_id,q.target_request_id)
    if w then w.stop_request_id=nil end
   elseif q.op=='mailbox_retire' and q.mode=='retire' and e.body.status=='retired' then
    local Mailbox=require('./mailbox')
    local next_registry,why=Mailbox.reclaim_retired(root.mailboxes,q.handle)
    if not next_registry then return nil,why end
    root.mailboxes=next_registry
    root.workers[q.logical_session_id..'/'..q.launch_request_id]=nil
    if views[root] then views[root][q.logical_session_id..'/'..q.launch_request_id]=nil end
   end
   root.requests[key]=nil
  end
 end
 c.request_floor=math.max(c.request_floor,r.settled_before);c.next_request_serial=math.max(c.next_request_serial,r.next_request_serial)
 return true
end
function M.page(root,r,body)
 local after=r.outstanding_cursor and r.outstanding_cursor.after_serial or 0
 local through=r.outstanding_cursor and r.outstanding_cursor.through_serial or 0
 if not r.outstanding_cursor then
  for _,e in pairs(root.requests) do local q=e.request;if q.logical_session_id==r.logical_session_id and q.admission_seq==r.admission_seq then through=math.max(through,q.request_serial) end end
 end
 local entries={}
 for _,e in pairs(root.requests) do
  local q=e.request
  if q.logical_session_id==r.logical_session_id and q.admission_seq==r.admission_seq and q.request_serial>after and q.request_serial<=through then
   local phase=e.body.status
   table.insert(entries,{request_serial=q.request_serial,request_id=q.request_id,action_id=q.action_id,op=q.op,phase=if phase=='pending' or phase=='claimed' or phase=='launching' or phase=='uncertain' then phase else 'current_result'})
  end
 end
 table.sort(entries,function(a,b)return a.request_serial<b.request_serial end)
 local page={after_serial=after,through_serial=through,next_after_serial=through,complete=true,entries=tern.json.array()}
 body.payload.outstanding=page
 for index,e in ipairs(entries) do
  if #page.entries>=(r.page_limit or 32) then page.complete=false;page.next_after_serial=page.entries[#page.entries].request_serial;break end
  table.insert(page.entries,e)
  page.complete=index==#entries;page.next_after_serial=if page.complete then through else e.request_serial
  if not P.encode(body) then
   table.remove(page.entries)
   if #page.entries==0 then return nil,'oversize' end
   page.complete=false;page.next_after_serial=page.entries[#page.entries].request_serial;break
  end
 end
 return body
end
function M.admission(root,r)
 if root.migration then return nil,'migration_blocked' end
 if root.authority_namespace~=r.authority_namespace then return nil,'stale_authority' end
 local s=root.sessions[r.logical_session_id]
 if not s or s.admission_seq~=r.admission_seq then return nil,'admission_refused' end
 return s
end
function M.observation(root,r)
 local compatibility=M.compatibility(root)
 if not compatibility then return P.reject(r,'migration_blocked','Paired managed stores are not qualified') end
 if root.authority_namespace~=r.authority_namespace then return P.reject(r,'stale_authority','Current ORCH authority differs') end
 local s=root.sessions[r.logical_session_id]
 if not s or s.admission_seq~=r.admission_seq then return P.body(r,'absent',{admission_cursor=root.admission_cursor,compatibility=compatibility},nil,'admission_absent') end
 return P.body(r,'owner_status',{admission_cursor=root.admission_cursor,compatibility=compatibility,control=P.clone(s.control)},nil,'current_admission')
end
local function peer_valid(peer,r,root)
 if not P.fields(peer,{protocol=true,phase=true,authority_namespace=true,authority_revision=true,spawn_namespace=true,session=true},{compatibility=true}) or peer.protocol~=2 or peer.phase~='stable' or peer.authority_namespace~=r.authority_namespace or peer.authority_revision~=r.authority_revision or peer.spawn_namespace~=root.namespace then return false end
 local s=peer.session
 return P.fields(s,{admission_seq=true,control=true}) and s.admission_seq==r.admission_seq and Codec.validate_dispatch_control(s.control) and s.control.last_authority_revision<=peer.authority_revision and s.control.generation_floor==r.generation_floor and s.control.next_request_serial==r.next_request_serial and s.control.request_floor==r.settled_before and (if r.control_origin.kind=='closing' then s.control.phase=='closing' and s.control.close_id==r.control_origin.close_id else P.equal(s.control.binding,r.control_origin.binding))
end
local function reconnectable(root,s,r)
 local previous=s.control.binding;local current=r.control_origin.binding
 if r.op~='reconcile_session' or s.control.phase~='open' or not previous or s.closing_origin or s.control.recovery or s.controller_pane~=r.control_origin.controller_pane then return false end
 for _,name in ipairs({'logical_session_id','owner_id','owner_generation','host_pane_id','window_key','native_session_id','window_host_id'}) do
  if previous[name]~=current[name] then return false end
 end
 for _,entries in ipairs({root.requests,M.publications(root)}) do
  for _,entry in pairs(entries) do
   if entry.request.logical_session_id==r.logical_session_id then
    local status=entry.body.status
    local wake=entry.wake
    if status=='claimed' or status=='launching' or status=='uncertain' or status=='pending' and entry.operation~=nil or wake and (wake.phase=='claimed' or wake.phase=='launching' or wake.phase=='uncertain') then return false end
   end
  end
 end
 return true
end
-- Explicit forget (SKILLS-205). SPAWN is the quiescence authority: it inventories everything this one session's graph
-- retains, requires fresh native absence for every retained pane (stopped ones included), treats any claimed, executing,
-- uncertain or unobservable effect as a blocker, and only then deletes exactly that graph. Nothing here closes a pane or
-- stops a process, and nothing outside the graph (agent roster, other sessions, watermarks, files) is touched.
local function forget_panes(root,logical)
 local panes={}
 local function add(binding,agent,proof,launched,cwd)
  if type(binding)=='table' and binding.pane_id then
   local key=binding.pane_id..'|'..tostring(binding.window_host_id)
   local known=panes[key]
   panes[key]={binding=binding,agent=agent or (known and known.agent) or '',proof=proof or (known and known.proof),launched=launched or (known and known.launched),cwd=cwd or (known and known.cwd)}
  end
 end
 for _,e in pairs(root.requests) do
  local r=e.request
  if r.logical_session_id==logical then
   local agent=r.record_id
   add(e.pane_binding,agent,e.terminal_process,e.launch_incarnation,r.cwd);add(r.pane_binding,agent)
   add(e.attachment and e.attachment.pane_binding,agent);add(e.wake and e.wake.pane_binding,agent)
   add(e.body and type(e.body.payload)=='table' and e.body.payload.pane_binding,agent)
   add(e.native_result and e.native_result.result and e.native_result.result.pane_binding,agent)
   add(e.stopped and e.stopped.pane_binding,agent)
  end
 end
 for _,w in pairs(root.workers) do
  if w.logical_session_id==logical then
   add(w.pane_binding,w.record_id,w.terminal_process,w.launch_incarnation);add(w.attachment and w.attachment.pane_binding,w.record_id);add(w.stopped and w.stopped.pane_binding,w.record_id,nil,w.launch_incarnation)
   -- Wake obligations retained on the worker (publications kept by acknowledge()) carry their own pane bindings.
   for _,p in pairs(w.wakes or {}) do add(p.wake and p.wake.pane_binding,w.record_id) end
  end
 end
 return panes
end
local function forget_uncertain(root,logical)
 local out={}
 local function note(agent,host) out[#out+1]={agent=agent or '',host=host or ''} end
 for _,e in pairs(root.requests) do
  local r=e.request
  if r.logical_session_id==logical then
   local status=e.body and e.body.status
   local running=status=='claimed' or status=='launching' or status=='uncertain' or status=='pending' and e.operation~=nil
    or e.wake and (e.wake.phase=='claimed' or e.wake.phase=='launching' or e.wake.phase=='uncertain')
    or e.authorization and e.authorization.phase=='consumed'
    or e.claim~=nil and status~='rejected' and status~='stopped' and status~='retired' and status~='published' and e.native_result==nil and e.attempt_pending
   if running then note(r.record_id,r.origin_binding and r.origin_binding.window_host_id) end
  end
 end
 for _,w in pairs(root.workers) do
  if w.logical_session_id==logical then
   for _,p in pairs(w.wakes or {}) do
    local phase=p.wake and p.wake.phase
    if phase=='claimed' or phase=='launching' or phase=='uncertain' then note(w.record_id,p.origin_binding and p.origin_binding.window_host_id) end
   end
  end
 end
 for _,g in pairs(root.mailboxes.generations) do
  if g.binding and g.binding.logical_session_id==logical then
   local uncertain=g.active~=nil
   for _,w in pairs(g.writes or {}) do if w.status=='uncertain' or w.status=='active' then uncertain=true end end
   if uncertain then note(g.record_id,'') end
  end
 end
 return out
end
-- `observe(pane_binding)` answers 'absent', 'present' or anything else for unobservable. `host` is the one execution
-- host this peer can observe (the retained owner's window host); evidence from any other host is unavailable.
function M.forget_inventory(root,logical,observe,host,native_session,process_state,incarnation)
 local blockers,counts={},{requests=0,workers=0,generations=0}
 for _,e in pairs(root.requests) do if e.request.logical_session_id==logical then counts.requests+=1 end end
 for _,w in pairs(root.workers) do if w.logical_session_id==logical then counts.workers+=1 end end
 for _,g in pairs(root.mailboxes.generations) do if g.binding and g.binding.logical_session_id==logical then counts.generations+=1 end end
 local mine=forget_panes(root,logical)
 local others={}
 for other,s in pairs(root.sessions) do
  if other~=logical then for key,p in pairs(forget_panes(root,other)) do others[key]=p end end
 end
 local keys={};for key in pairs(mine) do keys[#keys+1]=key end;table.sort(keys)
 local observed={}
 for _,key in ipairs(keys) do
  local p=mine[key];local binding=p.binding;local proof=p.proof
  local host_name=tostring(binding.window_host_id)
  -- Fail closed: evidence from another host or another native session (a restarted Tern reuses pane ids) is unavailable, never absence.
  local pane,matched='unknown',nil
  if binding.window_host_id==host and (native_session==nil or binding.native_session_id==native_session) then pane,matched=observe(binding,{agent=p.agent,cwd=p.cwd}) end
  -- A retained terminal process identity decides what the pane id means: only the retained process itself (boot, pid, start time)
  -- is positive evidence about the retained execution. A failed verification is never evidence of absence.
  local process=nil
  if type(proof)=='table' then
   if process_state then process=process_state(proof) else process='unknown' end
  elseif pane=='absent' and (incarnation==nil or p.launched~=incarnation) then
   -- No retained process proof: pane absence is evidence only for a pane that a SPAWN launch recorded under THIS Tern host
   -- incarnation. A missing record (older binding) or a different one (Tern restarted; pane ids may be reused) is not evidence.
   pane='unknown'
  end
  observed[#observed+1]=key..'='..tostring(pane)..'/'..tostring(process)
  if pane=='unknown' or pane~='present' and pane~='absent' then
   blockers[#blockers+1]={kind='unobservable',agent=p.agent,host=host_name}
  elseif process=='unknown' then
   blockers[#blockers+1]={kind='unobservable',agent=p.agent,host=host_name}
  elseif process=='alive' then
   -- A surviving retained process: a named pane to close through Tern, or (pane gone) a process outside any pane to resolve.
   if pane=='present' then blockers[#blockers+1]={kind=if others[key] then 'shared_pane' else 'pane',agent=p.agent,pane=matched or binding.pane_id,host=host_name}
   else blockers[#blockers+1]={kind='uncertain',agent=p.agent,host=host_name} end
  elseif pane=='present' then
   if process=='gone' then
    -- The pane id now shows some other process: attributing it to this orchestration (or telling the owner to close it) would be a guess.
    blockers[#blockers+1]={kind='unobservable',agent=p.agent,host=host_name}
   else blockers[#blockers+1]={kind=if others[key] then 'shared_pane' else 'pane',agent=p.agent,pane=matched or binding.pane_id,host=host_name} end
  end
 end
 for _,u in ipairs(forget_uncertain(root,logical)) do blockers[#blockers+1]={kind='uncertain',agent=u.agent,host=u.host} end
 -- Binds every observation result: a later commit must reproduce exactly these results.
 return {blockers=blockers,inventory=counts,dispatch_revision=root.revision,fingerprint=Codec.sha256(table.concat(observed,';'))}
end
-- Deletes exactly this session's graph. Returns the inventory, or nil and the blocking inventory.
function M.forget_discard(root,logical,observe,host,native_session,process_state,expected_fingerprint,incarnation)
 local inventory=M.forget_inventory(root,logical,observe,host,native_session,process_state,incarnation)
 if expected_fingerprint~=nil and #inventory.blockers==0 and inventory.fingerprint~=expected_fingerprint then return nil,inventory,'changed' end
 if #inventory.blockers>0 then return nil,inventory end
 for key,e in pairs(root.requests) do if e.request.logical_session_id==logical then root.requests[key]=nil end end
 for key,w in pairs(root.workers) do
  if w.logical_session_id==logical then
   root.workers[key]=nil
   if views[root] then views[root][key]=nil end
  end
 end
 for handle,g in pairs(root.mailboxes.generations) do if g.binding and g.binding.logical_session_id==logical then root.mailboxes.generations[handle]=nil end end
 root.sessions[logical]=nil
 return inventory
end
function M.control(root,r,binding,session,peer)
 if root.migration or r.compatibility.kind~='current' then return nil,'migration_blocked' end
 if not peer_valid(peer,r,root) or r.compatibility.spawn_namespace~=root.namespace then return nil,'stale_authority' end
 if root.authority_namespace~=r.authority_namespace then return nil,'stale_authority' end
 local s=root.sessions[r.logical_session_id];local origin=r.control_origin.binding
 if s and s.admission_seq~=r.admission_seq then return nil,'admission_refused' end
 if s and r.op=='reconcile_session' and (r.next_request_serial<s.control.next_request_serial or r.settled_before<s.control.request_floor or r.authority_revision<s.control.last_authority_revision) then
  if s.authority~=(binding.managed_authority_id or binding.authority_id) or s.host_session~=session or not P.equal(s.control.binding,origin) then return nil,'stale_binding' end
  -- Restored peer counters may be below our live outstanding serials. This is a
  -- read-only finite sweep, never acceptance of its regressed ACK or new effects.
  local body=P.body(r,'reconciled',{admission_cursor=root.admission_cursor,compatibility=M.compatibility(root),control=P.clone(s.control)},nil,'current_admission')
  local page,why=M.page(root,r,body);return page,why,false
 end
 if s and (r.authority_revision<s.control.last_authority_revision or r.generation_floor<s.control.generation_floor) then return nil,'stale_revision' end
 if not s then
  if r.op~='admit_session' then return P.body(r,if r.op=='close_session' then 'closed' else 'absent',{admission_cursor=root.admission_cursor,compatibility=r.compatibility},nil,'admission_absent') end
  if r.admission_seq<=root.admission_cursor then return nil,'admission_refused' end
  if origin.owner_generation<=r.generation_floor or r.control_origin.kind~='active' then return nil,'stale_binding' end
  local count=0;for _ in pairs(root.sessions) do count+=1 end
  if count>=64 then return nil,'admission_refused' end
  root.admission_cursor=r.admission_seq
  s={admission_seq=r.admission_seq,authority=binding.managed_authority_id or binding.authority_id,host_session=session,controller_pane=r.control_origin.controller_pane,control={phase='open',generation_floor=r.generation_floor,request_floor=r.settled_before,next_request_serial=r.next_request_serial,last_authority_revision=r.authority_revision,binding=P.clone(origin)}}
  root.sessions[r.logical_session_id]=s
 else
  if s.authority~=(binding.managed_authority_id or binding.authority_id) or s.host_session~=session then return nil,'stale_binding' end
  if s.control.binding and not P.equal(s.control.binding,origin) then
   if not reconnectable(root,s,r) then return nil,'stale_binding' end
   s.control.binding=P.clone(origin)
  end
  if s.closing_origin and not P.equal(s.closing_origin.binding,origin) then return nil,'stale_binding' end
  if not s.control.binding and r.op~='close_session' then
   if not s.control.recovery or s.control.recovery.phase~='confirmed' or origin.owner_generation<=s.control.generation_floor then return nil,'stale_binding' end
   s.control.binding=P.clone(origin);s.controller_pane=r.control_origin.controller_pane;s.control.recovery=nil
  end
  if s.control.phase=='closing' and r.op~='close_session' then return nil,'admission_refused' end
  local ok,why=M.acknowledge(root,r);if not ok then return nil,why end
  s.control.last_authority_revision=r.authority_revision
 end
 P.observe(root)
 if r.op=='close_session' then
  if s.control.phase=='closing' and s.control.close_id~=r.close_id then return nil,'stale_binding' end
  s.control.phase='closing';s.control.close_id=r.close_id
  s.closing_origin=s.closing_origin or {kind='closing',binding=P.clone(origin),controller_pane=r.control_origin.controller_pane,close_id=r.close_id}
  if s.control.binding then
   if peer.session.control.binding~=nil then return P.body(r,'closing',{admission_cursor=root.admission_cursor,compatibility=M.compatibility(root),control=P.clone(s.control)},nil,'current_admission') end
   s.control.generation_floor=math.max(s.control.generation_floor,s.control.binding.owner_generation);s.control.binding=nil
  end
  local unresolved=false
  for _,e in pairs(root.requests) do if e.request.logical_session_id==r.logical_session_id then unresolved=true;break end end
  for _,w in pairs(root.workers) do if w.logical_session_id==r.logical_session_id then unresolved=true;break end end
  for _,g in pairs(root.mailboxes.generations) do if g.binding.logical_session_id==r.logical_session_id then unresolved=true;break end end
  if unresolved then return P.body(r,'closing',{admission_cursor=root.admission_cursor,compatibility=M.compatibility(root),control=P.clone(s.control)},nil,'current_admission') end
  root.sessions[r.logical_session_id]=nil
  return P.body(r,'closed',{admission_cursor=root.admission_cursor,compatibility=M.compatibility(root)},nil,'admission_absent')
 end
 local body=P.body(r,if r.op=='admit_session' then 'admitted' else 'reconciled',{admission_cursor=root.admission_cursor,compatibility=M.compatibility(root),control=P.clone(s.control)},nil,'current_admission')
 return if r.op=='reconcile_session' then M.page(root,r,body) else body
end
return M
