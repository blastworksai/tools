-- Host-only SPAWN dispatcher. One writer; files/native effects are separate stores.
local P=require('./bridge_protocol')
local Codec=require('./wire/codec')
local Authority=require('./authority')
local Backend=require('./backend')
local Mailbox=require('./mailbox')
local Capabilities=require('./mailbox_capabilities')
local State=require('./dispatch_state')
local MailboxAdapter=require('./mailbox_adapter')
local Native=require('./native_cli')
local TerminalIdentity=require('./terminal_identity')
local Config=require('./config')
local terminal_starts,terminal_checks={},{}
local valid=State.validate_registry
local M={}
local on_commit
-- HOST view invalidation after a durable commit, never an execution grant.
function M.install(callback) on_commit=callback end
local KEY='dispatch-v1'
local LIMIT=4*1024*1024
local RESERVE=256*1024
local boot=string.format('vm-%d-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647))
local loaded=false
-- The Tern host incarnation this SPAWN runs in. On Linux the host process identity (boot id, pid, start time) survives a plugin
-- reload but never a Tern restart; elsewhere it is this VM's boot token, which also changes on reload (a conservative false
-- change). A pane recorded under a different incarnation may have had its id reused.
local incarnation=(function()
 local ok,value=pcall(function()
  if tern.runtime.os~='linux' then return nil end
  local stat=tern.fs.read('/proc/self/stat',16384)
  local pid,rest=stat:match('^(%d+) %(.+%) (.+)$')
  local fields={};for word in rest:gmatch('%S+') do fields[#fields+1]=word;if #fields==20 then break end end
  local boot_id=tern.fs.read('/proc/sys/kernel/random/boot_id',128):gsub('%s+$','')
  if #fields~=20 or #boot_id~=36 then return nil end
  return 'linux:'..boot_id..':'..pid..':'..fields[20]
 end)
 return if ok and value then value else 'vm:'..boot
end)()
local hold=nil
local control_challenges={}
local qualification_snapshot=nil
local qualification_source_bytes=nil
local orch_claim=Codec.validate_dispatch_claim
local function native_claim(root,executor_id)
 return {spawn_namespace=root.namespace,claim_nonce=string.format('claim-%d-%08x-%08x-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647)),executor_id=executor_id,boot=boot}
end
local function key(r) return r.logical_session_id..'/'..r.request_id end
local function same_owner(a,b)
 return a.logical_session_id==b.logical_session_id and a.owner_id==b.owner_id and a.owner_generation==b.owner_generation and a.host_pane_id==b.host_pane_id
end
local route,routed=State.route,State.routed
-- A launch-family entry binds a worker generation to a new or existing conversation.
local function launched(entry) return entry~=nil and (entry.request.op=='launch' or entry.request.op=='adopt' or entry.request.op=='enrol') end
-- Read-only, host-wide preparation guard. Never initializes or recovers a registry.
function M.record_preparation_busy(record_id)
 if not P.text(record_id,96,false) then return nil,'Invalid agent identity for managed-work inspection' end
 if hold then return nil,hold end
 local ok,root=pcall(tern.kv.get,KEY)
 if not ok then return nil,'Managed work cannot be read; preserve it before preparation' end
 if root==nil then
  local read,marker=pcall(tern.kv.get,KEY..'-initialized')
  if not read or marker~=nil then return nil,'Managed work was initialized but its registry is unavailable; restore it before preparation' end
  return false
 end
 local canonical,why=valid(root)
 if not canonical or root.version~=2 then return nil,why or 'Review retained managed work before preparing agents' end
 local message='This agent has unfinished managed launch, enrollment or mailbox work on this execution machine; stop and retire it before preparation'
 for _,generation in pairs(root.mailboxes.generations) do
  if generation.record_id==record_id and generation.status~='retired' then return true,message end
 end
 for _,worker in pairs(root.workers) do
  if worker.record_id==record_id and worker.mailbox_live~=false then return true,message end
 end
 for _,entry in pairs(root.requests) do
  local r=entry.request
  if r.record_id==record_id and (launched(entry) or r.op=='mailbox_provision') then
   local no_effect=entry.body.status=='rejected' and entry.claim==nil and entry.operation==nil and entry.attempt_id==nil and not entry.attempt_pending and entry.pane_binding==nil and entry.native_result==nil and entry.relay_result==nil
   if entry.mailbox_live~=false and not no_effect then return true,message end
  end
 end
 return false
end
local function preparation_admission(r,binding)
 if r.op~='launch' and r.op~='adopt' and r.op~='enrol' then return true end
 return Authority.record_launch_available(binding,r.record_id)
end
local retired_executor=State.retired_executor
local function executor_origin(root,entry)
 local id=entry.wake and entry.wake.request_id
 local wake=if id then root.requests[entry.request.origin_binding.logical_session_id..'/'..id] else nil
 return if wake then wake.request.origin_binding else entry.request.origin_binding
end
local function outstanding(entry)
 return entry.body.status=='claimed' or entry.body.status=='launching' or entry.body.status=='uncertain' or entry.body.status=='pending' and entry.operation~=nil or entry.wake and (entry.wake.phase=='claimed' or entry.wake.phase=='launching' or entry.wake.phase=='uncertain')
end
local function missing(root,r)
 local s=root.sessions[r.logical_session_id]
 if root.authority_namespace==r.authority_namespace and s and s.admission_seq==r.admission_seq and r.request_serial<s.control.request_floor then return P.body(r,'already_consumed',nil,nil,'already_consumed') end
 return P.body(r,'uncertain',nil,nil,'unknown_effect')
end
-- Waiting notifications are bounded durable obligations, not execution permits.
local function wake_occupancy(root,handle)
 local total,same=0,0
 for _,entry in pairs(State.publications(root)) do
  if entry.wake and entry.wake.phase~='submitted' and (entry.wake.request_id~=nil or entry.wake.phase~='resolved') then
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
 local target=State.publication(root,r.logical_session_id,r.target_request_id)
 local w=target and target.wake
 if not w or w.request_id~=r.request_id or w.phase~='resolved' or w.claim then return end
 -- No native execution claim ever existed. Removing the exact reservation also
 -- rejects delayed wakeclaim events before a replacement can be authorized.
 w.request_id=nil
 entry.body=P.body(r,'full',{resource='native_wake_idle',current=1,limit=1,retryable=true,effect_started=false})
end
local function save(root,control,before_write,previous_revision)
 State.flush(root)
 local checked,problem=valid(root);if not checked then return false,problem end
 if previous_revision~=nil then
  -- Pure migration candidates already own their one next revision.
  if not P.integer(previous_revision,0) or previous_revision>=9007199254740991 or root.revision~=previous_revision+1 then return false,'Migration candidate revision differs from its captured source' end
 else
  if not P.integer(root.revision,0) or root.revision>=9007199254740991 then return false,'Transport revision exhausted; preserve the registry for recovery' end
  root.revision+=1
 end
 local ok,bytes=pcall(tern.json.encode,root)
 if not ok or #bytes>LIMIT-(if control then 0 else RESERVE) then return false,'Transport registry capacity exhausted; unresolved facts retained' end
 if before_write then
  local ready,accepted,why=pcall(before_write,root)
  if not ready or accepted~=true then return false,tostring(if ready then why else accepted),'refused' end
 end
 local stored,err=pcall(tern.kv.set,KEY,root)
 if not stored then hold='Transport commit failed; effects held. Inspect host storage before explicit recovery.';return false,hold,'uncertain' end
 qualification_snapshot=nil
 qualification_source_bytes=nil
 P.observe(root)
 if on_commit then on_commit() end
 return true
end
local mailbox_error=State.mailbox_error
local function authority_identity(binding)
 return binding.managed_authority_id or binding.authority_id
end
local function load(legacy)
 if hold then return nil,hold end
 local ok,root=pcall(tern.kv.get,KEY);if not ok then return nil,'Transport registry unreadable; preserve it' end
 if root==nil then
  local marked,marker=pcall(tern.kv.get,KEY..'-initialized')
  if not marked or marker~=nil then return nil,'Transport registry missing after initialization; restore it' end
  return nil,'Transport registry absent; explicit native Create is required before managed setup'
 end
 local checked,why=valid(root);if not checked then return nil,why end
 P.observe(root)
 if root.version==1 then return if legacy then P.clone(root) else nil,'migration_blocked: paired legacy stores require exact source preparation before managed mutation' end
 root=P.clone(root)
 P.observe(root)
 if root.migration then return root end
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
  for _,w in pairs(root.workers) do
   for _,p in pairs(w.wakes or {}) do if p.wake.phase=='claimed' or p.wake.phase=='launching' then p.wake.phase='uncertain' end end
  end
  root.controls={}
  root.mailboxes=Mailbox.recover(root.mailboxes)
  for id,g in pairs(root.gates) do if not g.consumed then root.gates[id]=nil;changed=true end end
  -- Recovery also preserves mailbox operation uncertainty and generation claims.
  local persisted,err=save(root,true);if not persisted then return nil,err end
  loaded=true
 end
 return root
end
local function capture_terminal(logical,id)
 local k=logical..'/'..id;local start=terminal_starts[k]
 if not start or not start.route or start.busy or start.ambiguous then return end
 local root=load();local target=root and State.worker(root,logical,id)
 if not target or target.body.status~='accepted' or target.stop_request_id or target.terminal_process then return end
 start.busy=true
 TerminalIdentity.capture(start.route,start.session,start.expected,function(proof)
  start.busy=false
  if not proof or not TerminalIdentity.valid(proof) or terminal_starts[k]~=start or start.ambiguous then return end
  local fresh=load();local current=fresh and State.worker(fresh,logical,id)
  if not current or current.body.status~='accepted' or current.stop_request_id or current.terminal_process or not P.equal(current.pane_binding,target.pane_binding) then return end
  current.terminal_process=proof
  local saved=save(fresh,true)
  if saved then terminal_starts[k]=nil end
 end)
end
local function terminal_reconnect(root,r)
 if r.op~='attach_worker' or r.attestation~='same_terminal_process_no_pending_effects' then return true end
 local target=State.worker(root,r.logical_session_id,r.target_request_id)
 if not target or not target.launch or target.launch.backend~='local-terminal' then return true end
 if not target.terminal_process then
  return false,'The retained terminal has no launch-time provider proof. Its conversation is preserved and held, never relaunched.'..(if tern.runtime.os=='macos' then ' Check the optional Python 3/ctypes/libproc capability in SPAWN → Required resources and capabilities. If absent, use your approved macOS Python 3 installer. This can qualify future launches, not retroactively certify this process.' else ' An old pane ID is not provider-process identity; new qualified launches record proof automatically.')
 end
 local identity=P.fingerprint({origin=r.origin_binding,proof=target.terminal_process,target=r.target_request_id})
 local k=key(r);local observed=terminal_checks[k]
 if observed and observed.identity==identity and observed.complete and tern.now()-observed.at<=5000 then return observed.passed,observed.error end
 if observed and observed.identity==identity and not observed.complete then return nil end
 local count=0
 for id,value in pairs(terminal_checks) do if value.complete and tern.now()-value.at>5000 then terminal_checks[id]=nil else count+=1 end end
 if count>=64 then return false,'Terminal process observations are busy; retain the original request and retry observation later' end
 observed={identity=identity,complete=false};terminal_checks[k]=observed
 TerminalIdentity.verify(target.terminal_process,function(passed,problem)
  if terminal_checks[k]~=observed then return end
  if problem then
   problem=tostring(problem):gsub("%z",""):sub(1,512)
   while utf8.len(problem)==nil and #problem>0 do problem=problem:sub(1,-2) end
   if problem=="" then problem="The current terminal process observation is unavailable" end
  end
  observed.complete=true;observed.passed=passed;observed.error=problem;observed.at=tern.now()
  if on_commit then on_commit() end
 end)
 if observed.complete then return observed.passed,observed.error end
 return nil
end
-- Capture only fresh native spawn metadata for one exact issued terminal command.
-- The filter never writes storage, changes argv or sends input.
tern.on('spawn',function(spec)
 if type(spec)~='table' or type(spec.args)~='table' then return nil end
 local selected
 for k,start in pairs(terminal_starts) do
  local matches=spec.cwd==start.cwd and spec.args[#spec.args]==start.command
  if matches then
   if selected then terminal_starts[selected].ambiguous=true;start.ambiguous=true;return nil end
   selected=k
  end
 end
 if not selected then return nil end
 local start=terminal_starts[selected]
 if start.route then start.ambiguous=true;return nil end
 local route=Native.from_spawn(spec)
 if route then
  start.route=route
 end
 return nil
end)
local function allocate(root,prefix)
 if root.next_id>=9007199254740991 then return nil end
 local id=prefix..'-'..Codec.sha256(root.namespace..':'..tostring(root.next_id)):sub(1,40)
 root.next_id+=1;return id
end
local function identity(record)
 return {backend=record.backend,provider=record.provider,account_label=record.account_label,identity_status='configured_not_verified',model=record.model,profile=record.profile,variant_id=record.variant_id,capacity_binding=record.capacity_binding,capacity_limit=record.capacity_limit}
end
local capability=Capabilities.eligibility
local function catalog(r,snapshot)
 local cursor=r.cursor
 if cursor and cursor.revision~=snapshot.config_revision then return P.reject(r,'binding_mismatch','Catalog revision changed; select again') end
 local records=tern.json.array();local first=if cursor then cursor.index else 1
 if first>#snapshot.records+1 then return P.reject(r,'invalid_schema','Invalid catalog cursor') end
 local payload={catalog_version=2,setup=P.clone(snapshot.setup),revision=snapshot.config_revision,config_revision=snapshot.config_revision,namespace=snapshot.namespace,host_key=snapshot.host_key,records=records}
 for index=first,#snapshot.records do
  local record=snapshot.records[index];local eligible,caps,reasons=capability(record,snapshot)
  caps=tern.json.array(caps);reasons=tern.json.array(reasons)
  local row={id=record.id,revision=snapshot.config_revision,provider=record.provider,provider_family=Config.provider_family(record.provider,record.provider_family),account_label=record.account_label,backend=record.backend,enabled=record.enabled,eligible=eligible,capabilities=caps,unsupported=reasons,capability_evidence='configured_transport_contract_not_provider_readiness',effective_identity=identity(record),cwd=record.cwd,placement=record.placement,model_variant=record.model,profile_variant=record.profile,selector_evidence=record.selector_evidence,capacity_binding=record.capacity_binding}
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
-- Ephemeral read observations, one bounded request per currently admitted session.
-- No inventory response grants cleanup authority or mutates effect journals.
local inventories={}
local function inventory(root,r)
 for logical in pairs(inventories) do if not root.sessions[logical] then inventories[logical]=nil end end
 local targets={}
 for handle,g in pairs(root.mailboxes.generations) do
  if g.status~='retired' and g.binding.logical_session_id==r.logical_session_id then
   table.insert(targets,{handle=handle,target=P.clone(g.target)})
  end
 end
 table.sort(targets,function(a,b)return a.handle<b.handle end)
 if #targets>32 then return P.reject(r,'oversize','Retained mailbox inventory exceeds the complete supported worker-set bound') end
 local identity=P.fingerprint({namespace=root.namespace,origin=r.origin_binding,targets=targets,stale_ms=r.stale_ms})
 local observed=inventories[r.logical_session_id]
 if observed and observed.identity==identity and observed.request_id==r.request_id then
  if observed.error then return P.reject(r,'target_unavailable',observed.error) end
  return P.body(r,if observed.result then 'inventory' else 'pending',P.clone(observed.result))
 end
 if observed and observed.pending and observed.identity==identity then return P.reject(r,'target_unavailable','A read-only inventory is already pending; poll its original request') end
 observed={identity=identity,request_id=r.request_id,pending=true}
 inventories[r.logical_session_id]=observed
 local total={observed_at_ms=os.time()*1000,open_files=0,stale_files=0,mailboxes=#targets}
 -- Match the existing mailbox executor's 30-second overall budget, not
 -- 32 serial 15-second children. Busy effect slots are waited for, never stolen.
 local started=tern.now();local index,completed,inflight=0,0,0
 local pumping,scheduled=false,false
 local function finish(problem)
  if inventories[r.logical_session_id]~=observed or not observed.pending then return end
  observed.pending=false;observed.error=problem
  if not problem then observed.result=total end
  if on_commit then on_commit() end
 end
 local pump
 local function schedule()
  if scheduled or not observed.pending then return end
  scheduled=true
  tern.timer(100,function() scheduled=false;pump() end)
 end
 pump=function()
  if pumping or inventories[r.logical_session_id]~=observed or not observed.pending then return end
  if tern.now()-started>=30000 then finish('Complete retained mailbox inventory exceeded its 30-second read-only budget; no partial counts were returned');return end
  pumping=true
  while observed.pending and index<#targets and inflight<4 and MailboxAdapter.inventory_capacity()>0 do
   local remaining=math.floor(30000-(tern.now()-started))
   if remaining<1 then finish('Complete retained mailbox inventory exceeded its read-only budget; no partial counts were returned');break end
   index+=1;inflight+=1
   local selected=targets[index]
   MailboxAdapter.inventory(selected.target,selected.handle,r.stale_ms,function(value,problem)
    inflight-=1
    if inventories[r.logical_session_id]~=observed or not observed.pending then return end
    if tern.now()-started>=30000 then finish('Complete retained mailbox inventory exceeded its read-only budget; no partial counts were returned');return end
    if problem or not value then finish(problem or 'Retained mailbox inventory is unavailable');return end
    total.observed_at_ms=math.min(total.observed_at_ms,value.observed_at_ms)
    total.open_files+=value.open_files;total.stale_files+=value.stale_files
    if total.open_files>1000000 then finish('Mailbox inventory exceeds the supported file bound');return end
    completed+=1
    if completed==#targets then finish(nil) else pump() end
   end,math.min(15000,remaining))
  end
  pumping=false
  if completed==#targets then finish(nil) elseif observed.pending then schedule() end
 end
 pump()
 if observed.error then return P.reject(r,'target_unavailable',observed.error) end
 return P.body(r,if observed.result then 'inventory' else 'pending',P.clone(observed.result))
end
local function allocation_observation(root,r)
 local function unknown(message,pending)
  return P.body(r,'uncertain',nil,{code=if pending then 'allocation_pending' else 'target_unavailable',message=message},'unknown_effect')
 end
 local function scoped(q)
  local origin=q.origin_binding
  return q.schema==2 and q.authority_namespace==r.authority_namespace and q.admission_seq==r.admission_seq
   and type(origin)=='table' and origin.logical_session_id==r.logical_session_id
   and origin.native_session_id==r.origin_binding.native_session_id and origin.window_host_id==r.origin_binding.window_host_id
   and (same_owner(origin,r.origin_binding) or retired_executor(root,origin))
 end
 local generation,problem,pending=Mailbox.allocation_generation(root.mailboxes,r.target)
 if generation and generation.phase=='retained' then
  if not scoped(generation.request) then return unknown('Retained provision lacks the original admitted authority/session/native-owner proof') end
  return P.body(r,'allocation',{target=P.clone(r.target),allocation={state='retained',provision=generation.provision}})
 end
 if not generation and problem~='missing' then return unknown(problem,pending) end
 -- A removed record is not absence proof. Inspect only exact retained native
 -- outcomes; consumed legacy refusals may be unobservable and stay unknown.
 local selected=nil
 for _,entry in pairs(root.requests) do
  local q=entry.request
  local relevant=if generation then q.op=='mailbox_retire' and q.handle==generation.handle else q.op=='mailbox_provision' or q.op=='mailbox_retire'
  if relevant and Mailbox.matches_allocation(q,r.target) then
   if selected then return unknown('Multiple retained provisioning/retirement requests match this generation') end
   if not scoped(q) then return unknown('Matching journal belongs to another admitted authority/session/native owner') end
   selected=entry
  end
 end
 if not selected then return unknown('No exact settled provisioning or completed-retirement proof remains') end
 local q=selected.request
 if selected.authorization~=nil or selected.body.status=='pending' or selected.body.status=='uncertain' or selected.retirement_result~=nil then return unknown('Matching helper or native settlement is still pending or uncertain') end
 local retired=q.op=='mailbox_retire' and q.mode=='retire' and selected.body.status=='retired' and selected.operation~=nil
  and (not generation or q.handle==generation.handle)
 local unallocated=not generation and q.op=='mailbox_provision' and selected.operation==nil
  and (selected.body.status=='rejected' or selected.body.status=='full' and selected.body.payload and selected.body.payload.retryable==true and selected.body.payload.effect_started==false)
 if retired or unallocated then return P.body(r,'allocation',{target=P.clone(r.target),allocation={state='none'}}) end
 return unknown('The exact retained journal does not prove allocation absence or completed retirement')
end
local function owner(root,r,binding,session,_reserve)
 local s,why=State.admission(root,r);if not s then return false,why end
 local c=s.control
 if c.phase~='open' or c.recovery then return false,'stale_binding' end
 if s.authority~=authority_identity(binding) or s.host_session~=session or not P.equal(c.binding,r.origin_binding) then return false,'stale_binding' end
 if r.request_serial and r.request_serial<c.request_floor then return false,'already_consumed' end
 return true
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
 return {record_id=r.record_id,record_revision=r.record_revision,effective_identity=entry.identity,capabilities=entry.capabilities,pane_binding=entry.pane_binding,prompt_delivery=if not entry.pane_binding then 'not_submitted' elseif r.op=='enrol' and r.delivery=='clipboard' then 'copied_not_accepted' else 'submitted_not_accepted'}
end
-- Shared by fresh launch and explicit adoption: the validated record/mailbox enrolment and the exact
-- private transport preface followed by the unchanged assignment bytes. Failure returns nil,code,message.
local function enrolment_brief(root,r,snapshot)
 local record,why=find_record(snapshot,r.record_id,r.record_revision)
 if not record then return nil,'binding_mismatch',why end
 local eligible,caps,reasons=capability(record,snapshot)
 if not eligible then return nil,'unsupported_capability',table.concat(reasons,'; ') end
 if r.op=='launch' then
  local tab=r.presentation=='user_new_tab' or r.presentation=='coordinator_adjacent'
   or r.presentation=='background' and record.backend~='native-agent' and record.placement=='replace_if_alone'
    and r.enrolment.handover_id~=nil and r.enrolment.handover_token~=nil
  if r.cwd~=(r.execution_cwd or record.cwd) or r.placement~=(if tab then 'tab' else record.placement) then return nil,'binding_mismatch','Requested cwd/placement is not the authorized launch allowance' end
 end
 if r.op=='adopt' and record.backend~='native-agent' then return nil,'unsupported_capability','Adoption delivers the assignment by native ask; only native-agent records can enrol an existing agent pane' end
 if r.op=='enrol' then
  if r.prompt~=Codec.OPEN_CONVERSATION_ASSIGNMENT then return nil,'content_conflict','Enrollment adds only the canonical enrollment instructions, never an existing task' end
  if record.user and record.user~='' then return nil,'unsupported_capability','Existing conversation enrollment requires a same-user record; a pane does not prove an OS account route' end
  if (r.delivery=='native_ask' and record.backend~='native-agent') or (r.delivery=='clipboard' and record.backend~='local-terminal') then return nil,'unsupported_capability','Enrollment delivery must match the native agent or same-user terminal route' end
 end
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
  ..'Helper argv: POSIX sh,producer_helper,root,mailbox_handle,enrolment_token,mode; Windows powershell.exe -NoProfile -File producer_helper -Root: root -Handle: mailbox_handle -Owner: enrolment_token -Mode: mode. Each colon-ended name and its literal value are separate argv elements. Invoke init once for a new journal BEFORE reporting ACCEPTED; never reinitialize an existing journal, use replay to restore. report reads {kind,payload,action_id?,action_revision?,handover_id?,handover_token?} stdin; supplies BE/seq/event_id. Emit ACCEPTED {assignment_sha256}, with paired handover only if supplied. Copy handover_id and handover_token verbatim from the report-files-v1 JSON above; never retype them. The helper verifies them against the provisioned handover digest and refuses a mismatch before publishing, naming the field; then report ACCEPTED again with the exact values. Check receipts/consume at checkpoints. With native-ask-v1, end the initial turn immediately after ACCEPTED and return idle before awaiting ACK/control; native notifications require idle. On notification drain receipts and consume. Once the producer journal confirms ACCEPTED acknowledged, continue this original authorized assignment; do not wait for another assignment reply. Required typed coordinator activation, landing grants and other control gates still apply. Return idle only when awaiting future control; never keep the turn open polling or calling wait for another notification. Only worker-poll-v1 uses bounded wait while awaiting control. reply_ack precedes effects; claim/resolve retain uncertainty. Never reset or retry uncertain effects.\n'
 brief..='Control helper arguments: consume prints the exact typed reply JSON, including message_id, and durably publishes reply_ack. Keep that returned JSON. To claim it, invoke the same helper argv with mode claim and append that exact message_id as the next POSIX argument; on Windows use -Mode claim -MessageId followed by that exact message_id. Once the granted work is actually quiescent, resolve uses the identical arguments with mode resolve instead. Do not confuse message_id with action_id or reply_seq. These commands are silent on success; errors are not permission to repeat an uncertain effect. No helper-source inspection is needed to discover this command syntax.\n'
 brief..='Runtime context reporting: READY/HEARTBEAT/CHECKPOINT may include context_snapshot={current_tokens,window_tokens,observed_at_ms,first_turn_tokens?}; use actual runtime occupancy/capacity in whole tokens and the original measurement Unix time in milliseconds on this execution host. Capture first-turn occupancy for this exact conversation/generation after its first turn (including startup instructions), retain that baseline/window unchanged, and include it when known. Never derive it from billed input/output totals, cumulative usage, transcript length or guesses. Alternatively context_used_pct is an actual current whole runtime percentage0..100, never an estimate; do not send both fields. Percent-only supports numerical overrides, not the default current>=first_turn+0.55*(window-first_turn). Omit unavailable measurements; missing READY/HEARTBEAT context is unknown. CHECKPOINT may retain a preceding fresh measurement. Workers wait for the next completed-work checkpoint after threshold; coordinators do not wait for that boundary. All exact idle/in-flight/activation/retirement guards still apply, and rollover starts only on the issued host request. No SDK measurement support is implied by this transport.\n'
 brief..='Fresh-session suggestion: use the FIRST matching rule. (1) If context appears poisoned, such as reviving an already corrected assumption, suggest a fresh session immediately, name the symptom, and label suspicion as suspicion. (2) Otherwise workers evaluate measured renewal only at a completed checkpoint; coordinators evaluate it immediately at threshold, with no checkpoint wait. Use the measured first-turn plus55%-of-remaining-headroom rule or explicit numerical override; unavailable runtime measurement is unknown, never estimated. (3) Otherwise continue; task/checkpoint completion alone is not a reason. A suggestion grants no restart authority and bypasses no checkpoint, activation, retirement or in-flight-effect guard.\n'
 if r.op=='enrol' then brief='ENROLLMENT ONLY: preserve all existing task, conversation and context. Do not replay or replace earlier instructions. This message adds only the scoped report channel; copying it does not establish acceptance.\n'..brief end
 brief..=if r.enrolment.coordinator_owner_id then 'Your transport role is coordinator: await the exact typed coordinator_activation described below before coordinator work.\n'
  else 'Your transport role is an ordinary worker, NOT a coordinator. Do not wait for coordinator_activation. A coordinator-control-v1 capability alone does not confer that role. After ACCEPTED is acknowledged, perform the original assignment within its existing authority. Review work still requires its review_request; landing and deployment still require their exact typed grants. No transport notification authorizes unrelated work.\n'
 if r.enrolment.coordinator_owner_id then
  brief..='COORDINATOR TRANSPORT ROLE: '..tern.json.encode({owner_id=r.enrolment.coordinator_owner_id,owner_generation=r.enrolment.coordinator_generation})..'\n'
   ..'Acknowledge the exact assignment bytes with ACCEPTED first, but do not perform coordinator work yet. Await control using the enrolled transport rule above, then drain receipts and consume the typed coordinator_activation reply for this exact owner/generation. The consumer durably records reply_ack before returning it; claim that exact reply before coordinator work. Retain its action ID/revision and activation token. Never independently orchestrate Tern. When the assigned task finishes or typed retirement requests stop, quiesce and report COORDINATOR_RELEASE with that owner/generation/token, quiescent:true and the activation (or issued retirement) action ID/revision. Idle alone is not task completion. Continue draining committed replies and receipts, including a delayed coordinator_retirement, without starting fresh work; native stop and mailbox retirement belong to ORCH+/SPAWN. The role and token are protocol fencing, not OS/account isolation.\n'
   ..'Before final retirement, resolve each claimed control message through the helper once its work is actually quiescent; keep the grant IDs/token in your working context. Drain all final report receipts and committed reply acknowledgements. Unclaimed, claimed or uncertain execution journal entries prevent mailbox retirement and must never be erased or falsely marked resolved. SPAWN clears only the exact settled producer journal after observing native stop.\n'
  if table.find(caps,'project-start-v1') then
   brief..='Typed project_start is a data-only owner approval, never an instruction to launch or merge. After activation, consume and locally claim its exact message_id through the same helper route. Verify owner_id/owner_generation/activation_token match your retained activation. Report PROJECT_START_CLAIM once with the reply action_id/action_revision in the report header and exactly the six received payload fields owner_id,owner_generation,activation_token,orch_project_id,project_revision,decision_context. Await the actual committed acceptance receipt before treating the project as started; reply_ack or local claim alone is not acceptance. The host alone releases the approved held snapshot. Resolve the project_start message only after its claim has been accepted and the control operation is quiescent; preserve uncertain entries and never invent a replacement grant.\n'
  end
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
 if record.backend=='local-terminal' and (not record.user or record.user=='') then
  local active=0
  for id,start in pairs(terminal_starts) do
   local retained=State.worker(root,start.logical,start.request_id)
   if not retained or retained.stop_request_id or retained.terminal_process or retained.body.status=='rejected' then terminal_starts[id]=nil else active+=1 end
  end
  if active<64 then
   local argv=table.clone(record.fresh_arguments or {})
   table.insert(argv,record.task_argument_index,brief)
   terminal_starts[key(r)]={logical=r.logical_session_id,request_id=r.request_id,command=built.command,cwd=built.cwd,session=binding.native_session,expected={executable=record.fresh_executable,arguments=argv}}
  end
 end
 entry.observer_id='managed-'..Codec.sha256(key(r));entry.attempt_pending=true
 local persisted,persist_error=save(root,false)
 if not persisted then return P.reject(r,'storage_error',persist_error) end
 local attempt,attempt_error=Authority.managed_reserve(binding,r.record_revision,r.record_id,entry.observer_id)
 if not attempt then entry.attempt_pending=nil;return finish(root,entry,P.reject(r,'target_unavailable',attempt_error),false) end
 entry.attempt_id=attempt.id;entry.attempt_pending=nil
 return finish(root,entry,P.body(r,'resolved',launch_payload(entry)),false)
end
-- Existing conversation enrollment never starts an agent or replaces its context.
-- Retained adopt requests keep their original native delivery contract.
local function adopt_prepare(root,entry,binding,snapshot)
 local r=entry.request;local p,b=r.pane_binding,r.origin_binding
 if p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id then
  return finish(root,entry,P.reject(r,'binding_mismatch','Adopted pane must belong to the exact controller window, native session and host'),false)
 end
 for _,other in pairs(State.each_worker(root)) do
  if other~=entry and launched(other) and other.body.status~='rejected' then
   local stop=if other.stop_request_id then root.requests[other.request.origin_binding.logical_session_id..'/'..other.stop_request_id] else nil
   local bound=select(3,route(other)) or (if other.request.op=='adopt' or other.request.op=='enrol' then other.request.pane_binding else nil)
   if bound and P.equal(bound,p) and not other.stopped and not (stop and stop.body.status=='stopped') then
    return finish(root,entry,P.reject(r,'binding_mismatch','This exact pane is already bound to a managed worker generation; it is never adopted twice'),false)
   end
  end
 end
 local record,caps,brief=enrolment_brief(root,r,snapshot)
 if not record then return finish(root,entry,P.reject(r,caps,brief),false) end
 entry.launch={backend=record.backend,adopt=if r.op=='adopt' then true else nil,enrol=if r.op=='enrol' then true else nil,prompt=brief};entry.launch_sha256=P.fingerprint(entry.launch)
 entry.identity=identity(record);entry.capabilities=caps;entry.binding=P.clone(binding)
 entry.observer_id='managed-'..Codec.sha256(key(r))
 return finish(root,entry,P.body(r,'resolved',launch_payload(entry)),false)
end
local function accept(root,entry)
 local r=entry.request;local target=State.worker(root,r.logical_session_id,r.target_request_id)
 if not launched(target) then return finish(root,entry,P.reject(r,'binding_mismatch','Launch request not found'),true) end
 if target.mailbox_live==false then return finish(root,entry,P.reject(r,'binding_mismatch','Enrollment capability has been retired'),true) end
 if (target.request.op=='enrol' or target.request.op=='launch') and not target.acceptance then
  for _,pending in pairs(root.requests) do
   local q=pending.request
   if q.op=='mailbox_retire' and q.mode=='retire' and q.logical_session_id==r.logical_session_id and q.launch_request_id==target.request.request_id and pending.body.status~='rejected' then
    return finish(root,entry,P.reject(r,'target_unavailable','Enrollment cancellation is settling; preserve its exact outcome'),true)
   end
  end
 end
 local t=target.request;local e=t.enrolment
 if not routed(target,r) or t.action_id~=r.target_action_id or not P.equal(select(3,route(target)),r.pane_binding) or e.worker_id~=r.worker_id or e.worker_generation~=r.worker_generation or e.enrolment_token~=r.enrolment_token or t.work_id~=r.work_id or e.handover_id~=r.handover_id or e.handover_token~=r.handover_token then return finish(root,entry,P.reject(r,'binding_mismatch','Acceptance differs from launch contract'),true) end
 if r.event_id~=Codec.sha256(t.mailbox_handle..':report:'..string.format('%.0f',r.seq)) then return finish(root,entry,P.reject(r,'binding_mismatch','Acceptance event ID differs from its mailbox sequence'),true) end
 local receipt={event_id=r.event_id,seq=r.seq,event_sha256=r.event_sha256}
 if target.acceptance and not P.equal(target.acceptance,receipt) then return finish(root,entry,P.reject(r,'content_conflict','Acceptance event changed'),true) end
 if target.body.status~='awaiting_acceptance' and target.body.status~='accepted' then return finish(root,entry,P.reject(r,'binding_mismatch','Launch has no confirmed pane association'),true) end
 target.acceptance=receipt;target.body=if target.request.schema then P.body(t,'accepted',launch_payload(target)) else {status='accepted'}
 local body=finish(root,entry,P.body(r,'accepted',{target_request_id=t.request_id,pane_binding=target.pane_binding}),true)
 capture_terminal(t.logical_session_id,t.request_id)
 return body
end
local function stop_target(root,r)
 local target=State.worker(root,r.logical_session_id,r.target_request_id)
 if not launched(target) or target.body.status~='accepted' or not target.acceptance or not target.launch then return nil end
 local t=target.request;local e=t.enrolment;local p=r.pane_binding;local b=r.origin_binding
 if not routed(target,r) or t.action_id~=r.target_action_id or not P.equal(select(3,route(target)),p) or e.worker_id~=r.worker_id or e.worker_generation~=r.worker_generation or e.enrolment_token~=r.enrolment_token or t.work_id~=r.work_id then return nil end
 if p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id then return nil end
 return target
end
local function stop_prepare(root,entry)
 local r=entry.request;local target=stop_target(root,r)
 if not target then return finish(root,entry,P.reject(r,'binding_mismatch','Stop differs from the exact accepted managed launch'),true) end
 if target.stopped then return finish(root,entry,P.reject(r,'target_unavailable','Current worker is already stopped; no native stop is issued'),true) end
 if target.stop_request_id and target.stop_request_id~=r.request_id then return finish(root,entry,P.reject(r,'binding_mismatch','This launch already has an exclusive stop intent; reconcile that request, never repeat stop'),true) end
 if target.request.enrolment.coordinator_owner_id and not table.find(target.capabilities or {},'coordinator-control-v1') then return finish(root,entry,P.reject(r,'unsupported_capability','The issued coordinator launch did not provision coordinator-control-v1'),true) end
 for _,other in pairs(State.publications(root)) do
  if other.wake and other.request.launch_request_id==r.target_request_id and other.request.origin_binding.logical_session_id==r.origin_binding.logical_session_id and other.wake.phase~='submitted' then return finish(root,entry,P.reject(r,'target_unavailable','Native wake notification remains unresolved; drain it before stop'),true) end
 end
 target.stop_request_id=r.request_id
 entry.binding=P.clone(target.binding);entry.stop_backend=target.launch.backend
 return finish(root,entry,P.body(r,'resolved'),true)
end
local function stopped_cleanup(root,launch,r)
 if not launch or not launch.stopped or (r.op~='mailbox_read' and not (r.op=='mailbox_retire' and r.mode=='retire')) then return false end
 local s=root.sessions[r.logical_session_id]
 return s~=nil and s.control.phase=='open' and P.equal(s.control.binding,r.origin_binding) and retired_executor(root,select(1,route(launch)))
end
local function startup_route(root,launch,r)
 if not launch or launch.request.op~='launch' then return false end
 local original=launch.request.origin_binding;local current=r.origin_binding
 local session=root.sessions[r.logical_session_id]
 return session~=nil and session.control.phase=='open' and P.equal(session.control.binding,current)
  and original.window_key==current.window_key and original.native_session_id==current.native_session_id
  and original.window_host_id==current.window_host_id
  and (same_owner(original,current) or retired_executor(root,original))
end
-- Zero floors/initial chain let the existing producer helper prove this capability
-- was never consumed. A fresh coordinator launch also requires a native window witness.
local function pending_unaccepted_retirement(root,launch,r)
 if r.op~='mailbox_retire' or r.mode~='retire' or not launch or launch.body.status~='awaiting_acceptance'
  or launch.acceptance~=nil or launch.stop_request_id~=nil or r.report_floor~=0 or r.reply_floor~=0
  or r.report_chain_sha256~=Codec.sha256('report-files-v1\n'..r.handle..'\n') then return false end
 if launch.request.op=='enrol' then return routed(launch,r) end
 local p,b=launch.pane_binding,r.origin_binding
 return launch.request.op=='launch' and launch.request.enrolment.coordinator_owner_id~=nil
  and launch.launch~=nil and (launch.launch.backend=='native-agent' or launch.launch.backend=='local-terminal')
  and launch.attachment==nil and p~=nil and startup_route(root,launch,r)
  and p.window_key==b.window_key and p.native_session_id==b.native_session_id and p.window_host_id==b.window_host_id
end
-- This private witness arrives only with the exact nonce-bound window authorization.
-- HOST has no WindowCx; it never invents pane lifecycle from a process callback.
local function startup_witness(root,launch,r,observation)
 return pending_unaccepted_retirement(root,launch,r) and launch.request.op=='launch'
  and P.fields(observation,{pane_binding=P.pane,observation=function(v)return v=='absent' or v=='exited'end})
  and P.equal(observation.pane_binding,launch.pane_binding)
  and (launch.pane_binding.window_epoch==r.origin_binding.window_epoch or observation.observation=='absent')
end
local function retire_launch(root,entry)
 local r=entry.request
 local launch=State.worker(root,r.logical_session_id,r.launch_request_id)
 if not launch or not launch.stopped and not pending_unaccepted_retirement(root,launch,r) then return nil,'Exact native stop or unaccepted cancellation evidence is missing' end
 local t=launch.request;local e=t.enrolment
 if t.mailbox_handle~=r.handle or not (routed(launch,r) or stopped_cleanup(root,launch,r) or pending_unaccepted_retirement(root,launch,r)) or t.work_id~=r.work_id or e.worker_id~=r.worker_id or e.worker_generation~=r.worker_generation or e.worker_generation~=r.expected_generation or e.enrolment_token~=r.enrolment_token then return nil,'Mailbox retirement differs from the stopped launch' end
 return launch
end
local function settle_reservation(root,entry)
 local launch,why=retire_launch(root,entry)
 if not launch then return finish(root,entry,P.body(entry.request,'uncertain',nil,{code='binding_mismatch',message=why}),true) end
 -- Adoption reserved no managed launch attempt; a fresh launch settles its exact reservation.
 if launch.request.op=='launch' then
  local ok,err=Authority.managed_retire(launch.binding,launch.attempt_id,launch.observer_id,launch.request.record_id,tonumber(launch.pane_binding.pane_id))
  if not ok then return finish(root,entry,P.body(entry.request,'uncertain',nil,{code='storage_error',message=tostring(err):sub(1,512)}),true) end
 end
 local body=entry.retirement_result;entry.retirement_result=nil
 launch.mailbox_live=false
 return finish(root,entry,body,true)
end
local function attach_worker(root,entry,binding,session)
 local r=entry.request
 local target=State.worker(root,r.logical_session_id,r.target_request_id)
 if not launched(target) or not target.pane_binding or target.stop_request_id or (target.body.status~='accepted' and target.body.status~='awaiting_acceptance') then return finish(root,entry,P.reject(r,'binding_mismatch','Attachment requires the retained launched worker without a stop intent'),true) end
 local t=target.request;local e=t.enrolment;local p=r.pane_binding;local b=r.origin_binding
 if t.logical_session_id~=b.logical_session_id or not P.equal(select(1,route(target)),r.previous_origin_binding) or not P.equal(select(3,route(target)),r.previous_pane_binding) or t.action_id~=r.target_action_id or t.work_id~=r.work_id or e.worker_id~=r.worker_id or e.worker_generation~=r.worker_generation or e.enrolment_token~=r.enrolment_token or p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id then return finish(root,entry,P.reject(r,'binding_mismatch','Attachment differs from current worker route or explicitly selected pane'),true) end
 local automatic=r.attestation=='same_native_conversation_no_pending_effects' or r.attestation=='same_terminal_process_no_pending_effects'
 if automatic then
  if r.attestation=='same_native_conversation_no_pending_effects' and target.launch.backend~='native-agent' or r.attestation=='same_terminal_process_no_pending_effects' and target.launch.backend~='local-terminal' then return finish(root,entry,P.reject(r,'binding_mismatch','Automatic continuation evidence must match the retained native/terminal backend'),true) end
  if r.attestation=='same_terminal_process_no_pending_effects' then
   local verified,problem=terminal_reconnect(root,r)
   if verified~=true then return finish(root,entry,P.reject(r,'target_unavailable',problem or 'Fresh exact terminal process observation is still pending; the conversation remains held'),true) end
  end
  local old=r.previous_pane_binding;local old_origin=r.previous_origin_binding
  if target.body.status~='accepted' or old.pane_id~=p.pane_id or old.native_session_id~=p.native_session_id or old.window_key~=p.window_key or old.window_host_id~=p.window_host_id or old_origin.native_session_id~=b.native_session_id or old_origin.window_host_id~=b.window_host_id or old_origin.window_key~=b.window_key then
   return finish(root,entry,P.reject(r,'binding_mismatch','Automatic reconnect requires the exact accepted native conversation on the same host, window and session'),true)
  end
 end
 for _,other in pairs(root.requests) do
  if automatic and other~=entry and other.request.origin_binding.logical_session_id==b.logical_session_id and outstanding(other) then return finish(root,entry,P.reject(r,'target_unavailable','Automatic reconnect cannot transfer a claimed or uncertain effect'),true) end
  if other~=entry and other.request.origin_binding.logical_session_id==b.logical_session_id and outstanding(other) and not retired_executor(root,executor_origin(root,other)) then return finish(root,entry,P.reject(r,'target_unavailable','Inspect original outcomes, then fence and confirm stopped executors in SPAWN Config before attachment; unknown outcomes are not retried'),true) end
 end
 for _,other in pairs(State.publications(root)) do
  if automatic and other.request.origin_binding.logical_session_id==b.logical_session_id and outstanding(other) then return finish(root,entry,P.reject(r,'target_unavailable','Automatic reconnect awaits the original publication outcome'),true) end
  if other.request.origin_binding.logical_session_id==b.logical_session_id and outstanding(other) and not retired_executor(root,executor_origin(root,other)) then return finish(root,entry,P.reject(r,'target_unavailable','Current native wake outcome remains unresolved'),true) end
 end
 -- Revoke old unconsumed challenges. Never transfer an earlier effect claim.
 for _,other in pairs(root.requests) do
  if other~=entry and other.request.origin_binding.logical_session_id==b.logical_session_id and not P.equal(other.request.origin_binding,b) then fence_unstarted_wake(root,other) end
  if other~=entry and other.request.origin_binding.logical_session_id==b.logical_session_id and not P.equal(other.request.origin_binding,b) and other.authorization then
   local a=other.authorization
   other.authorization_fence={nonce=a.nonce,phase=a.phase,bridge=a.bridge,executor=a.window_executor}
   other.authorization=nil
   if a.phase=='requested' then other.body=a.base_body or P.reject(other.request,'authorization_revoked','Attachment fenced the old window challenge')
   elseif not automatic then other.body=P.body(other.request,'uncertain') end
  end
 end
 target.attachment={origin_binding=P.clone(b),controller_pane=r.controller_pane,pane_binding=P.clone(p)}
 root.sessions[b.logical_session_id].control.binding=P.clone(b)
 root.sessions[b.logical_session_id].controller_pane=r.controller_pane
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
 local launch=State.worker(root,r.logical_session_id,r.launch_request_id)
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
 for _,other in pairs(State.publications(root)) do
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
 local target=State.publication(root,r.logical_session_id,r.target_request_id)
 if not target or not target.wake or target.request.action_id~=r.target_action_id or (target.body.status~='published' and target.body.status~='already_published') then return nil end
 local launch=State.worker(root,r.logical_session_id,target.request.launch_request_id)
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
-- Only a retained terminal pre-effect refusal proves the launch never started.
-- Expiry or an absent claim in a restored snapshot is not negative effect evidence.
local function unexecuted_launch(entry)
 if not launched(entry) or entry.pane_binding~=nil or entry.attachment~=nil or entry.stop_request_id~=nil or entry.acceptance~=nil then return false end
 return entry.body.status=='rejected'
end
local function mailbox(root,entry,snapshot,changed,native_observation)
 local r=entry.request;local record=nil
 if entry.retirement_result then return settle_reservation(root,entry) end
 local launched=State.worker(root,r.logical_session_id,tostring(r.launch_request_id))
 -- Retiring the unused mailbox of a rejected launch binds to no pane, so it needs no attachment.
 local unused=r.op=='mailbox_retire' and r.mode=='retire' and unexecuted_launch(launched)
 if launched and (launched.request.op=='launch' or launched.request.op=='adopt' or launched.request.op=='enrol') and not routed(launched,r) and not unused and not stopped_cleanup(root,launched,r) and not pending_unaccepted_retirement(root,launched,r) then return finish(root,entry,P.reject(r,'binding_mismatch','Worker requires explicit attachment or positively stopped-generation cleanup'),true) end
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
  for _,other in pairs(State.publications(root)) do
   local q=other.request
   if other.wake and q.handle==r.handle then
    if other.wake.phase~='submitted' then count+=1 end
    if q.op==r.op and (r.op=='mailbox_publish_ack' and q.ack_sha256==r.ack_sha256 or r.op=='mailbox_publish_reply' and q.reply_sha256==r.reply_sha256 and q.reply_seq==r.reply_seq) then duplicate=true end
   end
  end
  if count>=32 and not duplicate and not entry.operation then return finish(root,entry,P.body(r,'full',{resource='wake_obligations',current=count,limit=32,retryable=true,effect_started=false}),true) end
 end
 if r.op=='mailbox_retire' and r.mode=='retire' then
  local issued=State.worker(root,r.logical_session_id,r.launch_request_id)
  if r.withdrawn_starts~=nil and (not issued or not issued.stopped or not issued.acceptance
   or issued.request.op~='launch' or not issued.request.enrolment.coordinator_owner_id) then
   return finish(root,entry,P.reject(r,'binding_mismatch','Withdrawn START retirement requires the exact accepted coordinator and positive native stopped evidence'),true)
  end
  if issued and not unused then
   local target,why=retire_launch(root,entry)
   if not target then return finish(root,entry,P.reject(r,'binding_mismatch',why),true) end
  end
  if issued and not unused and issued.request.op=='launch' and not issued.stopped and not startup_witness(root,issued,r,native_observation) then
   return finish(root,entry,P.reject(r,'binding_mismatch','Failed startup requires fresh exact-window native exit or absence; nothing was retired'),true)
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
 local issued=State.worker(root,r.logical_session_id,r.launch_request_id)
 if issued and (issued.request.op=='launch' or issued.request.op=='adopt' or issued.request.op=='enrol') then
  local enrolment=issued.request.enrolment
  op.binding.assignment_sha256=enrolment.assignment_sha256
  op.binding.handover_id=enrolment.handover_id;op.binding.handover_token=enrolment.handover_token
  op.binding.capabilities=P.clone(issued.capabilities)
 elseif r.op=='mailbox_read' and r.selector.stream=='report' then
  return finish(root,entry,P.reject(r,'binding_mismatch','Report reads require the issued immutable launch contract'),true)
 end
 -- Native stop or verified failed-startup exit permits producer cleanup; pending
 -- enrollment only revokes its unused capability without touching its conversation.
 if r.op=='mailbox_retire' and r.mode=='retire' and issued and (issued.stopped or pending_unaccepted_retirement(root,issued,r)) then
  local stopped,why=retire_launch(root,entry)
  if not stopped then return finish(root,entry,P.reject(r,'binding_mismatch',why),true) end
  op.retire_producer=true
  op.cancel_enrolment=pending_unaccepted_retirement(root,issued,r) or nil
 end
 root.mailboxes=next_registry;entry.operation=op.id or operation_id
 entry.body=P.body(r,'pending',{operation_id=operation_id})
 local stored,why=save(root,r.op~='mailbox_provision')
 if not stored then return P.reject(r,'storage_error',why) end
 Mailbox.execute(op,function(outcome)
  local latest,load_error=load();if not latest then changed(P.reject(r,'storage_error',load_error));return end
  local current=latest.requests[key(r)]
  if not current or current.operation~=entry.operation or not P.equal(current.request,r) then return end
  local current_owner=State.owner(latest,r.logical_session_id)
  if not current_owner or current_owner.recovery_revision or not P.equal(current_owner.binding,r.origin_binding) then return end
  local next_mail,settled=Mailbox.settle(latest.mailboxes,op,outcome)
  if not next_mail then changed(P.reject(r,'storage_error',mailbox_error(settled)));return end
  latest.mailboxes=next_mail
  if settled.status=='full' and settled.payload and settled.payload.retryable==true and settled.payload.effect_started==false then
   -- The child has exited and the generation claim was settled as a proven
   -- pre-effect admission refusal. Exact replay needs a new live window grant.
   current.operation=nil
  end
  if r.op=='mailbox_retire' and settled.status=='retired' then
   local issued=State.worker(latest,r.logical_session_id,r.launch_request_id)
   if issued and (issued.stopped or pending_unaccepted_retirement(latest,issued,r)) then
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
-- An expired/restored challenge is not proof of a missing effect. Preserve unknown
-- until the peer's current admitted action and irreversible witness reconcile it.
local function staged_outcome(entry)
 local a=entry.authorization
 if not a or a.phase~='requested' or live_challenge(a) then return entry.body end
 return P.body(entry.request,'uncertain',nil,nil,'unknown_effect')
end
-- Public writes first wait for a fresh, exact window-observed ORCH+ action.
-- The nonce is issued only AFTER asynchronous host-membership verification.
function M.stage(r,binding,session,bridge,request_json,relay_binding)
 if r.setup_origin then return P.reject(r,'binding_mismatch','Setup catalog is read-only and cannot acquire execution authority') end
 local available,preparation_error=preparation_admission(r,binding)
 if not available then return P.reject(r,'target_unavailable',preparation_error) end
 if relay_binding~=nil and (not P.digest(relay_binding) or not P.integer(bridge,1)) then return P.reject(r,'binding_mismatch','Exact trusted relay endpoint required') end
 if relay_binding~=nil then
  local source=r.origin_binding or r.control_origin and r.control_origin.binding
  if not source or source.host_pane_id~=tostring(bridge) then return P.reject(r,'binding_mismatch','Relay endpoint must be the actual admitted ORCH host source pane') end
 end
 -- owner_status is a read-only admission view: answered for any same-session binding, never staged or authorized.
 if r.op=='owner_status' or r.op=='mailbox_inventory' or r.op=='mailbox_allocation' then return M.request(r,binding,session,function()end) end
 local root,why=load(State.control_request(r));if not root then return P.reject(r,'migration_blocked',why) end
 if State.control_request(r) then
  if not P.equal(P.decode(request_json),r) then return P.reject(r,'invalid_schema','Exact immutable control bytes required') end
  for id,c in pairs(control_challenges) do if c.boot~=boot or c.deadline<tern.now() then control_challenges[id]=nil end end
  local prior=control_challenges[r.request_id]
  if prior and not P.equal(prior.request,r) then return P.reject(r,'stale_revision','Control request identity changed') end
  if prior and prior.relay_binding~=relay_binding then return P.reject(r,'binding_mismatch','Control challenge belongs to another relay incarnation') end
  if not prior then
   local nonce=native_claim(root,'control').claim_nonce
   control_challenges[r.request_id]={request=P.clone(r),request_json=request_json,nonce=nonce,boot=boot,bridge=bridge,relay_binding=relay_binding,binding=P.clone(binding),session=session,deadline=tern.now()+30000}
  end
  return nil
 end
 local admitted,err=owner(root,r,binding,session,false)
 if not admitted then return if err=='already_consumed' then P.body(r,'already_consumed',nil,nil,'already_consumed') else P.reject(r,err,'Current admitted authority and binding required') end
 if not P.equal(P.decode(request_json),r) then return P.reject(r,'invalid_schema','Exact immutable issued bytes required') end
 local entry=root.requests[key(r)]
 if entry and not P.equal(entry.request,r) then return P.reject(r,'content_conflict','Request ID reused with changed content') end
 if entry and entry.relay_binding~=relay_binding then return P.reject(r,'binding_mismatch','Retained request belongs to another transport incarnation; reconcile its outcome without reissuing it') end
 if not entry then
  local verified,problem=terminal_reconnect(root,r)
  if verified==nil then return P.body(r,'pending') end
  if verified==false then return P.reject(r,'target_unavailable',problem or 'The retained terminal process is not currently verified') end
 end
 if not entry and (r.op=='launch' or r.op=='adopt' or r.op=='enrol') and root.workers[key(r)] then return P.reject(r,'stale_binding','Current worker already owns this launch identity; a new serial cannot relaunch it') end
 if not entry then
  for _,other in pairs(root.requests) do
   local q=other.request
   if q.logical_session_id==r.logical_session_id and q.admission_seq==r.admission_seq and q.request_serial==r.request_serial then return P.reject(r,'stale_binding','Issued serial already belongs to another immutable request') end
  end
 end
 if entry and entry.authorization then
  local a=entry.authorization
  if a.phase=='consumed' then return entry.body end
  -- Duplicate/status panels must not replace a live nonce or steal its bridge.
  if a.boot==boot and a.deadline>=tern.now() then return entry.body end
  if relay_binding~=nil then return P.reject(r,'binding_mismatch','Expired relay consent cannot be renewed from retained delivery; reconcile explicitly') end
 elseif entry then
  local retry=entry.body.status=='full' and entry.body.payload and entry.body.payload.retryable==true and entry.body.payload.effect_started==false and not entry.operation
  if r.op=='native_wake' then if not retry then return entry.body end
  elseif r.op:sub(1,8)~='mailbox_' or not retry and entry.body.status~='uncertain' then return entry.body end
 end
 local old=if entry and entry.authorization then entry.authorization else nil
 local fresh=if old then old.new else entry==nil
 local base=if old then old.base_body else if entry then P.clone(entry.body) else nil
 local nonce=allocate(root,'grant');if not nonce then return P.reject(r,'storage_error','Authorization counter exhausted') end
 entry=entry or {request=P.clone(r),request_json=request_json,relay_binding=relay_binding}
 entry.authorization={nonce=nonce,boot=boot,bridge=bridge,binding=P.clone(binding),session=session,deadline=tern.now()+30000,new=fresh,phase='requested',base_body=base}
 root.requests[key(r)]=entry
 return finish(root,entry,P.body(r,'pending',{authorization_required=true}),true)
end
function M.authorize(r,nonce,bridge,changed,claim,executor_id,proof,relay_binding,native_observation)
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 local entry=root.requests[key(r)];local a=if entry then entry.authorization else nil
 if not entry then return missing(root,r) end
 local mismatch=if not a then 'SPAWN authorization challenge is missing or already consumed'
  elseif not P.equal(entry.request,r) then 'SPAWN authorization request differs from staged immutable request'
  elseif entry.relay_binding~=relay_binding then 'SPAWN authorization belongs to another relay incarnation'
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
 local session_control=root.sessions[r.logical_session_id].control
 if not Codec.validate_dispatch_projection(proof,r,entry.request_json,session_control.last_authority_revision,claim) then return P.reject(r,'stale_revision','Fresh exact native action proof required') end
 local startup=if r.op=='mailbox_retire' and r.mode=='retire' then State.worker(root,r.logical_session_id,r.launch_request_id) else nil
 local witness_required=startup~=nil and startup.request.op=='launch' and pending_unaccepted_retirement(root,startup,r)
 if witness_required and not startup_witness(root,startup,r,native_observation) or native_observation~=nil and not witness_required then
  return P.reject(r,'binding_mismatch','Failed startup requires its exact original pane observation from this fresh authorized window')
 end
 session_control.last_authority_revision=proof.authority_revision
 local ack,ack_error=State.acknowledge(root,r);if not ack then return P.reject(r,'stale_revision',tostring(ack_error)) end
 entry.orch_claim=P.clone(claim);a.window_executor=executor_id
 a.phase='consumed'
 local saved,err=save(root,true);if not saved then return P.reject(r,'storage_error',err) end
 return M.request(r,a.binding,a.session,changed,nonce,snapshot,native_observation)
end

function M.request(r,binding,session,changed,authorization_nonce,authorized_snapshot,native_observation)
 -- Setup queries never load the transport registry or perform reload recovery.
 if r.op=='catalog' and r.setup_origin then
  local snapshot,why=Authority.setup_snapshot()
  if not snapshot then return P.reject(r,'storage_error',why) end
  return catalog(r,snapshot)
 end
 local available,preparation_error=preparation_admission(r,binding)
 if not available then return P.reject(r,'target_unavailable',preparation_error) end
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 if r.op=='owner_status' then return State.observation(root,r) end
 local admitted,owner_error=owner(root,r,binding,session,r.op~='catalog' and r.op~='status' and r.op~='mailbox_inventory' and r.op~='mailbox_allocation')
 if not admitted then return if owner_error=='already_consumed' then P.body(r,'already_consumed',nil,nil,'already_consumed') else P.reject(r,owner_error,'Current admitted authority and binding required') end
 local snapshot,snapshot_error=authorized_snapshot,nil
 if not snapshot then snapshot,snapshot_error=Authority.managed_snapshot(binding) end
 if not snapshot then return P.reject(r,'storage_error',snapshot_error) end
 if r.op=='mailbox_inventory' then return inventory(root,r) end
 if r.op=='mailbox_allocation' then return allocation_observation(root,r) end
 if r.op=='status' then
  local c=root.sessions[r.logical_session_id].control
  if r.target_request_serial<c.request_floor then return P.body(r,'already_consumed',nil,nil,'already_consumed') end
  local target=root.requests[r.logical_session_id..'/'..r.target_request_id]
  if target and (target.request.request_serial~=r.target_request_serial or not same_owner(target.request.origin_binding,r.origin_binding)) then return P.reject(r,'stale_binding','Target belongs to another immutable request') end
  if target then
   local body=P.body(r,'found',{outcome=staged_outcome(target)})
   -- Inspection has room for a valid ordinary outcome plus its envelope. Keep a
   -- bounded refusal for corrupt or genuinely nonencodable retained evidence so
   -- the carrier can ACK this read without changing or replaying the original.
   if not P.encode(body) then return P.reject(r,'oversize','Retained outcome exceeds the status inspection bound; its original result remains retained') end
   return body
  end
  return P.body(r,'missing',nil,nil,'unknown_effect')
 end
 local authorized=false
 local authorized_claim=nil
 local prior=root.requests[key(r)]
 local original_bytes=prior and prior.request_json
 local authorized_relay=prior and prior.relay_binding
 local relay_consent=prior and prior.relay_consent
 if prior then
  if not P.equal(prior.request,r) then return P.reject(r,'content_conflict','Request ID reused with changed content') end
  if prior.authorization then
   local a=prior.authorization
   if a.phase~='consumed' or a.boot~=boot or a.nonce~=authorization_nonce then return P.reject(r,'binding_mismatch','This staged request requires its fresh window grant') end
   if authorized_relay then
    relay_consent={nonce=a.nonce,boot=a.boot,bridge=a.bridge,deadline=a.deadline,executor_id=a.window_executor}
    prior.relay_consent=relay_consent
   end
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
   return mailbox(root,prior,snapshot,changed,native_observation)
  end
  if authorized and prior.body.status=='uncertain' and r.op:sub(1,8)=='mailbox_' then
   -- Mailbox.prepare converts an uncertain immutable operation to readback-only
   -- reconciliation. A missing final file is still uncertainty, not retry permission.
   return mailbox(root,prior,snapshot,changed,native_observation)
  end
  return prior.body
 end
 if not authorized then return P.reject(r,'stale_binding','Issued operations require exact fresh native authorization') end
 if r.op=='mailbox_read' then
  for k,old in pairs(root.requests) do if old.request.op=='mailbox_read' and old.request.handle==r.handle then
   if (old.body.status=='pending' and old.operation~=nil) or old.body.status=='uncertain' then
    local refused={request=P.clone(r),request_json=original_bytes,orch_claim=authorized_claim,relay_binding=authorized_relay,relay_consent=relay_consent};root.requests[key(r)]=refused
    return finish(root,refused,P.body(r,'full',{resource='mailbox_read',current=1,limit=1,retryable=true,effect_started=false}),true)
   end
  end end
 end
 local entry={request=P.clone(r),request_json=original_bytes,body=P.body(r,'resolved'),orch_claim=authorized_claim,relay_binding=authorized_relay,relay_consent=relay_consent};root.requests[key(r)]=entry
 if r.op=='catalog' then return finish(root,entry,catalog(r,snapshot),false)
 elseif r.op=='declare_provider_families' then
  local result,problem=Authority.managed_declare_provider_families(binding,r.record_revision,r.declarations)
  if not result then return finish(root,entry,P.reject(r,'content_conflict',tostring(problem)),true) end
  return finish(root,entry,P.body(r,'resolved',result),true)
 elseif r.op=='launch' then return launch_prepare(root,entry,binding,snapshot)
 elseif r.op=='adopt' or r.op=='enrol' then return adopt_prepare(root,entry,binding,snapshot)
 elseif r.op=='accept' then return accept(root,entry)
 elseif r.op=='stop' then return stop_prepare(root,entry)
 elseif r.op=='native_wake' then return prepare_wake(root,entry)
 elseif r.op=='attach_worker' then return attach_worker(root,entry,binding,session)
 else return mailbox(root,entry,snapshot,changed,native_observation) end
end
-- Carrier retirement invalidates only this VM's exact private control callback;
-- it neither consumes a domain action nor changes any durable native effect.
function M.revoke_control(challenge,bridge,relay_binding)
 if type(challenge)~='table' or challenge.schema~=2 or challenge.kind~='control_authorize'
  or challenge.boot~=boot or type(challenge.request)~='table' or not State.control_request(challenge.request)
  or not P.id(challenge.nonce) or not P.integer(bridge,1) or not P.digest(relay_binding) then return false end
 local a=control_challenges[challenge.request.request_id]
 -- Absence here is a positive private-table observation, not a failed registry
 -- read. A replacement nonce already makes the old exact callback impossible.
 if not a or a.nonce~=challenge.nonce then return true end
 if a.boot~=challenge.boot or a.bridge~=bridge or a.relay_binding~=relay_binding
  or a.request_json~=challenge.request_json or a.deadline~=challenge.deadline
  or not P.equal(a.request,challenge.request) then return false end
 control_challenges[challenge.request.request_id]=nil
 return true
end
function M.control_authorize(r,nonce,bridge,executor_id,peer,relay_binding)
 local root,why=load(true);if not root then return P.reject(r,'migration_blocked',why) end
 local a=control_challenges[r.request_id]
 if not a or not P.equal(a.request,r) or a.nonce~=nonce or a.boot~=boot or a.bridge~=bridge or a.relay_binding~=relay_binding or a.deadline<tern.now() or not P.id(executor_id) then return P.reject(r,'stale_revision','Current exact native control challenge required') end
 control_challenges[r.request_id]=nil
 if r.compatibility.kind=='migration' then
  if not P.fields(peer,{protocol=true,phase=true,authority_namespace=true,authority_revision=true,spawn_namespace=true,session=true,compatibility=true,managed_selection=true}) or peer.authority_namespace~=r.authority_namespace or peer.authority_revision~=r.authority_revision or peer.spawn_namespace~=root.namespace or not P.equal(peer.compatibility,r.compatibility) then return P.reject(r,'migration_blocked','Fresh exact native migration sources required') end
  local Migration=require('./dispatch_migration')
  local next_root,problem
  if root.migration then next_root,problem=Migration.finish(root,r.compatibility,peer.managed_selection,valid)
  else next_root,problem=Migration.prepare(root,r.compatibility,peer.managed_selection,valid) end
  if not next_root then return P.reject(r,'migration_blocked',if type(problem)=='table' then problem.message else problem) end
  local stored,err=save(next_root,true,nil,root.revision);if not stored then return P.reject(r,'storage_error',err) end
  return P.reject(r,'migration_blocked',if next_root.migration then 'Prepared source retained; observe both validated current candidates before cutover' else 'Pair qualified; issue a fresh compact current control at the captured current revision')
 end
 local body,err,changed=State.control(root,r,a.binding,a.session,peer)
 if not body then return P.reject(r,if err=='unknown_effect' then 'migration_blocked' else err,'Control refused; retain current obligations') end
 if changed==false then return body end
 if r.op=='reconcile_session' and r.control_origin.kind=='active' then
  -- The admitted new binding cannot consume an old window's unissued permit.
  -- Settle only never-consumed authorization; prior outcomes remain unchanged.
  for _,entry in pairs(root.requests) do
   local old=entry.authorization
   if entry.request.logical_session_id==r.logical_session_id and old and old.phase=='requested'
    and not P.equal(entry.request.origin_binding,r.control_origin.binding) then
    entry.authorization_fence={nonce=old.nonce,phase=old.phase,bridge=old.bridge,executor=old.window_executor}
    entry.authorization=nil
    entry.body=old.base_body or P.reject(entry.request,'authorization_revoked','Controller continuation revoked an unconsumed old-window authorization')
   end
  end
 end
 local stored,problem=save(root,true);return if stored then body else P.reject(r,'storage_error',problem)
end
local function qualification(root)
 local Migration=require('./dispatch_migration')
 local proof,why,projection=Migration.proof(root,valid)
 if not proof then return nil,if type(why)=='table' then why.message else why end
 qualification_snapshot={proof=proof,selection=Migration.selection(projection)}
 qualification_source_bytes=Codec.dispatch_source_bytes(root)
 return P.clone(qualification_snapshot)
end
local function observed_qualification(root)
 if not qualification_snapshot then return nil end
 if qualification_snapshot.proof.source_revision==root.revision and qualification_snapshot.proof.source_namespace==root.namespace then
  local ok,bytes=pcall(Codec.dispatch_source_bytes,root)
  if ok and bytes==qualification_source_bytes then return P.clone(qualification_snapshot) end
 end
 qualification_snapshot=nil;qualification_source_bytes=nil
 return nil
end
function M.qualification(request)
 local ok,root=pcall(tern.kv.get,KEY);if not ok or not root then return nil end
 if request and request.compatibility and request.compatibility.kind=='migration' then return qualification(root) end
 return observed_qualification(root)
end
local function setup_authority()
 local ok,snapshot,why=pcall(Authority.setup_snapshot)
 if not ok then return nil,'Configuration authority cannot be read; preserve it' end
 if not snapshot then return nil,why end
 if type(snapshot)~='table' or not P.text(snapshot.namespace,128,false) then return nil,'Configuration authority missing; restore or configure the actual owner before source inspection' end
 return snapshot
end
local function admin_source_existing()
 local ok,root=pcall(tern.kv.get,KEY)
 if not ok then return nil,'Managed source cannot be read; preserve its initialized identity','source_unavailable' end
 local marked,marker=pcall(tern.kv.get,KEY..'-initialized')
 if not marked then return nil,'Managed initialization marker cannot be read; preserve it','source_unavailable' end
 if root==nil then
  if hold then return nil,hold,'source_unavailable' end
  if marker~=nil then return nil,'Managed source missing after initialization; restore it, never reset','source_unavailable' end
  return nil,'Managed source absent; explicit native Create is required before managed setup','source_absent'
 end
 if marker~=nil and (type(root)~='table' or marker~=root.namespace) then return nil,'Managed source differs from its initialization marker; restore the matching store','source_unavailable' end
 local result,why=qualification(root)
 return result,why,if result then nil else 'source_unavailable'
end
-- Source observation never initializes either owner or performs reload recovery.
function M.admin_source_readonly()
 local snapshot,why=setup_authority();if not snapshot then return nil,why,'source_unavailable' end
 return admin_source_existing()
end
-- Explicit Config owner administration retains its native binding safeguard.
function M.admin_source(binding)
 local ok,snapshot,why=pcall(Authority.managed_snapshot,binding)
 if not ok then return nil,'Configuration authority cannot be read; preserve it','source_unavailable' end
 if not snapshot then return nil,why,'source_unavailable' end
 if type(snapshot)~='table' or not P.text(snapshot.namespace,128,false) then return nil,'Configuration authority missing; restore the actual owner before source inspection','source_unavailable' end
 return admin_source_existing()
end
-- Only the native Create witness may call this private first-use boundary.
-- The marker is permanent: a partial or ambiguous attempt is never replayed.
function M.admin_bootstrap(creation,on_transition)
 if not P.bootstrap_creation(creation) then return nil,'Exact native Create identity required','refused','bootstrap_refused' end
 if hold then return nil,hold,'refused','bootstrap_refused' end
 local snapshot,why=setup_authority()
 if not snapshot then return nil,why,'refused','bootstrap_refused' end
 local function absent()
  local ok,root=pcall(tern.kv.get,KEY)
  local marked,marker=pcall(tern.kv.get,KEY..'-initialized')
  if not ok or not marked then return false,'Managed source or initialization marker cannot be read; preserve both' end
  if root~=nil or marker~=nil then return false,'Managed source or initialization marker already exists; inspect or restore it, never reset' end
  if hold then return false,hold end
  return true
 end
 local empty,problem=absent()
 if not empty then return nil,problem,'refused','bootstrap_refused' end
 local root={version=2,revision=0,namespace=string.format('dispatch-%d-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647)),next_id=1,admission_cursor=0,sessions={},workers={},controls={},requests={},mailboxes=Mailbox.empty(),gates={}}
 local started=false
 local candidate_bytes
 local function configuration_current()
  local current,err=setup_authority()
  if not current then return false,err end
  if current.namespace~=snapshot.namespace then return false,'Configuration authority changed during Create; preserve both sources' end
  return true
 end
 local called,stored,err=pcall(save,root,false,function(final)
  local Migration=require('./dispatch_migration')
  local candidate,diagnostic=Migration.proof(final,valid)
  if not candidate then return false,if type(diagnostic)=='table' then diagnostic.message else diagnostic end
  candidate_bytes=Codec.dispatch_source_bytes(final)
  if on_transition then on_transition(P.clone(candidate)) end
  local current,changed=configuration_current();if not current then return false,changed end
  local vacant,occupied=absent();if not vacant then return false,occupied end
  started=true
  local stamped=pcall(tern.kv.set,KEY..'-initialized',final.namespace)
  if not stamped then return false,'Initialization marker write is uncertain; preserve it and never retry Create' end
  local unchanged,configuration_error=configuration_current();if not unchanged then return false,configuration_error end
  local marked,marker=pcall(tern.kv.get,KEY..'-initialized')
  local read,existing=pcall(tern.kv.get,KEY)
  if not marked or marker~=final.namespace or not read or existing~=nil then return false,'Initialization marker or absent source readback differs; preserve both and never retry Create' end
  return true
 end)
 local function uncertain(message)
  hold=message
  qualification_snapshot=nil;qualification_source_bytes=nil
  return nil,hold,'uncertain','bootstrap_uncertain'
 end
 if not called or not stored then
  local message=if called then err else 'Managed initialization failed; preserve both sources'
  if started then return uncertain(message) end
  return nil,message,'refused','bootstrap_refused'
 end
 local read,observed=pcall(tern.kv.get,KEY)
 local marked,marker=pcall(tern.kv.get,KEY..'-initialized')
 if not read or observed==nil or not marked or marker~=root.namespace then return uncertain('Managed initialization readback is unavailable; preserve both sources and never retry Create') end
 local encoded,bytes=pcall(Codec.dispatch_source_bytes,observed)
 if not encoded or bytes~=candidate_bytes then return uncertain('Managed initialization readback differs from the exact candidate; preserve both sources and never retry Create') end
 local qualified,result,qualification_error=pcall(qualification,observed)
 if not qualified or not result then return uncertain(if qualified then qualification_error else 'Managed initialization cannot be qualified; preserve both sources') end
 loaded=true
 return result,nil
end
function M.admin_apply(operation,expected,peer,on_transition)
 if operation~='inspect' and operation~='prepare' and operation~='finish' then return nil,'Unknown migration administration operation','refused' end
 local ok,root=pcall(tern.kv.get,KEY);if not ok or not root then return nil,'Managed source missing; restore its initialized identity, never reset','refused' end
 local Migration=require('./dispatch_migration')
 local own,why,normal=Migration.proof(root,valid)
 if not own then return nil,(if type(why)=='table' then why.message else why),'refused' end
 if not P.equal(own,expected) then return nil,'Managed source changed since this intent was created; inspect again explicitly','refused' end
 if not Codec.validate_dispatch_migration_qualification(peer,'orch') then return nil,'Complete fresh native peer qualification required','refused' end
 local compatibility={schema=1,kind='migration',orch=P.clone(peer.proof),spawn=own}
 if not Codec.validate_dispatch_compatibility(compatibility) then return nil,'Unsupported native source qualification','refused' end
 local own_selection=Migration.selection(normal)
 local own_digest=Codec.dispatch_managed_digest(tern.json.encode(normal))
 if not P.equal(own_selection,peer.selection) or not own_digest or own_digest~=peer.proof.managed_sha256 then return nil,'Complete independently derived identities differ from the native peer qualification','refused' end
 if operation=='inspect' then
  qualification_snapshot={proof=own,selection=own_selection}
  qualification_source_bytes=Codec.dispatch_source_bytes(root)
  return {proof=P.clone(own),selection=P.clone(own_selection),compatibility=compatibility}
 end
 local candidate,problem
 if operation=='prepare' then candidate,problem=Migration.prepare(root,compatibility,peer.selection,valid)
 else candidate,problem=Migration.finish(root,compatibility,peer.selection,valid) end
 if not candidate then return nil,(if type(problem)=='table' then problem.message else problem),'refused' end
 local stored,err,disposition=save(candidate,true,function(final)
  local after,why=Migration.proof(final,valid)
  if not after then return false,if type(why)=='table' then why.message else why end
  if on_transition then on_transition(P.clone(after)) end
  return true
 end,root.revision)
 if not stored then return nil,err,disposition or 'refused' end
 local result,why=qualification(candidate)
 return result,why,if result then nil else 'uncertain'
end
function M.current(logical_session_id)
 local ok,root=pcall(tern.kv.get,KEY)
 if not ok or not root or not valid(root) then return nil end
 local observed=observed_qualification(root)
 if root.version~=2 then return {protocol=1,phase='legacy',spawn_namespace=root.namespace,authority_revision=root.revision,qualification=observed} end
 local sessions={}
 local s=logical_session_id and root.sessions[logical_session_id]
 local progress
 if s then
  sessions[logical_session_id]={admission_seq=s.admission_seq,control=P.clone(s.control)}
  -- Fingerprint only this admission's current control and outstanding page facts.
  -- A global store revision would make otherwise idle sessions reconcile each other.
  local entries={}
  for _,entry in pairs(root.requests) do
   local q=entry.request
   if q.logical_session_id==logical_session_id and q.admission_seq==s.admission_seq then
    entries[#entries+1]=string.format('%.0f',q.request_serial)..':'..q.request_id..':'..q.action_id..':'..q.op..':'..entry.body.status
   end
  end
  table.sort(entries)
  local control=table.clone(s.control)
  control.last_authority_revision=nil -- Observing another page is not new delivery progress.
  progress=Codec.sha256(string.format('%.0f',s.admission_seq)..'\n'..Codec.dispatch_source_bytes(control)..'\n'..table.concat(entries,'\n'))
 end
 return {protocol=2,phase=if root.migration then 'prepared' else 'stable',spawn_namespace=root.namespace,authority_namespace=root.authority_namespace,authority_revision=root.revision,admission_cursor=root.admission_cursor,sessions=sessions,session_progress=progress,compatibility=State.compatibility(root),qualification=observed}
end
-- Explicit forget (SKILLS-205): dedicated opt-in operations, answered here and nowhere else. The preview is read-only: it
-- never uses load() (whose reload recovery rewrites claims and persists), never revokes a permit and never acknowledges a
-- request. A challenge is bound to both namespaces, the session/admission, the retained owner identity, this boot and one
-- attempt id; only the latest per identity is honoured and it lives in memory, so a SPAWN reload invalidates it.
local forget_challenges={}
local forget_done={} -- identity -> the exact completed attempt, so an exact retry of a lost completion answers closed again
local function forget_body(r,status,payload,err)
 return {schema=1,op=r.op,request_id=r.request_id,attempt_id=r.attempt_id,status=status,spawn_namespace=r.spawn_namespace,authority_namespace=r.authority_namespace,logical_session_id=r.logical_session_id,admission_seq=r.admission_seq,spawn_boot=boot,payload=payload,error=err}
end
local function forget_refuse(r,code,message) return forget_body(r,'refused',nil,{code=code,message=message}) end
local function forget_identity(r) return r.authority_namespace..'/'..r.logical_session_id..'/'..string.format('%.0f',r.admission_seq) end
-- Production pane observer. A retained pane is absent only when BOTH the host's pane list lacks its id AND the host's live agent
-- panes (the pane list entries running an agent program) show no agent for the retained identity (the record's command in the
-- retained working directory). A still-listed agent is a blocker (present, naming the pane the owner can see); anything that cannot
-- be read or identified is unknown ("cannot be checked"), never absence. The window-only `cx.agents:list()` has no host-side
-- twin: the host pane list, which supplies each pane's program and cwd, is the live agent list this peer can read.
local function forget_pane_observer()
 local ok,panes=pcall(tern.pane.list)
 if not ok or type(panes)~='table' then return function() return 'unknown' end end
 local present,rows={},{}
 for _,pane in ipairs(panes) do present[tostring(pane.pane)]=true;rows[#rows+1]=pane end
 local function basename(value) return type(value)=='string' and value:match('([^/\\]+)$') or nil end
 local commands
 local function command_of(record_id)
  if commands==nil then
   commands={}
   local read,snapshot=pcall(Authority.setup_snapshot)
   if not read or type(snapshot)~='table' or type(snapshot.records)~='table' then commands=false
   else for _,record in ipairs(snapshot.records) do if type(record)=='table' and type(record.id)=='string' then commands[record.id]=basename(record.command) end end end
  end
  return if commands then commands[record_id] else nil
 end
 return function(binding,info)
  if present[binding.pane_id] then return 'present' end
  info=info or {}
  local command=command_of(info.agent)
  -- Without the record's agent identity the live agent list cannot be matched to this binding.
  if command==nil or type(info.cwd)~='string' then return 'unknown' end
  for _,pane in ipairs(rows) do
   if basename(pane.program)==command and pane.cwd==info.cwd then return 'present',tostring(pane.pane) end
  end
  return 'absent'
 end
end
-- Retained terminal process identity: synchronous on Linux (/proc); other platforms answer 'unknown', which is a blocker.
local function forget_process_observer(proof)
 local result='unknown'
 local ok=pcall(TerminalIdentity.liveness,proof,function(value) result=value end)
 return if ok then result else 'unknown'
end
local function forget_owner_matches(s,owner)
 local function same(b)
  if type(b)~='table' then return false end
  for _,name in ipairs({'owner_id','owner_generation','host_pane_id','alias_nonce','window_key','native_session_id','window_host_id'}) do
   if b[name]~=owner[name] then return false end
  end
  return true
 end
 return same(s.control.binding) or s.closing_origin~=nil and same(s.closing_origin.binding)
end
function M.forget_unavailable(r,why) return forget_refuse(r,'unsupported',tostring(why or 'Execution-host authority is unavailable'):sub(1,400)) end
function M.forget(r,binding,session,observe,process_state,incarnation_override)
 if hold then return forget_refuse(r,'busy',hold) end
 local ok,stored=pcall(tern.kv.get,KEY)
 if not ok or type(stored)~='table' or stored.version~=2 or not valid(stored) then return forget_refuse(r,'unsupported','Managed dispatch store is unavailable or not current') end
 local root=P.clone(stored);P.observe(root)
 if root.migration or root.authority_namespace~=r.authority_namespace or root.namespace~=r.spawn_namespace then return forget_refuse(r,'changed','The paired namespaces changed') end
 local identity=forget_identity(r)
 local s=root.sessions[r.logical_session_id]
 if s then
  if s.admission_seq~=r.admission_seq then return forget_refuse(r,'changed','The admission changed') end
  if s.authority~=(binding.managed_authority_id or binding.authority_id) or s.host_session~=session or not forget_owner_matches(s,r.owner) then
   return forget_refuse(r,'owner_mismatch','This orchestration is owned by a different identity')
  end
 elseif r.admission_seq>root.admission_cursor then return forget_refuse(r,'not_found','No such admission was ever recorded')
 elseif root.sessions[r.logical_session_id]~=nil then return forget_refuse(r,'changed','Conflicting admission') end
 local current=forget_challenges[identity]
 if r.op=='discard_capability' then
  -- Repeating the same attempt is idempotent; a new attempt replaces (and so invalidates) the older challenge.
  if not current or current.attempt_id~=r.attempt_id then
   current={attempt_id=r.attempt_id,challenge=string.format('forget-%08x-%08x-%08x-%08x',math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647)),boot=boot}
   forget_challenges[identity]=current
  end
  return forget_body(r,'capable',{challenge=current.challenge,absent=if s==nil then true else nil})
 end
 local done=forget_done[identity]
 if r.op=='discard_session' and s==nil and done and done.attempt_id==r.attempt_id and done.challenge==r.challenge then
  return forget_body(r,'closed',{admission_cursor=root.admission_cursor})
 end
 if not current or current.attempt_id~=r.attempt_id or current.challenge~=r.challenge or current.boot~=boot then
  return forget_refuse(r,'stale_challenge','The challenge is not the latest for this attempt and boot')
 end
 observe=observe or forget_pane_observer()
 process_state=process_state or forget_process_observer
 local current_incarnation=incarnation_override or incarnation
 if not s then
  -- An authenticated retry after SPAWN already deleted the graph: the admission existed (cursor), nothing conflicts.
  if r.op=='discard_session' then return forget_body(r,'closed',{admission_cursor=root.admission_cursor}) end
  return forget_refuse(r,'not_found','The orchestration is already gone')
 end
 local host=r.owner.window_host_id
 if r.op=='discard_preview' then
  local inventory=State.forget_inventory(root,r.logical_session_id,observe,host,r.owner.native_session_id,process_state,current_incarnation)
  if #inventory.blockers>0 then return forget_body(r,'blocked',{dispatch_revision=inventory.dispatch_revision,blockers=inventory.blockers}) end
  current.preview_fingerprint=inventory.fingerprint
  return forget_body(r,'clean',{dispatch_revision=inventory.dispatch_revision,inventory=inventory.inventory})
 end
 -- discard_session: the preview's boot and revision must still hold, then everything is observed again immediately before commit.
 if r.spawn_boot~=boot or r.dispatch_revision~=root.revision then return forget_refuse(r,'changed','The orchestration changed after it was checked') end
 if current.preview_fingerprint==nil then return forget_refuse(r,'changed','The orchestration must be previewed before it is forgotten') end
 local inventory,blocked,why=State.forget_discard(root,r.logical_session_id,observe,host,r.owner.native_session_id,process_state,current.preview_fingerprint,current_incarnation)
 if why=='changed' then return forget_refuse(r,'changed','The observed execution changed after it was checked') end
 if not inventory then return forget_refuse(r,'blocked','Execution is not provably quiescent') end
 local saved,why=save(root,true)
 if not saved then return forget_refuse(r,'busy',tostring(why):sub(1,400)) end
 forget_challenges[identity]=nil
 forget_done[identity]={attempt_id=r.attempt_id,challenge=r.challenge}
 return forget_body(r,'closed',{admission_cursor=root.admission_cursor})
end
local function execution_in(root,r,bridge,relay_binding)
 if r.setup_origin then return nil end
 if State.control_request(r) then
  local a=control_challenges[r.request_id]
  return if a and a.bridge==bridge and a.relay_binding==relay_binding and a.boot==boot and a.deadline>=tern.now() then {schema=2,kind='control_authorize',request=a.request,request_json=a.request_json,nonce=a.nonce,boot=boot,deadline=a.deadline} else nil
 end
 local entry=root.requests[if r.op=='status' then r.origin_binding.logical_session_id..'/'..r.target_request_id else key(r)]
 local endpoint=entry and (entry.authorization or entry.relay_consent)
 if entry and (entry.relay_binding~=relay_binding or relay_binding~=nil and (not endpoint or endpoint.bridge~=bridge)) then return nil end
 local function project(value)
  value.schema=2;value.request_json=entry.request_json;value.boot=boot
  if entry.relay_binding and endpoint then value.nonce=endpoint.nonce;value.deadline=endpoint.deadline end
  value.last_authority_revision=root.sessions[r.logical_session_id].control.last_authority_revision
  return value
 end
 if entry and entry.authorization and entry.authorization.phase=='requested' and entry.authorization.boot==boot and entry.authorization.bridge==bridge and entry.authorization.deadline>=tern.now() and P.equal(entry.request.origin_binding,r.origin_binding) then
  local base=entry.authorization.base_body
  local target=if r.op=='mailbox_retire' and r.mode=='retire' then State.worker(root,r.logical_session_id,r.launch_request_id) else nil
  local startup=if target and target.request.op=='launch' and pending_unaccepted_retirement(root,target,r)
   then {pane_binding=P.clone(target.pane_binding),backend=target.launch.backend} else nil
  return project({kind='authorize',request=entry.request,nonce=entry.authorization.nonce,deadline=entry.authorization.deadline,
   startup_cleanup=startup,previous_claim=if base and base.status=='full' then entry.orch_claim else nil})
 end
 local admitted=State.owner(root,r.logical_session_id)
 if not admitted or admitted.recovery_revision or not P.equal(admitted.binding,r.origin_binding) then return nil end
 if entry and entry.request.op=='launch' and (if r.op=='status' then P.equal(entry.request.origin_binding,r.origin_binding) else P.equal(entry.request,r)) and (entry.body.status=='resolved' or entry.body.status=='claimed' or entry.body.status=='launching') then
  if entry.launch and entry.launch.backend=='ssh-command' then return nil end
  return project({kind='launch',request=entry.request,phase=entry.body.status,claim=entry.claim,launch=entry.launch,orch_claim=entry.orch_claim})
 end
 if entry and (entry.request.op=='adopt' or entry.request.op=='enrol') and entry.launch and (if r.op=='status' then P.equal(entry.request.origin_binding,r.origin_binding) else P.equal(entry.request,r)) and (entry.body.status=='resolved' or entry.body.status=='claimed' or entry.body.status=='launching') then
  return project({kind=entry.request.op,request=entry.request,phase=entry.body.status,claim=entry.claim,prompt=entry.launch.prompt,orch_claim=entry.orch_claim})
 end
 if entry and entry.request.op=='stop' and (if r.op=='status' then P.equal(entry.request.origin_binding,r.origin_binding) else P.equal(entry.request,r)) and stop_target(root,entry.request) and (entry.body.status=='resolved' or entry.body.status=='claimed' or entry.body.status=='launching') then
  return project({kind='stop',request=entry.request,phase=entry.body.status,claim=entry.claim,backend=entry.stop_backend,orch_claim=entry.orch_claim})
 end
 local target,launch=nil,nil
 if entry and entry.request.op=='native_wake' then target,launch=wake_target(root,entry.request) end
 local w=if target then target.wake else nil
 local owner_record=State.owner(root,r.logical_session_id)
 if w and launch and w.request_id==entry.request.request_id and owner_record and not owner_record.recovery_revision and P.equal(owner_record.binding,r.origin_binding) and P.equal(entry.request.origin_binding,r.origin_binding) and (w.phase=='resolved' or w.phase=='claimed' or w.phase=='launching') then
  return project({kind='wake',request=entry.request,phase=w.phase,claim=w.claim,pane_binding=w.pane_binding,orch_claim=entry.orch_claim})
 end
 return nil
end
function M.execution(r,bridge,relay_binding)
 if not P.integer(bridge,1) then return nil end
 if r and r.setup_origin then return nil end
 local root=load(r and State.control_request(r));if not root then return nil end
 return execution_in(root,r,bridge,relay_binding)
end
-- Releasing a carrier lane never removes authority, requests or worker obligations.
function M.relay_releasable(relay_binding)
 if hold or not P.digest(relay_binding) then return false end
 for _,challenge in pairs(control_challenges) do if challenge.relay_binding==relay_binding then return false end end
 local ok,root=pcall(tern.kv.get,KEY)
 if not ok then return false end
 if root==nil then
  local marked,marker=pcall(tern.kv.get,KEY..'-initialized')
  return marked and marker==nil
 end
 return valid(root)~=nil and State.relay_releasable(root,relay_binding)
end
-- Preserve a stale post-effect callback without treating it as current consent.
-- One exact result lives with its existing request, under the same store limit.
function M.retain_relay_result(act,bytes,delivery)
 local value,r=State.decode_relay_result(act,bytes)
 if not value or delivery~=nil and (delivery.body~=bytes or not State.valid_result_delivery(delivery,value.request_json,value.result,value.spawn_claim,value.orch_claim)) then return false,'invalid_result_evidence' end
 local readable,present=pcall(tern.kv.get,KEY)
 if not readable or present==nil then return false,'request_unavailable' end
 local root,why=load();if not root then return false,why end
 local entry=root.requests[key(r)]
 if not entry or entry.request_json~=value.request_json or not P.equal(entry.request,r) then return false,'request_mismatch' end
 if entry.relay_result then
  if entry.relay_result.act==act and entry.relay_result.bytes==bytes then return true end
  return false,'result_conflict'
 end
 local native=if entry.native_result then entry.native_result.claim else entry.claim
 if r.op=='native_wake' and not native then
  local target=wake_target(root,r)
  native=target and target.wake and target.wake.claim
 end
 if not native or not P.equal(value.spawn_claim,native) or value.executor_id~=native.executor_id
  or not P.equal(value.orch_claim,entry.orch_claim)
  or not Codec.validate_dispatch_projection(value.proof,r,entry.request_json,0,entry.orch_claim,native) then return false,'claim_mismatch' end
 if entry.native_result then
  if not P.equal(value.result,entry.native_result.result) then return false,'result_conflict' end
  if delivery~=nil then
   if entry.native_result.delivery then
    if P.equal(entry.native_result.delivery,delivery) then return true end
    return false,'delivery_conflict'
   end
   entry.native_result.delivery=P.clone(delivery)
   return save(root,true)
  end
  return true
 end
 entry.relay_result={act=act,bytes=bytes}
 if entry.body.status=='resolved' or entry.body.status=='claimed' or entry.body.status=='launching' then
  entry.body=P.body(r,'uncertain',nil,{code='target_unavailable',message='Exact native result retained for explicit reconciliation; it was not applied as current authorization'})
 end
 local saved,err=save(root,true)
 return saved,if saved then nil else err
end
-- Only the host carrier adapter calls these private settlement methods. A pending
-- exact inbound receipt fences ordinary consumption even when status overtakes ACK.
function M.result_deliveries()
 local ok,stored=pcall(tern.kv.get,KEY)
 if not ok then return nil,'Unable to read native delivery fences' end
 if stored==nil then
  local marker_ok,marker=pcall(tern.kv.get,KEY..'-initialized')
  if not marker_ok or marker~=nil then return nil,'Initialized native delivery registry is unavailable' end
  return {}
 end
 local root,why=valid(stored);if not root then return nil,why end
 local messages={}
 for _,entry in pairs(root.requests) do
  if entry.native_result and entry.native_result.delivery then
   if #messages>=24 then return nil,'Native delivery fence capacity exceeded' end
   table.insert(messages,P.clone(entry.native_result.delivery))
  end
 end
 return messages
end
function M.settle_result_deliveries(messages)
 if type(messages)~='table' or #messages>24 then return false,'Invalid native delivery settlement batch' end
 if #messages==0 then return true end
 local root,why=load();if not root then return false,why end
 local changed=false
 for _,message in ipairs(messages) do
  local value,r
  if type(message)=='table' then
   value,r=State.decode_relay_result('spawn.result',message.body)
   if not value then value,r=State.decode_relay_result('spawn.wakeresult',message.body) end
  end
  if not value or not State.valid_result_delivery(message,value.request_json,value.result,value.spawn_claim,value.orch_claim) then return false,'Invalid native delivery receipt' end
  local entry=root.requests[key(r)]
  if not entry or entry.request_json~=value.request_json then return false,'Native delivery request is unavailable' end
  if entry.native_result then
   if not P.equal(entry.native_result.claim,value.spawn_claim) or not P.equal(entry.native_result.result,value.result)
    or not P.equal(entry.orch_claim,value.orch_claim) then return false,'Native delivery outcome conflicts' end
   if entry.native_result.delivery then
    if not P.equal(entry.native_result.delivery,message) then return false,'Native delivery receipt conflicts' end
    entry.native_result.delivery=nil;changed=true
   end
  elseif not entry.relay_result or entry.relay_result.bytes~=message.body then return false,'Native delivery outcome was not retained' end
 end
 if not changed then return true end
 return save(root,true)
end
local function record_native_result(entry,result,native,delivery)
 if delivery~=nil and not State.valid_result_delivery(delivery,entry.request_json,result,native,entry.orch_claim) then return false end
 entry.native_result={claim=P.clone(native),result=P.clone(result),delivery=if delivery then P.clone(delivery) else nil}
 return true
end
local function native_proof(root,entry,proof,claim,executor_id,begin)
 local r=entry.request;local s=root.sessions[r.logical_session_id]
 if not s or s.control.phase~='open' or s.control.recovery or root.migration or root.authority_namespace~=r.authority_namespace or s.admission_seq~=r.admission_seq then return false end
 if begin and (not claim or claim.executor_id~=executor_id or claim.boot~=boot or claim.spawn_namespace~=root.namespace) then return false end
 if not Codec.validate_dispatch_projection(proof,r,entry.request_json,s.control.last_authority_revision,entry.orch_claim,if begin then claim else nil) then return false end
 s.control.last_authority_revision=proof.authority_revision
 return true
end
local function relay_start_current(entry,executor_id)
 if entry.relay_binding==nil then return true end
 local a=entry.relay_consent
 return a~=nil and a.boot==boot and a.executor_id==executor_id and a.deadline>=tern.now()
end
function M.claim(r,executor_id,operation,result,proof,observed_claim,relay_binding,delivery)
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 local entry=root.requests[key(r)]
 if not entry then return missing(root,r) end
 if entry.relay_binding~=relay_binding then return P.reject(r,'binding_mismatch','Native claim belongs to another transport incarnation') end
 if (operation=='claim' or operation=='begin') and not relay_start_current(entry,executor_id) then return P.reject(r,'stale_binding','Relay native consent expired; reconcile without renewing or replaying it') end
 if not P.equal(entry.request,r) or not P.id(executor_id) then return P.reject(r,'binding_mismatch','Execution request differs') end
 local current_owner=State.owner(root,r.logical_session_id)
 if not current_owner or current_owner.recovery_revision or not P.equal(current_owner.binding,r.origin_binding) then return P.reject(r,'binding_mismatch','Controller was fenced or retired; do not execute') end
 if operation~='claim' and (not entry.claim or entry.claim.executor_id~=executor_id or entry.claim.boot~=boot) then return P.reject(r,'stale_binding','Execution claim belongs to another executor or boot') end
 if not native_proof(root,entry,proof,entry.claim,executor_id,operation~='claim') or operation~='claim' and not P.equal(observed_claim,entry.claim) then
  if entry.claim and proof and proof.claim and proof.claim.spawn_claim and (proof.claim.spawn_claim.claim_nonce~=entry.claim.claim_nonce or proof.claim.spawn_claim.spawn_namespace~=entry.claim.spawn_namespace) then return finish(root,entry,P.reject(r,'claim_mismatch','Current peer committed a different native claim'),true) end
  return P.reject(r,'stale_revision','Fresh exact peer witness and original native executor are required')
 end
 -- Legacy effects remain inspectable, but no old SSH launch may start or replay.
 if (operation=='claim' or operation=='begin') and entry.launch and entry.launch.backend=='ssh-command' then return P.reject(r,'unsupported_capability','Retained SSH launch cannot start here; run ORCH+ on target host and settle existing effects with the original build before cutover') end
 if operation=='claim' or operation=='begin' then
  local available,preparation_error=preparation_admission(r,entry.binding)
  if not available then return P.reject(r,'target_unavailable',preparation_error) end
 end
 if operation=='claim' then
  if entry.body.status~='resolved' or entry.claim then return entry.body end
  entry.claim=native_claim(root,executor_id);return finish(root,entry,P.body(r,'claimed',launch_payload(entry)),false)
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
 if not State.valid_native_result(r,result) then return P.reject(r,'invalid_schema','Invalid launch result') end
 if not record_native_result(entry,result,entry.claim,delivery) then return P.reject(r,'invalid_schema','Invalid native delivery receipt') end
 if r.op=='adopt' or r.op=='enrol' then
  -- Refusal precedes delivery; a copied message is not a submitted task or ACCEPTED report.
  if result.status=='refused' then return finish(root,entry,P.reject(r,'target_unavailable',result.message or 'Enrollment refused before delivery; nothing was sent'),true) end
  local expected=if r.op=='enrol' and r.delivery=='clipboard' then 'copied' else 'submitted'
  if result.status==expected and P.equal(result.pane_binding,r.pane_binding) then
   entry.pane_binding=P.clone(r.pane_binding);entry.launch_incarnation=incarnation
   return finish(root,entry,P.body(r,'awaiting_acceptance',launch_payload(entry)),true)
  end
  return finish(root,entry,P.body(r,'uncertain',launch_payload(entry),{code='target_unavailable',message=result.message or 'Native ask may have been delivered; never repeat it'}),true)
 end
 if result.status=='submitted' and result.pane_binding and result.pane_binding.window_epoch==r.origin_binding.window_epoch and result.pane_binding.window_key==r.origin_binding.window_key and result.pane_binding.native_session_id==r.origin_binding.native_session_id and result.pane_binding.window_host_id==r.origin_binding.window_host_id then
  entry.pane_binding=P.clone(result.pane_binding);entry.launch_incarnation=incarnation
  local observed,observe_error=Authority.managed_observe(entry.binding,entry.attempt_id,entry.observer_id,{phase='Starting',pane=tonumber(result.pane_binding.pane_id)})
  if not observed then return finish(root,entry,P.body(r,'uncertain',launch_payload(entry),{code='storage_error',message=tostring(observe_error):sub(1,512)}),true) end
  return finish(root,entry,P.body(r,'awaiting_acceptance',launch_payload(entry)),true)
 end
 return finish(root,entry,P.body(r,'uncertain',launch_payload(entry),{code='target_unavailable',message=result.message or 'Native effect outcome uncertain; do not retry'}),true)
end
function M.stop_claim(r,executor_id,operation,result,proof,observed_claim,relay_binding,delivery)
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 local entry=root.requests[key(r)];local owner_record=State.owner(root,r.logical_session_id)
 if not entry then return missing(root,r) end
 if entry.relay_binding~=relay_binding then return P.reject(r,'binding_mismatch','Native stop belongs to another transport incarnation') end
 if (operation=='claim' or operation=='begin') and not relay_start_current(entry,executor_id) then return P.reject(r,'stale_binding','Relay stop consent expired; preserve the existing conversation') end
 local target=stop_target(root,r)
 if r.op~='stop' or not P.equal(entry.request,r) or not P.id(executor_id) or not target or target.stop_request_id~=r.request_id or not owner_record or owner_record.recovery_revision or not P.equal(owner_record.binding,r.origin_binding) then return P.reject(r,'stale_binding','Stop claim does not match the exclusive accepted launch') end
 if operation~='claim' and (not entry.claim or entry.claim.executor_id~=executor_id or entry.claim.boot~=boot) then return P.reject(r,'stale_binding','Stop claim belongs to another executor or boot') end
 if not native_proof(root,entry,proof,entry.claim,executor_id,operation~='claim') or operation~='claim' and not P.equal(observed_claim,entry.claim) then
  if entry.claim and proof and proof.claim and proof.claim.spawn_claim and not P.equal(proof.claim.spawn_claim,{spawn_namespace=entry.claim.spawn_namespace,claim_nonce=entry.claim.claim_nonce}) then return finish(root,entry,P.reject(r,'claim_mismatch','Peer stop witness changed'),true) end
  return P.reject(r,'stale_revision','Fresh exact stop witness required')
 end
 if operation=='claim' then
  if entry.body.status~='resolved' or entry.claim then return entry.body end
  entry.claim=native_claim(root,executor_id)
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
  target.stopped=result.observation
  if not record_native_result(entry,result,entry.claim,delivery) then return P.reject(r,'invalid_schema','Invalid native delivery receipt') end
  return finish(root,entry,P.body(r,'stopped',{pane_binding=P.clone(r.pane_binding),observation=result.observation}),true)
 end
 if not P.fields(result,{status=function(v)return v=='uncertain'end,message=function(v)return P.text(v,512,false)end}) then return P.reject(r,'invalid_schema','Invalid exact native stop outcome') end
 if not record_native_result(entry,result,entry.claim,delivery) then return P.reject(r,'invalid_schema','Invalid native delivery receipt') end
 return finish(root,entry,P.body(r,'uncertain',nil,{code='target_unavailable',message=result.message}),true)
end
function M.wake_claim(r,executor_id,operation,result,claim,proof,observed_claim,relay_binding,delivery)
 local root,why=load();if not root then return P.reject(r,'storage_error',why) end
 local entry=root.requests[key(r)];local owner_record=State.owner(root,r.logical_session_id)
 if not entry then return missing(root,r) end
 if entry.relay_binding~=relay_binding then return P.reject(r,'binding_mismatch','Native wake belongs to another transport incarnation') end
 if (operation=='wakeclaim' or operation=='wakebegin') and not relay_start_current(entry,executor_id) then return P.reject(r,'stale_binding','Relay wake consent expired; do not renew it from retained delivery') end
 local target,launch=wake_target(root,r)
 if not P.equal(entry.request,r) or not target or target.wake.request_id~=r.request_id or not P.id(executor_id) or not owner_record or owner_record.recovery_revision or not P.equal(owner_record.binding,r.origin_binding) then return P.reject(r,'stale_binding','Wake action is not owned by this controller') end
 local w=target.wake
 local begun=operation=='wakebegin' or operation=='wakeresult' or operation=='wakedefer' and w.claim~=nil
 if begun and (not w.claim or w.claim.executor_id~=executor_id or w.claim.boot~=boot) then return P.reject(r,'stale_binding','Wake claim belongs to another executor or boot') end
 if not orch_claim(claim) or not native_proof(root,entry,proof,w.claim,executor_id,begun) or begun and not P.equal(observed_claim,w.claim) then
  if w.claim and proof and proof.claim and proof.claim.spawn_claim and not P.equal(proof.claim.spawn_claim,{spawn_namespace=w.claim.spawn_namespace,claim_nonce=w.claim.claim_nonce}) then return finish(root,entry,P.reject(r,'claim_mismatch','Peer wake witness changed'),true) end
  return P.reject(r,'stale_revision','Fresh exact native wake witness required')
 end
 if not P.equal(w.pane_binding,select(3,route(launch))) then return P.reject(r,'binding_mismatch','Wake publication no longer matches its explicitly attached worker') end
 if operation=='wakedefer' then
  if w.phase~='resolved' and w.phase~='claimed' and w.phase~='launching' then return entry.body end
  if w.claim and (w.claim.executor_id~=executor_id or w.claim.boot~=boot) then return P.reject(r,'binding_mismatch','Only the exact never-started executor can defer wake') end
  w.phase='resolved';w.claim=nil;w.request_id=nil
  target.body=publication_wake(root,target,target.body)
  return finish(root,entry,P.body(r,'full',{resource='native_wake_idle',current=1,limit=1,retryable=true,effect_started=false}),true)
 elseif operation=='wakeclaim' then
  if w.phase~='resolved' or w.claim then return entry.body end
  w.claim=native_claim(root,executor_id);w.phase='claimed'
 elseif not w.claim or w.claim.executor_id~=executor_id or w.claim.boot~=boot then return P.reject(r,'binding_mismatch','Wake execution claim differs')
 elseif operation=='wakebegin' then
  if w.phase~='claimed' then return entry.body end
  w.phase='launching'
 elseif operation=='wakeresult' then
  if w.phase~='launching' then return entry.body end
  if not State.valid_native_result(r,result) then return P.reject(r,'invalid_schema','Invalid wake outcome') end
  if not record_native_result(entry,result,w.claim,delivery) then return P.reject(r,'invalid_schema','Invalid native delivery receipt') end
  w.phase=result.status
  if result.status=='submitted' then State.complete_wake(root,r.logical_session_id,r.target_request_id) end
 else return P.reject(r,'invalid_schema','Unknown wake operation') end
 target.body=publication_wake(root,target,target.body)
 return finish(root,entry,P.body(r,w.phase,{wake_status=w.phase,wake_effect_started=true}),true)
end
function M.open_import(binding,bytes)
 local r,records=State.import_decode(bytes,true);if not r then return nil,records end
 if r.target_host~=binding.host_key then return nil,'Snapshot target host differs from this Config host' end
 local root,why=load(true);if not root then return nil,why end
 local id=allocate(root,'import');if not id then return nil,'Gate counter exhausted' end
 local complete=P.clone(r);complete.migration_gate_id=id
 if #tern.json.encode(complete)>P.LIMIT then return nil,'Import request exceeds the bridge bound after adding its gate; shorten the exact snapshot before opening a gate' end
 root.gates[id]={request=r,records=records,binding=P.clone(binding),boot=boot}
 local ok,err=save(root,false);return if ok then id else nil,err
end
function M.cancel_import(id)
 local root,why=load(true);if not root then return false,why end
 local g=root.gates[id];if not g or g.consumed then return false,'Gate missing or already consumed' end
 root.gates[id]=nil;return save(root,true)
end
function M.import_config(r)
 local root,why=load(true);if not root then return {schema=1,op=r.op,request_id=r.request_id,status='rejected',error={code='storage_error',message=why}} end
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
 for logical,s in pairs(root.sessions) do
  local owner_record=State.owner(root,logical)
  if owner_record and owner_record.authority==authority_identity(binding) then
   local outcomes={}
   for _,entry in pairs(root.requests) do
    if entry.request.origin_binding.logical_session_id==logical then
     table.insert(outcomes,{request_id=entry.request.request_id,op=entry.request.op,phase=entry.body.status,pane=entry.pane_binding,claim=entry.claim,wake=entry.wake,retained_result=if entry.relay_result then {state='retained_unapplied',bytes=#entry.relay_result.bytes} else nil,authorization=if entry.authorization then {phase=entry.authorization.phase,bridge=entry.authorization.bridge,executor=entry.authorization.window_executor} else entry.authorization_fence})
    end
   end
   table.insert(rows,{logical_session_id=logical,binding=owner_record.binding,revision=root.revision,fenced=owner_record.recovery_revision~=nil,outcomes=outcomes})
  end
 end
 return rows
end
function M.recover_owner(binding,logical,revision,confirm)
 local root,why=load();if not root then return false,why end
 local current=State.owner(root,logical);local session=root.sessions[logical]
 if not current or current.authority~=authority_identity(binding) or revision~=root.revision then return false,'Owner/revision changed; inspect the current recovery view' end
 if not confirm then
  session.control.recovery={recovery_id=allocate(root,'recovery'),phase='fenced',generation_floor=session.control.generation_floor}
  for _,entry in pairs(root.requests) do
   if entry.request.origin_binding.logical_session_id==logical then
    fence_unstarted_wake(root,entry)
    if (entry.request.op=='launch' or entry.request.op=='adopt' or entry.request.op=='enrol' or entry.request.op=='stop' or entry.request.op=='native_wake') and (entry.body.status=='resolved' or entry.body.status=='claimed' or entry.body.status=='launching') then
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
  if not session.control.recovery then return false,'Fence the previous owner before confirming recovery' end
  session.control.generation_floor=math.max(session.control.generation_floor,current.binding.owner_generation)
  session.control.recovery.phase='confirmed';session.control.recovery.generation_floor=session.control.generation_floor
  for _,g in pairs(root.mailboxes.generations) do
   if g.binding.logical_session_id==logical and g.active then
    local write=g.writes[g.active.key]
    if write then write.status='uncertain';write.result={status='uncertain'} end
    g.active=nil
   end
  end
  session.control.binding=nil
 end
 return save(root,true)
end
M.protocol=P
return M
