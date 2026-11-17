-- Pure window fixtures: genuine ORCH relay boundaries are injected, not runtime evidence.
local root,section=...
assert(type(root)=='string','pass package directory')
assert(section==nil or section=='wake' or section=='retirement' or section=='window' or section=='failed_startup','unknown window dispatch section')
local runtime,environment=tern,getfenv()
local checks=0
local function check(v,m)assert(v,m);checks+=1 end
local function copy(v)if type(v)~='table'then return v end local n={}for k,x in pairs(v)do n[k]=copy(x)end return n end
local function issued(f)
 for _,r in ipairs({f.request,f.current,f.projection.request}) do
  r.schema=2;r.authority_namespace='orch-native';r.logical_session_id='session';r.admission_seq=1;r.request_serial=1;r.next_request_serial=2;r.settled_before=1;r.consumed=runtime.json.array()
 end
 f.projection.schema=2;f.projection.request_json=runtime.json.encode(f.projection.request)
 f.projection.last_authority_revision=10;f.projection.boot='fixture-boot'
 f.projection.nonce=f.projection.nonce or 'original-authorization';f.projection.deadline=30000
 f.state.version=2;f.state.protocol=2;f.state.phase='stable';f.state.authority_namespace='orch-native';f.state.authority_revision=10;f.state.spawn_namespace='spawn-native'
 local a=f.state.action
 a.authority_namespace='orch-native';a.authority_revision=10;a.logical_session_id='session';a.admission_seq=1;a.request_serial=1;a.request_sha256=f.c.sha256(f.projection.request_json)
 return f
end
local function control_projection(f,op,consumed)
 local r={schema=2,origin='orchplus',op=op or 'reconcile_session',request_id='control-one',action_id='control-action',authority_namespace='orch-native',authority_revision=10,logical_session_id='session',admission_seq=1,control_origin={kind='active',binding=copy(f.request.origin_binding),controller_pane='44'},compatibility={schema=1,kind='current',protocol=2,authority_namespace='orch-native',spawn_namespace='spawn-native'},generation_floor=0,next_request_serial=2,settled_before=1,consumed=runtime.json.array()}
 for _,serial in ipairs(consumed or {}) do table.insert(r.consumed,serial) end
 if r.op=='reconcile_session' then r.page_limit=32 end
 if r.op=='close_session' then r.close_id='closing-one' end
 local control={phase=if r.op=='close_session' then 'closing' else 'open',generation_floor=0,request_floor=1,next_request_serial=2,last_authority_revision=10,binding=copy(r.control_origin.binding)}
 if r.close_id then control.close_id=r.close_id end
 local bytes=runtime.json.encode(r)
 f.state.sessions={session={admission_seq=1,control=control}};f.state.control={request=r,request_bytes=bytes}
 return {schema=2,kind='control_authorize',request=r,request_json=bytes,nonce='control-nonce'}
end
local function fixture()
 local modules={};local scheduled;local events={};local request_reads=0
 local injected=setmetatable({timer=function(_,fn)scheduled=fn;return 1 end},{__index=runtime})
 local function load(name)
  name=name:gsub('^%./','');if modules[name]then return modules[name]end
  local fn=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
  setfenv(fn,setmetatable({tern=injected,require=load},{__index=environment}));modules[name]=fn();return modules[name]
 end
 local p,c,w=load('bridge_protocol'),load('wire/codec'),load('dispatch_window')
 local origin={logical_session_id='session',owner_id='owner',owner_generation=1,host_pane_id='12',alias_nonce='alias',window_key='',window_epoch='epoch',native_session_id='3',window_host_id='7'}
 local r={schema=1,origin='orchplus',op='mailbox_publish_reply',request_id='publication',action_id='action-publication',controller_pane='44',controller_generation=1,origin_binding=copy(origin),logical_session_id='session',worker_id='worker',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,message_id='message',reply_seq=1,action_revision=1,reply_sha256=c.sha256('reply'),part='manifest',object_b64='e30=',object_sha256=c.sha256('{}')}
 local claim={executor='epoch',epoch=1,grant_id='grant-one'}
 local state={version=1,source_nonce='alias',host_pane_id='12',orch_session_id='session',owner_id='owner',owner_generation=1,command_cursor={origin=copy(origin),controller_pane='44',seq=1},action={action_id=r.action_id,phase='claimed',claim=copy(claim),execution_origin=copy(origin),execution_controller_pane='44',reconciliation_only=false}}
 local f={p=p,c=c,w=w,request=r,current=copy(r),state=state,claim=claim,events=events,relay_events={},clock=0,asks=0,starts=0,action_reads=0,idle_reads=0,agent_state='idle',focus=44,projection={schema=1,kind='authorize',request=copy(r),nonce='challenge'}}
 local host={id=7,state='connected',panes={44,55,66}}
 local session={id=3,host=7}
 local function surface(block,key,role,bytes)return {surface={role='plugin.'..block},main={id='main.'..key,k='text',p={role=role,spans={{t=bytes}}}}}end
 local function close_target(native)
  if native then f.stops=(f.stops or 0)+1 else f.closes=(f.closes or 0)+1 end
  if f.stop_error then error('ambiguous native stop') end
  if f.stop_drift then state.action.claim.grant_id='stale-after-stop';return end
  if f.stop_result=='absent' then f.absent=true;host.panes={44,66}
  elseif f.stop_result=='exited' then f.agent_state='exited';f.exit_status=0 end
 end
 local cx={hosts={current=function()return host end},sessions={
  current=function()return if f.selected_session then {id=f.selected_session,host=7} else session end,
  list=function()return {{id=3,host=f.session_host or 7},{id=4,host=7}}end,
 },window_key=function()return ''end,agents={
  get=function()if f.unrecognized then error('not a native agent')end return {pane=55}end,
  list=function()
   f.idle_reads+=1
   return if f.unknown then {} else {{pane=55,state=if f.idle_reads==f.busy_on_list then 'working' else f.agent_state,delivery_error=f.delivery_error}}
  end,
  ask=function(_,pane,prompt)
   f.asks+=1;f.asked_pane=pane;f.asked_prompt=prompt
   if f.continue_during_ask then
    state.command_cursor.origin.window_epoch='continued-epoch';state.command_cursor.seq+=1
    state.action.execution_origin=copy(state.command_cursor.origin);state.action.reconciliation_only=true
   end
   if f.ask_error then error('possible delivery')end
  end,
  start=function(_,options)
   f.starts+=1;f.start_options=copy(options)
   if f.relay_change_during_start then f.relay_override={source_nonce='reloaded-source'} end
   if f.start_error then error('ambiguous native start')end
   local created=if f.start_panes then table.remove(f.start_panes,1) else 55
   -- Native start focuses the new agent pane unless a test models late (macOS) focus.
   if not f.start_keeps_focus then f.focus=created end
   return created
  end,
  stop=function()close_target(true)end,
 }}
 cx.hosts.list=function()return {host}end
 cx.copy=function(_,text)
  f.copies=(f.copies or 0)+1;f.copied_text=text
  if f.copy_error then error('possible clipboard delivery') end
 end
 cx.layout={close=function()close_target(false)end,focus=function(_,id)
  f.focus_calls=(f.focus_calls or 0)+1
  if f.focus_error then error('focus refused') end
  f.focus=id;f.refocused=(f.refocused or 0)+1
 end}
 cx.layout.new_tab=function(_,options,presentation)
  f.terminals=(f.terminals or 0)+1;f.terminal_options=copy(options);f.terminal_presentation=copy(presentation)
  if presentation.focus then f.focus=55 end
  return 55
 end
 cx.session={
  focused=function()return f.focus end,
  pane=function(_,id)if id==55 and f.absent then return nil end return {block=if id==44 or id==47 then (if f.foreign_program then 'other.plugin' else 'orchplus.orchestrator') elseif id==45 then 'spawn.dispatch' else 'agent',tab=if f.setup_parked and id==44 then nil elseif id==55 and f.target_foreign_session then 2 else 1,kind=if id==55 then f.pane_kind or 'agent' else 'plugin',exited=if id==55 then f.exit_status else nil}end,
  tabs=function()return {{id=1,session=if f.foreign_session then 99 else 3},{id=2,session=4}}end,
  panes=function()
   if f.old_transport_only then return {{pane=45,block='spawn.dispatch'}} end
   local out={{pane=44,block='orchplus.orchestrator'}}
   if f.setup_duplicate then table.insert(out,{pane=47,block='orchplus.orchestrator'}) end
   if f.leading_panel then table.insert(out,1,{pane=47,block='orchplus.orchestrator'}) end
   return out
  end,
  surface=function(_,id,opts)
   if opts.root=='main.orchplus-spawn-relay' then
    if f.missing_relay then return nil end
    f.metadata_reads=(f.metadata_reads or 0)+1
    local function lane(id)
     local row={lane_id=id,peer_boot='spawn-boot',bind_id='bind-'..id,release_held=false,messages={execution={id='frame-'..id,incarnation='spawn-boot',route='spawn.execution',binding='orch-endpoint:'..id}}}
     for _,kind in ipairs({'response','current'}) do row.messages[kind]={id=kind..'-'..tostring(f.progress or 0),incarnation='spawn-boot',route='spawn.'..kind,binding='orch-endpoint:'..id} end
     for key,value in pairs(f.proof_override or {}) do row.messages.execution[key]=value end
     if f.pending_lane then row.peer_boot=nil;row.messages={} end
     if f.held_lane then row.held=true;row.error='source_changed' end
     for key,value in pairs(f.lane_override or {}) do row[key]=value end
     if f.metadata_reads==f.receipt_drift_read then row.messages.execution.id='replacement-frame' end
     if f.metadata_reads==f.lane_drift_read then row.bind_id='replacement-bind' end
     return row
    end
    local metadata={schema=1,peer='spawn',host_pane_id='12',source_nonce=if f.setup_query then 'setup-alias' else 'alias',relay_endpoint='orch-endpoint',relay_boot='orch-boot',lanes={lane('lane-one')},releases={{lane_id='released-lane',peer_boot='spawn-boot'}},held=false}
    if f.second then table.insert(metadata.lanes,lane('lane-two')) end
    if f.duplicate_lane then table.insert(metadata.lanes,lane('lane-one')) end
    if f.leading_panel and id==47 then
     metadata.lanes={};metadata.releases={}
     for index=1,32 do table.insert(metadata.lanes,{lane_id='pending-'..index,messages={}}) end
    end
    if f.metadata_reads==f.relay_drift_read then metadata.relay_boot='replacement-boot' end
    for key,value in pairs(f.relay_override or {}) do metadata[key]=value end
    local tree=surface('orchplus.orchestrator','orchplus-spawn-relay','orchplus.spawn-relay',runtime.json.encode(metadata))
    if f.foreign_relay_surface then tree.surface.role='plugin.spawn.dispatch' end
    if f.truncated_relay then tree.more=1 end
    return tree
   end
   if opts.root=='main.spawn-relay-lane-one-execution' or opts.root=='main.spawn-relay-lane-two-execution' then
    if f.missing_execution then return nil end
    local projection=if opts.root=='main.spawn-relay-lane-two-execution' and f.second then f.second.projection else f.projection
    f.execution_reads=(f.execution_reads or 0)+1
    if f.execution_reads==f.execution_drift_read then projection=copy(projection);projection.nonce='replacement-authorization' end
    local tree=surface('orchplus.orchestrator',opts.root:sub(6),'orchplus.spawn-execution','SPAWN_EXECUTION v2 '..runtime.json.encode(projection))
    if f.foreign_execution_role then tree.main.p.role='spawn.dispatch.execution' end
    return tree
   end
   -- Independent execution lanes share the real controller, not transport panes.
   local second=f.second
   if second then
    local key=second.request.action_id
    if opts.root=='main.dispatch-action-'..key then return surface('orchplus.orchestrator','dispatch-action-'..key,'orchplus.dispatch',runtime.json.encode(second.state))end
    if opts.root=='main.dispatch-request-'..key then return surface('orchplus.orchestrator','dispatch-request-'..key,'orchplus.request',runtime.json.encode(second.request))end
   end
   if f.bootstrap_nodes and f.bootstrap_roles[opts.root] then
    local key=opts.root
    f.bootstrap_reads[key]=(f.bootstrap_reads[key] or 0)+1
    local value=f.bootstrap_nodes[key]
    if not value then return nil end
    local bytes=f.bootstrap_bytes[key] or runtime.json.encode(f.p.clone(value))
    if f.bootstrap_reads[key]==2 and f.bootstrap_drift==key then bytes..=' ' end
    if f.bootstrap_reads[key]==2 and f.bootstrap_origin_drift then f.current.request_id='replaced' end
    local out=surface('orchplus.orchestrator',key:sub(6),f.bootstrap_roles[key],bytes)
    if f.bootstrap_wrong_role==key then out.main.p.role='spawn.fabricated' end
    if f.bootstrap_truncated==key then out.more=1 end
    return out
   end
   if opts.root=='main.migration-state' then
    f.migration_reads=(f.migration_reads or 0)+1
    if not f.migration_peer then return nil end
    local peer=f.p.clone(f.migration_peer)
    if f.migration_reads==f.migration_drift_read then peer.source_nonce='replacement-source' end
    if f.migration_origin_drift then f.current.request_id='replacement-request' end
    local out=surface('orchplus.orchestrator','migration-state','orchplus.migration',runtime.json.encode(peer))
    if f.migration_truncated then out.more=1 end
    return out
   end
   if f.setup_query and opts.root=='main.setup-index' then
    if f.missing_setup_index then return nil end
    return surface('orchplus.orchestrator','setup-index','orchplus.setup',runtime.json.encode(f.setup_index))
   end
   if f.setup_query and opts.root=='main.setup-catalog-request' then
    if f.missing_setup_request then return nil end
    local out=surface('orchplus.orchestrator','setup-catalog-request','orchplus.setup.request',runtime.json.encode(f.current))
    if f.setup_truncated then out.more=1 end
    return out
   end
   if opts.root=='main.dispatch-state'then return surface('orchplus.orchestrator','dispatch-state','orchplus.dispatch',runtime.json.encode(f.primary_state or state))end
   local action_key='dispatch-action-'..f.request.action_id
   if opts.root=='main.'..action_key then
    f.action_reads+=1
    if f.missing_action or f.action_reads==f.missing_action_read then return nil end
    local observed=state
    if f.action_reads==f.stale_action_read then observed=copy(state);observed.action.claim.grant_id='transient-stale-grant'end
    return surface('orchplus.orchestrator',action_key,'orchplus.dispatch',runtime.json.encode(observed))
   end
   local request_key='dispatch-request-'..f.request.action_id
   local current=f.current
   if opts.root=='main.dispatch-request'then request_key='dispatch-request';current=f.primary_request or current
   elseif opts.root~='main.'..request_key or f.missing_request then return nil end
   request_reads+=1
   local out=surface('orchplus.orchestrator',request_key,'orchplus.request',runtime.json.encode(current))
   if f.drift_after_read and request_reads==1 then state.action.claim.grant_id='changed-during-observation'end
   return out
  end,
  event=function(_,pane,value)
   if value.act=='dispatch-notice' then
    local notice=assert(c.strict_decode(value.value,65536))
    f.notices=f.notices or {};table.insert(f.notices,notice);return
   end
   if value.act=='dispatch-command' then
    local command=c.strict_decode(value.value,65536);f.relays=(f.relays or 0)+1;f.last_relay=command
    if f.drop_relay then return end
    if f.stale_relay_once then
     f.stale_relay_once=false
     state.authority_revision+=1;state.action.authority_revision=state.authority_revision
     state.result={ok=false,code='stale_revision',command=command.command,request_id=command.request_id,action_id=command.action_id,grant_id=command.grant_id}
     return
    end
    local witness={spawn_namespace=command.spawn_namespace,claim_nonce=command.claim_nonce}
    if state.action.claim.spawn_claim and not p.equal(state.action.claim.spawn_claim,witness) then state.action.phase='uncertain'
    else state.action.claim.spawn_claim=witness end
    return
   end
   assert(pane==44 and value.id=='main.orchplus-spawn-relay' and value.act=='spawn_relay','dispatch callbacks use only the real ORCH relay')
   local relay=c.strict_decode(value.value,65536)
   assert(relay and relay.schema==1 and relay.source_nonce==(if f.setup_query then 'setup-alias' else 'alias') and relay.relay_endpoint=='orch-endpoint' and relay.relay_boot=='orch-boot' and relay.peer_boot=='spawn-boot','callback preserves explicit source and peer incarnations')
   assert(relay.lane_id=='lane-one' or relay.lane_id=='lane-two','callback identifies published lane')
   local body=c.strict_decode(relay.bytes,65536)
   assert(body and p.equal(body.relay_execution,{id='frame-'..relay.lane_id,incarnation='spawn-boot'}),'every callback echoes the exact observed execution receipt, not an acknowledgement')
   assert(relay.act~='ack','native submission alone never acknowledges carrier execution durability')
   table.insert(f.relay_events,copy(value))
   value={ev='action',id=value.id,act=relay.act,value=relay.bytes}
   table.insert(events,copy(value))
   if f.event_error then error('ambiguous event submission')end
  end,
 }
 f.cx=cx;f.host=host
 -- Injectable monotonic clock for the focus guard deadline; the real clock otherwise.
 injected.now=function()return if f.clock then f.clock else runtime.now()end
 f.tick=function()if not scheduled then w.start()end scheduled(cx)end
 return issued(f)
end
local function ordering_callbacks(make_fixture,act)
 for _,scope in ipairs({'view','lane','both','older-view'}) do
  local f=make_fixture()
  if scope~='lane' then f.relay_override={held=true,error='callback_pending'} end
  if scope=='lane' or scope=='both' then f.lane_override={held=true,error='callback_pending'} end
  if scope=='older-view' then f.progress=99 end
  f.tick()
  check(#f.events==1 and f.events[1].act==act and f.starts==0 and f.asks==0,
   act..' drains '..scope..' callback_pending using the exact current lane witness without native effects')
 end
 for _,scope in ipairs({'view','lane'}) do
  for _,hold in ipairs({{held=true},{held=true,error='source_changed'},{error='backpressure'},{held=true,error='revoked'}}) do
   local f=make_fixture()
   f.relay_override={held=true,error='callback_pending'}
   f.lane_override={held=true,error='callback_pending'}
   if scope=='view' then f.relay_override=hold else f.lane_override=hold end
   f.tick()
   check(#f.events==0 and f.starts==0 and f.asks==0,act..' refuses non-ordering '..scope..' holds despite another callback_pending advisory')
  end
 end
 for _,mutate in ipairs({
  function(f)f.proof_override={incarnation='stale-boot'}end,
  function(f)f.proof_override={binding='orch-endpoint:another-lane'}end,
  function(f)f.proof_override={id=''}end,
  function(f)f.receipt_drift_read=2 end,
  function(f)f.lane_drift_read=2 end,
  function(f)f.relay_drift_read=2 end,
  function(f)f.execution_drift_read=2 end,
 }) do
  local f=make_fixture();f.relay_override={held=true,error='callback_pending'};f.lane_override={held=true,error='callback_pending'}
  mutate(f);f.tick()
  check(#f.events==0 and f.starts==0 and f.asks==0,act..' callback_pending cannot bypass stale receipt, lane, incarnation or execution identity')
 end
end
local function adopt_claim(f)
 local claim=f.c.strict_decode(f.events[1].value,65536)
 f.projection.claim={spawn_namespace='spawn-native',claim_nonce='native-nonce-aaaaaaaa',executor_id=claim.executor_id,boot='fixture-boot'};f.projection.phase='claimed'
 f.state.action.claim.spawn_claim={spawn_namespace='spawn-native',claim_nonce='native-nonce-aaaaaaaa'}
end
local function begin_effect(f)
 f.tick();adopt_claim(f);f.tick();f.projection.phase='launching'
end
-- Interrupt only the second origin read: the caller has already accepted the
-- projection, but the final control-event validation has not submitted anything.
local function control_handoffs(make_fixture,prefix,effect)
 for _,loss in ipairs({'missing','stale'})do
  for _,phase in ipairs({'claim','begin'})do
   local f=make_fixture()
   if phase=='begin' then f.tick();adopt_claim(f)end
   local before=#f.events
   f[loss..'_action_read']=f.action_reads+2
   f.tick()
   check(#f.events==before and (f[effect] or 0)==0,'pre-submit '..loss..' origin emits no '..prefix..phase..' or native effect')
   f.tick();f.tick()
   check(#f.events==before+1 and f.events[before+1].act=='spawn.'..prefix..phase and (f[effect] or 0)==0,'restored origin submits exactly one '..prefix..phase)
   if phase=='claim' then adopt_claim(f);f.tick()end
   f.projection.phase='launching';f.tick();f.tick()
   check(#f.events==3 and f[effect]==1 and f.c.strict_decode(f.events[3].value,65536).result.status==(if effect=='stops' then 'stopped' else 'submitted'),'recovered '..loss..' '..prefix..phase..' completes with exactly one native effect and one result')
  end
 end
 for _,phase in ipairs({'claim','begin'})do
  local f=make_fixture()
  if phase=='begin' then f.tick();adopt_claim(f)end
  local before=#f.events
  f.event_error=true;f.tick();f.event_error=false;f.tick();f.tick()
  check(#f.events==before+1 and f.events[before+1].act=='spawn.'..prefix..phase and (f[effect] or 0)==0,'ambiguous submitted '..prefix..phase..' is not repeated or treated as native permission')
 end
 local f=make_fixture();begin_effect(f);f.event_error=true;f.tick();f.event_error=false;f.tick();f.tick()
 check(f[effect]==1 and #f.events==3,'throwing result submission cannot repeat the native '..effect..' effect')
 local exact=f.relay_events[3].value
 f.clock=999;f.tick()
 check(#f.events==3,'result delivery retry waits for its bounded interval')
 f.held_lane=true;f.relay_override={held=true,error='backpressure'};f.progress=99
 f.projection.last_authority_revision=11;f.state.action.authority_revision=11
 f.clock=1000;f.tick();f.tick()
 check(f[effect]==1 and #f.events==4 and f.relay_events[4].value==exact,'lost or backpressured '..effect..' result retries byte-for-byte without another native effect')
 f.held_lane=false;f.relay_override=nil
 for _,change in ipairs({
  function()f.projection.nonce='new-nonce'end,
  function()f.projection.claim.claim_nonce='native-nonce-bbbbbbbb'end,
  function()f.projection.boot='new-boot'end,
  function()f.projection.orch_claim.grant_id='new-base-grant'end,
  function()f.proof_override={id='new-execution'}end,
  function()f.lane_override={bind_id='new-bind'}end,
 }) do
  local before=copy(f.projection);change();f.clock=2000;f.tick()
  check(#f.events==4 and f[effect]==1,'changed execution/native identity cannot resend or repeat '..effect)
  f.projection=before;f.proof_override=nil;f.lane_override=nil
 end
 f.state.action.authority_revision=10;f.tick()
 check(#f.events==4 and f[effect]==1,'current native proof still enforces the new session revision lower bound')
 f.state.action.authority_revision=11
 local current_claim=copy(f.state.action.claim)
 f.state.action.claim.grant_id='replacement';f.clock=2000;f.tick()
 check(f[effect]==1 and #f.events==4,'replacement native grant prevents stale result retry')
 f.state.action.claim=current_claim;f.missing_relay=true;f.tick()
 check(#f.events==4,'missing current ORCH relay holds retained result bytes')
 f.missing_relay=false;f.tick()
 check(f[effect]==1 and #f.events==5 and f.relay_events[5].value==exact,'restored exact source retries only the retained result')
 f.state.action.phase='complete';f.clock=3000;f.tick()
 check(#f.events==5 and f[effect]==1,'completed peer action ends retries without clearing effect exclusion')
end
if section==nil then
 local function terminal_reattach(kind)
  local f=fixture()
  local origin=copy(f.request.origin_binding)
  local pane={pane_id='55',window_epoch=origin.window_epoch,window_key=origin.window_key,native_session_id=origin.native_session_id,window_host_id=origin.window_host_id}
  local previous_origin,previous_pane=copy(origin),copy(pane)
  previous_origin.window_epoch='previous-epoch';previous_pane.window_epoch='previous-epoch'
  local r={schema=1,origin='orchplus',op='attach_worker',request_id='reattach',action_id='action-reattach',controller_pane='44',controller_generation=1,origin_binding=origin,target_request_id='launch',target_action_id='action-launch',pane_binding=pane,worker_id='worker',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',previous_origin_binding=previous_origin,previous_pane_binding=previous_pane,attestation='same_terminal_process_no_pending_effects'}
  f.request=r;f.current=copy(r);f.projection.request=copy(r);f.state.action.action_id=r.action_id
  f.pane_kind=kind;issued(f)
  assert(f.p.decode(runtime.json.encode(f.request)))
  return f
 end
 for _,kind in ipairs({'terminal','agent'})do
  local f=terminal_reattach(kind);f.tick()
  check(#f.events==1 and f.events[1].act=='spawn.authorize' and f.asks==0 and f.starts==0,'qualified '..kind..' pane reaches retained-process authorization without relaunch')
  f.tick();check(#f.events==1,'duplicate terminal continuation does not repeat authorization')
 end
 local unrelated=terminal_reattach('browser');unrelated.tick()
 check(#unrelated.events==0,'non-terminal surface cannot authorize retained terminal continuation')
 local exited=terminal_reattach('agent');exited.exit_status=0;exited.tick()
 check(#exited.events==0,'exited agent-tagged terminal cannot authorize continuation')
 local absent=terminal_reattach('agent');absent.absent=true;absent.tick()
 check(#absent.events==0,'missing agent-tagged terminal cannot authorize continuation')
 local function launch_fixture(presentation)
  local f=fixture()
  local r={schema=1,origin='orchplus',op='launch',request_id='launch',action_id='action-launch',controller_pane='44',controller_generation=1,origin_binding=copy(f.request.origin_binding),record_id='worker',record_revision=0,work_id='work',prompt='Complete the assigned work',cwd='/work',placement='tab',fresh=true,mailbox_handle='mailbox',enrolment={worker_id='worker',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',assignment_sha256=f.c.sha256('Complete the assigned work')}}
  r.presentation=presentation
  f.request=r;f.current=copy(r);f.state.action.action_id=r.action_id
  f.projection={schema=1,kind='launch',request=copy(r),phase='resolved',orch_claim=copy(f.claim),launch={backend='native-agent',command='omp',prompt=r.prompt,cwd=r.cwd,placement=r.placement}}
  return issued(f)
 end
 local unavailable=launch_fixture();unavailable.selected_session=4;unavailable.focus=66
 unavailable.tick();unavailable.tick()
 check(unavailable.starts==0 and #unavailable.events==0 and unavailable.focus==66 and not unavailable.focus_calls,
  'native creation cannot guess the selected session or mutate focus when the SDK has no targeted start')
 check(#unavailable.notices==1 and unavailable.notices[1].code=='targeted_native_launch_unavailable'
  and unavailable.notices[1].message:find('targeted native agent API',1,true)~=nil,
  'inert exact launch grant exposes the genuine SDK prerequisite on its source once')
 for _,phase in ipairs({'resolved','claimed','launching'}) do
  local held=launch_fixture()
  if phase~='resolved' then held.tick();adopt_claim(held) end
  if phase=='launching' then held.tick();held.projection.phase='launching' end
  local before=#held.events
  held.relay_override={held=true,error='callback_pending'};held.lane_override={held=true,error='callback_pending'}
  held.tick();held.tick()
  check(held.starts==0 and #held.events==before,'callback_pending cannot authorize a new launch effect or '..phase..' transition')
 end
 local draining=launch_fixture();begin_effect(draining);draining.tick()
 local result=draining.relay_events[3].value
 draining.relay_override={held=true,error='callback_pending'};draining.lane_override={held=true,error='callback_pending'}
 draining.clock=1000;draining.tick();draining.tick()
 check(draining.starts==1 and #draining.events==4 and draining.relay_events[4].value==result,
  'callback_pending permits only the retained exact native result without resubmitting its invoked effect')
 local first=launch_fixture();first.tick();adopt_claim(first);first.state.action.claim.spawn_claim=nil
 first.tick()
 check(first.relays==1 and #first.events==1 and first.starts==0,'first persisted native tuple is relayed to ORCH before begin or effect')
 check(first.last_relay.command=='spawn_claimed' and first.last_relay.action_id=='action-launch' and first.last_relay.grant_id=='grant-one' and first.last_relay.claim_nonce==first.projection.claim.claim_nonce,'relay uses exact approved four-field native witness command')
 first.tick()
 check(#first.events==2 and first.events[2].act=='spawn.begin','earlier base grant accepts fresh witness-bearing peer claim without deadlock')
 local begin=first.c.strict_decode(first.events[2].value,65536)
 check(first.p.equal(begin.spawn_claim,first.projection.claim) and first.p.equal(begin.proof.claim.spawn_claim,first.state.action.claim.spawn_claim) and begin.request_json==first.projection.request_json and begin.authorization_nonce==first.projection.nonce,'begin carries exact immutable bytes, original authorization nonce, fresh proof and full native tuple separately')
 first.projection.phase='launching';first.tick();check(first.starts==1,'exact committed first witness permits one native effect')
 local result=first.c.strict_decode(first.events[3].value,65536)
 check(result.authorization_nonce==first.projection.nonce,'begun-effect result retains its original nonce for authoritative host reconciliation')
 local restored=launch_fixture();restored.tick();adopt_claim(restored)
 restored.projection.claim.claim_nonce='native-nonce-restored';restored.state.action.claim.spawn_claim=copy(first.state.action.claim.spawn_claim)
 restored.tick();restored.tick();restored.projection.phase='launching';restored.tick()
 check(restored.relays==1 and restored.state.action.phase=='uncertain' and restored.starts==0 and #restored.events==1,'preclaim snapshot restore changes nonce, commits visible uncertainty and never starts a second effect')
 local lost_peer=launch_fixture();lost_peer.tick();adopt_claim(lost_peer);lost_peer.state.action.claim.spawn_claim=nil;lost_peer.drop_relay=true
 lost_peer.tick();lost_peer.tick()
 check(lost_peer.relays==1 and #lost_peer.events==1 and lost_peer.starts==0 and lost_peer.w.retained().markers>0,'lost peer callback retains markers without begin or blind replay')
 local raced=launch_fixture();raced.tick();adopt_claim(raced);raced.state.action.claim.spawn_claim=nil;raced.stale_relay_once=true
 local immutable_request=raced.projection.request_json
 raced.tick()
 local refused=copy(raced.last_relay)
 check(raced.relays==1 and raced.state.action.claim.spawn_claim==nil and raced.starts==0 and #raced.events==1,
  'an intervening authority commit refuses the first witness without authorizing a native effect')
 raced.tick()
 check(raced.relays==2 and raced.last_relay.request_id~=refused.request_id
  and raced.last_relay.expected_revision>refused.expected_revision and raced.last_relay.grant_id==refused.grant_id
  and raced.last_relay.claim_nonce==refused.claim_nonce and raced.projection.request_json==immutable_request,
  'exact stale refusal permits a distinct fresh observation of the same immutable grant and native tuple')
 check(raced.starts==0 and #raced.events==1,'fresh witness observation must commit before begin or native effect')
 raced.tick();check(#raced.events==2 and raced.events[2].act=='spawn.begin','committed current witness releases the original native claim')
 raced.projection.phase='launching';raced.tick();raced.tick()
 check(raced.starts==1,'fresh witness after a no-write refusal still permits only one native effect')
 lost_peer.state.authority_revision+=1;lost_peer.state.action.authority_revision=lost_peer.state.authority_revision
 lost_peer.state.result={ok=false,code='stale_revision',command='spawn_claimed',request_id='unrelated-command',action_id=lost_peer.request.action_id,grant_id=lost_peer.claim.grant_id}
 lost_peer.tick()
 check(lost_peer.relays==1 and lost_peer.starts==0,'unrelated stale refusal cannot replace a lost witness intent')
 lost_peer.state.result.request_id=lost_peer.last_relay.request_id;lost_peer.state.result.grant_id='another-grant'
 lost_peer.tick()
 check(lost_peer.relays==1 and lost_peer.starts==0,'another grant refusal cannot replace a lost witness intent')
 for _,changed in ipairs({'boot','executor_id','spawn_namespace','claim_nonce'}) do
  local stale=launch_fixture();begin_effect(stale);stale.projection.claim[changed]='different-native-value';stale.tick()
  check(stale.starts==0 and #stale.events==2,'launching checks full tuple immediately before native effect: '..changed)
 end
 control_handoffs(launch_fixture,'','starts')
 for _,loss in ipairs({'missing','stale'})do
  local f=launch_fixture();begin_effect(f)
  f[loss..'_action_read']=f.action_reads+2;f.tick()
  check(f.starts==0 and #f.events==2,'launch final '..loss..' origin refuses native invocation')
  f.tick();f.tick()
  check(f.starts==1 and #f.events==3 and f.c.strict_decode(f.events[3].value,65536).result.status=='submitted','restored pre-effect launch origin starts once without burning its effect marker')
 end
 local invalid=launch_fixture();begin_effect(invalid);invalid.projection.launch.prompt=' ';invalid.tick()
 check(invalid.starts==0 and #invalid.events==2,'invalid native launch assignment consumes no effect or result')
 invalid.projection.launch.prompt=invalid.request.prompt;invalid.tick();invalid.tick()
 check(invalid.starts==1 and #invalid.events==3,'valid restored assignment invokes native launch exactly once')
 local ambiguous=launch_fixture();begin_effect(ambiguous);ambiguous.start_error=true;ambiguous.tick();ambiguous.tick()
 check(ambiguous.starts==1 and #ambiguous.events==3 and ambiguous.c.strict_decode(ambiguous.events[3].value,65536).result.status=='uncertain','throwing native launch remains marked and is never repeated')
 local function result_of(f,n)return f.c.strict_decode(f.events[n].value,65536).result end
 for _,presentation in ipairs({'user_new_tab','coordinator_adjacent','background'}) do
  local selected=launch_fixture(presentation);selected.start_keeps_focus=true
  begin_effect(selected);selected.tick()
  check(selected.starts==1 and selected.start_options.how=='tab' and selected.start_options.cwd=='/work','native conversation receives exact placement and cwd')
  check(selected.focus==(if presentation=='user_new_tab' then 55 else 44),'explicit presentation owns focus behavior without changing the native launch')
  selected.focus=55;selected.tick()
  check(selected.focus==(if presentation=='user_new_tab' then 55 else 44),'only background/adjacent delayed native focus is restored')
  local terminal=launch_fixture(presentation);terminal.projection.launch.backend='local-terminal';terminal.pane_kind='terminal'
  begin_effect(terminal);terminal.tick()
  check(terminal.terminals==1 and terminal.starts==0 and terminal.terminal_presentation.focus==(presentation=='user_new_tab'),'terminal new-tab uses the same explicit focus contract')
  if presentation=='background' then
   check(terminal.focus==44 and terminal.closes==nil and terminal.stops==nil,
    'background terminal successor opens an unfocused tab without closing the predecessor or replacing the controller')
  end
 end
 local pending=launch_fixture('user_new_tab');pending.missing_relay=true;pending.tick();pending.tick()
 check(#pending.events==0 and pending.starts==0,'a missing ORCH relay holds without transport fallback or effect permission')
 pending.missing_relay=false;begin_effect(pending);pending.tick()
 check(pending.starts==1 and #pending.relay_events==3,'the actual ORCH panel relays native claim, begin and result without a SPAWN transport pane')
 for _,field in ipairs({'peer','host_pane_id','source_nonce'}) do
  local foreign=launch_fixture();foreign.relay_override={[field]='foreign'};foreign.tick()
  check(#foreign.events==0 and foreign.starts==0,'relay cannot borrow another '..field)
 end
 for _,override in ipairs({
  {unexpected=true},{held='yes'},{error=false},{releases={{lane_id='gone',peer_boot=1}}},
  {releases={{lane_id='gone',peer_boot='spawn-boot',unexpected=true}}},
  {releases={named={lane_id='gone',peer_boot='spawn-boot'}}},
 }) do
  local malformed=launch_fixture();malformed.relay_override=override;malformed.tick()
  check(#malformed.events==0,'closed relay metadata rejects unknown fields and malformed release/held/error shapes')
 end
 for _,override in ipairs({{bind_id=1},{release_held='yes'},{unexpected=true},{messages=runtime.json.array()}}) do
  local malformed=launch_fixture();malformed.lane_override=override;malformed.tick()
  check(#malformed.events==0,'closed lane metadata rejects unknown or wrongly typed publisher fields')
 end
 local across=launch_fixture();across.leading_panel=true;table.insert(across.host.panes,47);across.tick()
 check(#across.events==1,'logical scan admits the 33rd lane across real panels independently of 24 physical carrier slots')
 local empty=launch_fixture();empty.relay_override={releases={}};empty.tick()
 check(#empty.events==1,'actual publisher empty Lua release collection remains valid')
 for _,flag in ipairs({'foreign_program','foreign_relay_surface','foreign_execution_role','truncated_relay','missing_execution','setup_parked','foreign_session','old_transport_only','pending_lane','held_lane','duplicate_lane'}) do
  local foreign=launch_fixture();foreign[flag]=true;foreign.tick()
  check(#foreign.events==0 and foreign.starts==0,'relay refuses '..flag..' without weakening native controller membership')
 end
 for _,field in ipairs({'incarnation','route','binding'}) do
  local foreign=launch_fixture();foreign.proof_override={[field]='foreign'};foreign.tick()
  check(#foreign.events==0 and foreign.starts==0,'carrier execution proof must match the actual peer, route and endpoint: '..field)
 end
 local source_race=launch_fixture();source_race.relay_drift_read=2;source_race.tick()
 check(#source_race.events==0 and source_race.starts==0,'relay host reload between observation and claim refuses stale native permission')
 source_race.relay_drift_read=nil;begin_effect(source_race);source_race.relay_change_during_start=true;source_race.tick();source_race.tick()
 check(source_race.starts==1 and #source_race.events==2,'relay source reload during native start suppresses stale result and never repeats the effect')
 local native_race=launch_fixture();begin_effect(native_race)
 native_race.relay_drift_read=native_race.metadata_reads+3;native_race.tick()
 check(native_race.starts==0 and #native_race.events==2,'final exact relay incarnation check prevents native start after a reload')
 native_race.relay_drift_read=nil;native_race.tick();native_race.tick()
 check(native_race.starts==1 and #native_race.events==3,'an uninvoked native action remains available only under the restored exact source and grant')
 for _,stage in ipairs({'claim','native'}) do
  local changed=launch_fixture()
  if stage=='native' then begin_effect(changed) end
  local before=#changed.events
  changed.execution_drift_read=(changed.execution_reads or 0)+(if stage=='native' then 3 else 2);changed.tick()
  check(changed.starts==0 and #changed.events==before,'changed exact peer execution bytes refuse '..stage..' even with the same carrier proof')
  changed.execution_drift_read=nil;changed.tick()
  check(#changed.events==before+1 and changed.starts==(if stage=='native' then 1 else 0),'unchanged restored execution bytes permit only the previously unsubmitted '..stage)
 end
 local focused=launch_fixture();begin_effect(focused);focused.tick()
 check(focused.starts==1 and focused.focus==44 and focused.refocused==1,'a managed native launch returns focus to the previously focused controller pane')
 focused.tick();focused.tick()
 check(focused.focus==44 and focused.refocused==1 and focused.focus_calls==1,'a synchronous focus change is restored exactly once, with no second focus call')
 focused.focus=55;focused.tick()
 check(focused.focus==44 and focused.refocused==2,'after an immediate restore the guard still catches one late focus on the new pane')
 focused.focus=55;focused.tick()
 check(focused.focus==55 and focused.refocused==2 and #focused.events==3,'a guard restores at most once after the immediate restore and never touches the launch result')
 -- Late focus (macOS): agents:start returns before the new agent tab takes focus.
 local late=launch_fixture();begin_effect(late);late.start_keeps_focus=true;late.clock=1000;late.tick()
 check(late.starts==1 and late.focus==44 and late.refocused==nil and result_of(late,3).status=='submitted','a launch that leaves focus alone needs no immediate restore and still submits')
 late.tick();check(late.focus==44 and late.refocused==nil,'a guard acts only when focus sits on the created pane')
 late.clock=5999;late.focus=55;late.tick()
 check(late.focus==44 and late.refocused==1,'focus that lands on the new pane later is restored to the controller pane')
 late.focus=55;late.tick()
 check(late.focus==55 and late.refocused==1 and #late.events==4 and late.relay_events[4].value==late.relay_events[3].value,'a late restore happens once; elapsed retry time repeats only the exact unacknowledged result')
 local operator=launch_fixture();begin_effect(operator);operator.start_keeps_focus=true;operator.tick()
 operator.focus=66;operator.tick();operator.focus=55;operator.tick()
 check(operator.focus==55 and operator.refocused==nil,'focus seen on a third pane drops the guard, so a later deliberate visit to the new pane is never stolen back')
 local expired=launch_fixture();begin_effect(expired);expired.start_keeps_focus=true;expired.clock=1000;expired.tick()
 expired.clock=6001;expired.focus=55;expired.tick()
 check(expired.focus==55 and expired.refocused==nil,'focus that reaches the new pane after the 5 s guard is left alone')
 -- Back to back: the second launch starts while focus still sits on the first new pane (its
 -- restore threw); its guard inherits the first guard's controller pane, not the earlier worker.
 local pair=launch_fixture();begin_effect(pair)
 local second=copy(pair.request);second.request_id='launch-two';second.action_id='action-launch-two';second.consumed=runtime.json.array()
 local second_state=copy(pair.state);second_state.action.action_id=second.action_id
 local second_projection=copy(pair.projection);second_projection.request=copy(second);second_projection.request.consumed=runtime.json.array()
 second_projection.request_json=runtime.json.encode(second);second_state.action.request_sha256=pair.c.sha256(second_projection.request_json)
 pair.second={request=second,state=second_state,projection=second_projection};pair.host.panes={44,55,56,66}
 pair.start_panes={55,56};pair.focus_error=true;pair.tick()
 check(pair.starts==2 and pair.focus==56 and pair.focus_calls==2 and #pair.events==4 and result_of(pair,3).status=='submitted' and result_of(pair,4).pane_binding.pane_id=='56','two launches in one tick both submit although each immediate restore threw')
 pair.focus_error=false;pair.tick()
 check(pair.focus==44 and pair.refocused==1,'focus on the second new pane returns to the original controller pane, not the first worker')
 pair.focus=55;pair.tick()
 check(pair.focus==44 and pair.refocused==2 and #pair.events==4,'the first launch guard still restores its own late focus to the controller pane')
 local moved=launch_fixture();begin_effect(moved);moved.focus=66;moved.tick()
 check(moved.starts==1 and moved.focus==66 and moved.refocused==1,'focus returns to the pane the owner had focused, not a fixed controller pane')
 -- Bookkeeping: markers survive while the ORCH+ action is claimed, uncertain or unreadable, and
 -- are released only once it reads back settled, without enabling any new effect.
 local settled=launch_fixture();begin_effect(settled);settled.tick()
 local held=settled.w.retained()
 check(settled.starts==1 and #settled.events==3 and held.markers==3 and held.requests==1,'launch control and effect markers are retained while the ORCH+ claim is live')
 for _,phase in ipairs({'uncertain','claimed'})do
  settled.state.action.phase=phase;settled.tick();settled.tick()
  check(settled.w.retained().markers==held.markers and settled.starts==1 and #settled.events==3,'a '..phase..' ORCH+ action keeps every marker and never repeats the launch')
 end
 settled.state.action.phase='complete';settled.missing_action=true;settled.tick();settled.tick()
 check(settled.w.retained().markers==held.markers,'unreadable ORCH+ action evidence never drops a marker')
 settled.missing_action=nil;settled.tick();settled.tick()
 check(settled.w.retained().markers==held.markers,'terminal or missing action alone is never an ACK')
 control_projection(settled,'reconcile_session',{1})
 settled.state.authority_revision=9;settled.tick()
 check(settled.w.retained().markers==held.markers,'stale current-control consumed page cannot reclaim native markers')
 settled.state.authority_revision=10;settled.state.spawn_namespace='different-spawn';settled.tick()
 check(settled.w.retained().markers==held.markers,'another SPAWN namespace cannot acknowledge this effect')
 settled.state.spawn_namespace='spawn-native'
 settled.tick();settled.tick()
 local released=settled.w.retained()
 check(released.markers==0 and released.requests==0 and settled.starts==1 and #settled.events==3,'a settled ORCH+ action releases its markers and starts nothing')
 -- A compacted control page no longer lists the completed serial as a hole.
 -- Exercise the real native launch, then observe only its authenticated floor.
 local function floor_page(f)
  f.state.action.phase='complete'
  local projection=control_projection(f,'reconcile_session')
  projection.request.settled_before=2
  f.state.sessions.session.control.request_floor=2
  f.state.control.request_bytes=runtime.json.encode(projection.request)
 end
 for _,mismatch in ipairs({'authority_namespace','logical_session_id','admission_seq','revision','bytes','membership'}) do
  local f=launch_fixture();begin_effect(f);f.tick();floor_page(f)
  if mismatch=='revision' then f.state.authority_revision=9
  elseif mismatch=='bytes' then f.state.control.request_bytes='{}'
  elseif mismatch=='membership' then f.host.panes={45,55}
  else
   f.state.control.request[mismatch]=if mismatch=='admission_seq' then 2 else 'different'
   f.state.control.request_bytes=runtime.json.encode(f.state.control.request)
  end
  f.tick();f.tick()
  check(f.w.retained().markers==3 and f.w.retained().requests==1 and f.starts==1,'floor-only '..mismatch..' mismatch preserves native effect exclusion')
 end
 local floorOnly=launch_fixture();begin_effect(floorOnly);floorOnly.tick();floor_page(floorOnly)
 floorOnly.tick();floorOnly.tick()
 check(floorOnly.w.retained().markers==0 and floorOnly.w.retained().requests==0 and floorOnly.starts==1 and #floorOnly.events==3,'floor-only settled control releases completed markers without another native effect')
end
if section==nil or section=='failed_startup' then
 local function startup_fixture(backend)
  local f=fixture()
  local r={schema=1,origin='orchplus',op='mailbox_retire',request_id='failed-startup',action_id='action-failed-startup',
   controller_pane='44',controller_generation=1,origin_binding=copy(f.request.origin_binding),logical_session_id='session',
   worker_id='worker',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',
   handle='mailbox',expected_generation=1,mode='retire',settlement_revision=5,report_floor=0,reply_floor=0,
   report_chain_sha256=f.c.sha256('report-files-v1\nmailbox\n'),grant_id='startup-retirement'}
  local original={pane_id='55',window_epoch='epoch',window_key='',native_session_id='3',window_host_id='7'}
  f.request=r;f.current=copy(r);f.state.action.action_id=r.action_id
  f.projection={schema=1,kind='authorize',request=copy(r),nonce='startup-challenge',
   startup_cleanup={pane_binding=original,backend=backend or 'local-terminal'}}
  if backend~='native-agent' then f.pane_kind='terminal' end
  return issued(f)
 end
 for _,backend in ipairs({'native-agent','local-terminal'})do for _,state in ipairs({'exited','absent'})do
  local f=startup_fixture(backend);f.agent_state=state
  if state=='absent' then f.absent=true;f.host.panes={44,66} end
  f.tick()
  local value=assert(f.events[1] and f.c.strict_decode(f.events[1].value,65536),'fresh native cleanup authorization')
  check(#f.events==1 and f.events[1].act=='spawn.authorize' and value.nonce=='startup-challenge'
   and value.native_observation.observation==state
   and f.p.equal(value.native_observation.pane_binding,f.projection.startup_cleanup.pane_binding),
   backend..' failed startup carries exact fresh '..state..' evidence on its existing private authorization')
  check(f.starts==0 and f.asks==0 and f.stops==nil and f.closes==nil,'failed-startup observation performs no native lifecycle effect')
  f.tick();check(#f.events==1,'the nonce-bound cleanup witness is submitted only once')
 end end
 for _,state in ipairs({'idle','working','waiting_input','unknown'})do
  local f=startup_fixture();f.agent_state=state;f.tick()
  check(#f.events==0 and f.stops==nil and f.closes==nil,'live/unknown '..state..' native target grants no cleanup witness')
 end
 for _,kind in ipairs({'partial-absence','parked','foreign-session','foreign-host','old-epoch-exited','observation-drift'})do
  local f=startup_fixture();f.agent_state='exited'
  if kind=='partial-absence' then f.absent=true
  elseif kind=='parked' then
   local pane=f.cx.session.pane
   f.cx.session.pane=function(self,id)local info=pane(self,id);if id==55 then info.tab=nil end return info end
  elseif kind=='foreign-session' then f.foreign_session=true
  elseif kind=='foreign-host' then f.host.id=8
  elseif kind=='old-epoch-exited' then f.projection.startup_cleanup.pane_binding.window_epoch='original-old-epoch'
  else f.busy_on_list=2 end
  f.tick()
  check(#f.events==0,'native cleanup witness refuses '..kind)
 end
 local continued=startup_fixture();continued.projection.startup_cleanup.pane_binding.window_epoch='original-old-epoch'
 continued.absent=true;continued.host.panes={44,66};continued.tick()
 check(#continued.events==1 and continued.c.strict_decode(continued.events[1].value,65536).native_observation.observation=='absent',
  'a fresh continued controller may prove original old-epoch absence without rebinding a restored pane')
 local stale=startup_fixture();stale.agent_state='exited';stale.proof_override={id='changed-execution'};stale.tick()
 check(#stale.events==0,'a replaced private execution receipt cannot carry native cleanup evidence')
end

if section==nil or section=='wake' then
local good=fixture()
check(good.p.decode(runtime.json.encode(good.request))~=nil,'fixture uses valid immutable publication')
check(not good.w.origin_ok(good.cx,45,good.request,good.claim,good.projection),'retained SPAWN transport pane cannot authorize the new ORCH relay')
good.tick()
check(#good.events==1 and good.events[1].act=='spawn.authorize','only exact live request emits private nonce response')
local observation=good.c.strict_decode(good.events[1].value,65536)
check(good.p.equal(observation.orch_claim,good.claim) and observation.nonce=='challenge','nonce response carries exact observed action claim')
good.tick();check(#good.events==1,'one window emits nonce once')
ordering_callbacks(fixture,'spawn.authorize')
ordering_callbacks(function()local f=fixture();f.projection=control_projection(f);return f end,'spawn.control_authorize')
for _,op in ipairs({'admit_session','reconcile_session','close_session'}) do
 local current=fixture();current.projection=control_projection(current,op);current.tick()
 check(#current.events==1 and current.events[1].act=='spawn.control_authorize','fresh exact current state authorizes '..op)
 local reply=current.c.strict_decode(current.events[1].value,65536)
 check(reply.peer.protocol==2 and reply.peer.authority_revision==10 and reply.peer.session.admission_seq==1 and reply.request_json==current.projection.request_json,'control callback preserves exact challenge and current peer proof')
 for _,field in ipairs({'protocol','phase','authority_namespace','authority_revision','spawn_namespace'}) do
  local stale=fixture();stale.projection=control_projection(stale,op);stale.state[field]=if field=='protocol' or field=='authority_revision' then 1 else 'stale';stale.tick()
  check(#stale.events==0,'stale '..field..' refuses '..op)
 end
 local replaced=fixture();replaced.projection=control_projection(replaced,op);replaced.state.control.request_bytes='{}';replaced.tick()
 check(#replaced.events==0,'replacement control request bytes cannot authorize old nonce')
 local parked=fixture();parked.projection=control_projection(parked,op);parked.host.panes={45,55};parked.tick()
 check(#parked.events==0,'control source requires current native membership')
 local prepared=fixture();prepared.projection=control_projection(prepared,op);prepared.state.phase='prepared';prepared.tick()
 check(#prepared.events==0,'prepared peer never authorizes ordinary compact current control')
end
for _,field in ipairs({'authority_namespace','authority_revision','admission_seq','request_serial','request_sha256'}) do
 local stale=fixture();stale.state.action[field]=if field=='authority_revision' then 9 elseif field=='admission_seq' or field=='request_serial' then 2 else 'stale';stale.tick()
 check(#stale.events==0,'canonical native proof rejects stale '..field)
end
local exact_bytes=fixture();exact_bytes.projection.request_json=' '..exact_bytes.projection.request_json;exact_bytes.tick()
check(#exact_bytes.events==0,'semantically identical but non-original request bytes cannot authorize')
do
 local function setup_fixture()
  local f=fixture()
  local q={schema=2,origin='orchplus',op='catalog',request_id='setup-query',action_id='setup-action',setup_origin={host_pane_id='12',window_key='',window_epoch='setup-epoch',native_session_id='3',window_host_id='7'}}
  f.setup_query=true;f.setup_index={version=1,host_pane_id='12',source_nonce='setup-alias'}
  f.request=q;f.current=copy(q);f.projection={schema=2,kind='setup_catalog',request=copy(q),observation_id='fixture-observation'}
  return f
 end
 ordering_callbacks(setup_fixture,'spawn.setup_catalog')
 local exact=setup_fixture();exact.tick()
 check(#exact.events==1 and exact.events[1].act=='spawn.setup_catalog' and exact.p.equal(exact.c.strict_decode(exact.c.strict_decode(exact.events[1].value,65536).request_json,8192),exact.request),'native setup observation binds actual host/session/window, host-pane view and exact request')
 local retained=exact.w.retained()
 check(exact.asks==0 and exact.starts==0 and exact.action_reads==0 and retained.requests==0 and retained.markers==0,'setup observation creates no fake controller claim, execution marker or native effect')
 check(not exact.w.origin_ok(exact.cx,45,exact.request),'setup origin cannot authorize ordinary dispatch effects')
 for _,field in ipairs({'host_pane_id','window_key','window_epoch','native_session_id','window_host_id'}) do
  local wrong=setup_fixture();wrong.projection.request.setup_origin[field]='other';wrong.tick()
  check(#wrong.events==0,'setup refuses altered native origin '..field)
 end
 for _,field in ipairs({'missing_setup_index','missing_setup_request','setup_parked','setup_truncated'}) do
  local hidden=setup_fixture();hidden[field]=true;hidden.tick()
  check(#hidden.events==0,'setup requires actual visible untruncated source evidence: '..field)
 end
 local forged=setup_fixture();forged.setup_index.host_pane_id='other';forged.tick()
 check(#forged.events==0,'copied setup request cannot override its actual host-pane view binding')
 local duplicate=setup_fixture();duplicate.setup_duplicate=true;table.insert(duplicate.host.panes,47);duplicate.tick()
 check(#duplicate.events==0,'ambiguous live source views refuse setup observation')
 local moved=setup_fixture();moved.host.panes={45,55};moved.tick()
 check(#moved.events==0,'setup source must be a member of the current native host')
 local disconnected=setup_fixture();disconnected.host.state='disconnected';disconnected.tick()
 check(#disconnected.events==0,'disconnected native host cannot bind setup')
 local replaced=setup_fixture();replaced.current.request_id='new-query';replaced.tick()
 check(#replaced.events==0,'replaced live setup query invalidates the earlier bridge projection')
 local function migration_fixture(operation)
  local f=setup_fixture()
  f.projection={schema=2,kind='migration',request=copy(f.request),request_json=runtime.json.encode(f.request),
   operation=operation or 'source',nonce='migration-nonce',boot='spawn-boot',deadline=0.25}
  if operation and operation~='source' then
   local proof={source_schema=3,source_revision=12,source_sha256=string.rep('c',64),candidate_namespace='orch-candidate',
    protocol=1,state='ready',phase='stable',managed_sha256=string.rep('b',64),pending_immutable=0,blockers=0}
   f.migration_peer={protocol=2,phase='legacy',source_nonce='setup-alias',host_pane_id='12',authority_revision=12,source_sha256=proof.source_sha256,
    qualification={proof=proof,selection={logical_session_ids=runtime.json.array(),mailbox_handles=runtime.json.array()}}}
   f.projection.peer=f.p.clone(f.migration_peer)
   f.projection.expected=copy(proof);f.projection.expected.source_schema=1;f.projection.expected.source_namespace='spawn-native';f.projection.expected.candidate_namespace='spawn-native'
  end
  return f
 end
 local function bootstrap_fixture()
  local f=migration_fixture()
  f.projection.operation='bootstrap'
  f.projection.creation={request_id='create-one',orch_session_id='session-one',owner_id='owner-one',generation=1,
   authority_namespace='orch-candidate',source_nonce='setup-alias'}
  f.bootstrap_reads={};f.bootstrap_bytes={}
  f.bootstrap_roles={['main.orchestration-result']='orchplus.orchestration.result',['main.ownership-alias']='orchplus.alias',['main.dispatch-state']='orchplus.dispatch'}
  f.bootstrap_nodes={
   ['main.orchestration-result']={ok=true,code='controller_granted',request_id='create-one',orch_session_id='session-one',
    owner_id='owner-one',generation=1,revision=2,execution_epoch=1,message='Durable ownership granted; no native launch was performed.',
    owner={owner_id='owner-one',generation=1,phase='active',owner_active=true,pane_binding={host_pane_id='12',alias_nonce='setup-alias'},
     created_at_ms=0,pending_executors=0,pending_executor_evidence='observed'}},
   ['main.ownership-alias']={version=2,authority_version=5,authority_namespace='orch-candidate',revision=2,alias_nonce='setup-alias',
    host_pane_id='12',orch_session_id='session-one',session_closed=false,config_open=false,
    owners={controller={owner_id='owner-one',generation=1,alias_nonce='setup-alias'}}},
   ['main.dispatch-state']={version=2,authority_version=5,name='Session',source_nonce='setup-alias',host_pane_id='12',orch_session_id='session-one',
    owner_id='owner-one',owner_generation=1,protocol=2,phase='prepared',authority_namespace='orch-candidate',authority_revision=2,
    next_admission_seq=1,sessions={},session_control={phase='open',generation_floor=0,request_floor=0,next_request_serial=1,last_authority_revision=0},
    controller_phase='active',revision=2,uncertain_actions=runtime.json.array()},
  }
  return f
 end
 local bootstrap=bootstrap_fixture();bootstrap.tick()
 local callback=if bootstrap.events[1] then bootstrap.c.strict_decode(bootstrap.events[1].value,65536) else nil
 check(#bootstrap.events==1 and bootstrap.events[1].act=='spawn.migration' and callback
  and bootstrap.p.fields(callback,{request_json=true,nonce=true,executor_id=bootstrap.p.id,relay_execution=true,creation=bootstrap.p.bootstrap_creation})
  and bootstrap.p.equal(callback.creation,bootstrap.projection.creation) and callback.peer==nil
  and callback.request_json==bootstrap.projection.request_json
  and bootstrap.p.equal(callback.relay_execution,{id='frame-lane-one',incarnation='spawn-boot'}),'bootstrap emits exact closed Create witness and native receipt')
 for key in pairs(bootstrap.bootstrap_roles) do check(bootstrap.bootstrap_reads[key]==2,'bootstrap independently reads '..key..' twice') end
 check(bootstrap.asks==0 and bootstrap.starts==0 and bootstrap.action_reads==0 and bootstrap.w.retained().markers==0,'bootstrap witness performs no native effect')
 local bootstrap_mutations={
  missing_creation=function(f)f.projection.creation=nil end,
  extra_creation=function(f)f.projection.creation.extra=true end,
  expected=function(f)f.projection.expected={}end,
  peer=function(f)f.projection.peer={}end,
  boot=function(f)f.projection.boot='other'end,
  receipt=function(f)f.proof_override={incarnation='other'}end,
  receipt_id=function(f)f.proof_override={id=''}end,
  relay_incarnation=function(f)f.relay_drift_read=3 end,
  execution=function(f)f.execution_drift_read=3 end,
  origin=function(f)f.bootstrap_origin_drift=true end,
  bytes=function(f)f.projection.request_json..=' 'end,
  deadline=function(f)f.projection.deadline=-1 end,
  refused=function(f)f.bootstrap_nodes['main.orchestration-result'].ok=false end,
  result_code=function(f)f.bootstrap_nodes['main.orchestration-result'].code='controller_occupied'end,
  missing_owner=function(f)f.bootstrap_nodes['main.orchestration-result'].owner=nil end,
  inactive=function(f)f.bootstrap_nodes['main.orchestration-result'].owner.owner_active=false end,
  uncertain=function(f)f.bootstrap_nodes['main.orchestration-result'].owner.phase='uncertain'end,
  pending=function(f)f.bootstrap_nodes['main.orchestration-result'].owner.pending_executors=1 end,
  unobserved=function(f)f.bootstrap_nodes['main.orchestration-result'].owner.pending_executor_evidence='unconfirmed'end,
  closed=function(f)f.bootstrap_nodes['main.ownership-alias'].session_closed=true end,
  no_controller=function(f)f.bootstrap_nodes['main.ownership-alias'].owners.controller=nil end,
  admitted=function(f)f.bootstrap_nodes['main.dispatch-state'].session_control.admitted=true end,
  admitted_false=function(f)f.bootstrap_nodes['main.dispatch-state'].session_control.admitted=false end,
  session_shape=function(f)f.bootstrap_nodes['main.dispatch-state'].session_control=runtime.json.array()end,
  logical_session=function(f)local d=f.bootstrap_nodes['main.dispatch-state'];d.logical_session_id=d.orch_session_id;d.orch_session_id=nil end,
 }
 for name,mutate in pairs(bootstrap_mutations) do
  local f=bootstrap_fixture();mutate(f);f.tick()
  check(#f.events==0 and f.asks==0 and f.starts==0,'bootstrap refuses '..name)
 end
 for _,spec in ipairs({
  {'main.orchestration-result',{'request_id','orch_session_id','owner_id','generation','execution_epoch','revision'}},
  {'main.ownership-alias',{'orch_session_id','authority_namespace','alias_nonce','host_pane_id','authority_version','revision'}},
  {'main.dispatch-state',{'orch_session_id','authority_namespace','source_nonce','host_pane_id','owner_id','owner_generation','controller_phase','authority_version','revision','authority_revision'}},
 }) do
  for _,field in ipairs(spec[2]) do
   local f=bootstrap_fixture();local value=f.bootstrap_nodes[spec[1]]
   value[field]=if type(value[field])=='number' then -1 else 'stale';f.tick()
   check(#f.events==0,'bootstrap rejects mismatched '..spec[1]..' '..field)
   local missing=bootstrap_fixture();missing.bootstrap_nodes[spec[1]][field]=nil;missing.tick()
   check(#missing.events==0,'bootstrap requires '..spec[1]..' '..field)
  end
 end
 for _,target in ipairs({'owner','binding','controller'}) do
  for _,field in ipairs(if target=='binding' then {'host_pane_id','alias_nonce'} elseif target=='controller' then {'owner_id','generation','alias_nonce'} else {'owner_id','generation'}) do
   local f=bootstrap_fixture()
   local value=if target=='controller' then f.bootstrap_nodes['main.ownership-alias'].owners.controller elseif target=='binding' then f.bootstrap_nodes['main.orchestration-result'].owner.pane_binding else f.bootstrap_nodes['main.orchestration-result'].owner
   value[field]=if field=='generation' then 2 else 'stale';f.tick()
   check(#f.events==0,'bootstrap binds '..target..' '..field)
  end
 end
 for key in pairs(bootstrap.bootstrap_roles) do
  for _,failure in ipairs({'missing','drift','role','truncated','duplicate','oversized','array'}) do
   local f=bootstrap_fixture()
   if failure=='missing' then f.bootstrap_nodes[key]=nil
   elseif failure=='drift' then f.bootstrap_drift=key
   elseif failure=='role' then f.bootstrap_wrong_role=key
   elseif failure=='truncated' then f.bootstrap_truncated=key
   elseif failure=='duplicate' then f.bootstrap_bytes[key]='{"version":2,"version":2}'
   elseif failure=='oversized' then f.bootstrap_bytes[key]=string.rep(' ',65537)
   else f.bootstrap_nodes[key]=runtime.json.array() end
   f.tick();check(#f.events==0,'bootstrap rejects '..failure..' actual '..key)
  end
 end
 for _,operation in ipairs({'source','inspect','prepare','finish'}) do
  local f=migration_fixture(operation);f.projection.creation=bootstrap.p.clone(bootstrap.projection.creation);f.tick()
  check(#f.events==0,operation..' excludes bootstrap creation')
 end
 for _,operation in ipairs({'source','inspect','prepare','finish'}) do
  local f=migration_fixture(operation);f.tick()
  check(#f.events==1 and f.events[1].act=='spawn.migration','native migration witnesses '..operation)
  local value=f.c.strict_decode(f.events[1].value,65536)
  check(f.p.fields(value,{request_json=true,nonce=true,executor_id=f.p.id,relay_execution=true},{peer=true})
   and value.request_json==f.projection.request_json and value.nonce==f.projection.nonce
   and f.p.equal(value.relay_execution,{id='frame-lane-one',incarnation='spawn-boot'})
   and f.p.equal(value.peer,f.projection.peer),'migration callback contains exact request, challenge, executor, receipt and complete peer')
  check((f.migration_reads or 0)==(if operation=='source' then 0 else 2),'migration reads exact native peer twice only for paired operations')
  local retained=f.w.retained()
  check(f.asks==0 and f.starts==0 and f.action_reads==0 and retained.requests==0 and retained.markers==0,'migration witness has no native effects or managed authorizations')
 end
 local mutations={
  extra=function(f)f.projection.extra=true end,
  operation=function(f)f.projection.operation='reset'end,
  nonce=function(f)f.projection.nonce=''end,
  boot=function(f)f.projection.boot='stale-boot'end,
  deadline=function(f)f.projection.deadline='0'end,
  request=function(f)f.projection.request.request_id='other'end,
  bytes=function(f)f.projection.request_json..=' 'end,
  expected=function(f)f.projection.expected.source_namespace=nil end,
  missing_peer=function(f)f.projection.peer=nil end,
  peer_extra=function(f)f.migration_peer.extra=true;f.projection.peer=f.p.clone(f.migration_peer)end,
  peer_nonce=function(f)f.migration_peer.source_nonce='stale';f.projection.peer=f.p.clone(f.migration_peer)end,
  peer_host=function(f)f.migration_peer.host_pane_id='13';f.projection.peer=f.p.clone(f.migration_peer)end,
  peer_revision=function(f)f.migration_peer.authority_revision+=1;f.projection.peer=f.p.clone(f.migration_peer)end,
  peer_hash=function(f)f.migration_peer.source_sha256=string.rep('d',64);f.projection.peer=f.p.clone(f.migration_peer)end,
  peer_namespace=function(f)f.migration_peer.authority_namespace='other';f.projection.peer=f.p.clone(f.migration_peer)end,
  peer_selection=function(f)f.migration_peer.qualification.selection.logical_session_ids={};f.projection.peer=f.p.clone(f.migration_peer)end,
  captured_peer=function(f)f.projection.peer.phase='prepared'end,
  peer_drift=function(f)f.migration_drift_read=2 end,
  origin_drift=function(f)f.migration_origin_drift=true end,
  relay_drift=function(f)f.relay_drift_read=3 end,
  execution_drift=function(f)f.execution_drift_read=3 end,
  receipt=function(f)f.proof_override={incarnation='stale-boot'}end,
  truncated=function(f)f.migration_truncated=true end,
 }
 for name,mutate in pairs(mutations) do
  local f=migration_fixture('prepare');mutate(f);f.tick()
  check(#f.events==0 and f.asks==0 and f.starts==0,'migration refuses '..name..' without effect')
 end
 for _,field in ipairs({'expected','peer'}) do
  local f=migration_fixture();f.projection[field]={};f.tick()
  check(#f.events==0,'source migration excludes '..field)
 end
 for _,field in ipairs({'host_pane_id','window_key','window_epoch','native_session_id','window_host_id'}) do
  local f=migration_fixture();f.projection.request.setup_origin[field]='other';f.projection.request_json=runtime.json.encode(f.projection.request);f.tick()
  check(#f.events==0,'migration rejects mismatched current native '..field)
 end
 local currentMigration=migration_fixture('finish')
 currentMigration.migration_peer.phase='stable';currentMigration.migration_peer.authority_namespace='orch-candidate'
 currentMigration.migration_peer.qualification.proof.protocol=2;currentMigration.migration_peer.qualification.proof.source_namespace='orch-candidate'
 currentMigration.projection.peer=currentMigration.p.clone(currentMigration.migration_peer);currentMigration.tick()
 check(#currentMigration.events==1,'native current migration validates exact qualified source namespace')
 local legacyNamespace=migration_fixture('prepare')
 legacyNamespace.migration_peer.authority_namespace='orch-candidate'
 legacyNamespace.projection.peer=legacyNamespace.p.clone(legacyNamespace.migration_peer);legacyNamespace.tick()
 check(#legacyNamespace.events==1,'legacy native migration accepts optional exact candidate namespace before source namespace is persisted')
 local optionalNamespace=migration_fixture('finish')
 optionalNamespace.migration_peer.qualification.proof.protocol=2;optionalNamespace.migration_peer.qualification.proof.source_namespace='orch-candidate'
 optionalNamespace.projection.peer=optionalNamespace.p.clone(optionalNamespace.migration_peer);optionalNamespace.tick()
 check(#optionalNamespace.events==1,'native migration preserves wrapper namespace optionality while validating qualified protocol-two namespace')
 for _,field in ipairs({'missing_setup_index','missing_setup_request','setup_parked','setup_truncated','missing_relay','foreign_relay_surface','held_lane'}) do
  local f=migration_fixture();f[field]=true;f.tick()
  check(#f.events==0,'migration requires live genuine native origin: '..field)
 end
 local lostMigration=migration_fixture();lostMigration.host.state='disconnected';lostMigration.tick()
 check(#lostMigration.events==0,'migration cannot witness disconnected host')
 local movedMigration=migration_fixture();movedMigration.host.panes={45,55};movedMigration.tick()
 check(#movedMigration.events==0,'migration cannot witness source outside current host membership')
end
local unrelated=fixture();unrelated.state.action.action_id='other-action';unrelated.tick()
check(#unrelated.events==0,'copied owner and enrolment cannot authorize unrelated action')
local changed=fixture();changed.current.message_id='different-message';changed.tick()
check(#changed.events==0,'same action with changed exact request refuses authorization')
local inactive=fixture();inactive.state.action.phase='uncertain';inactive.tick()
check(#inactive.events==0,'uncertain or inactive action cannot authorize transport')
local drift=fixture();drift.drift_after_read=true;drift.tick()
check(#drift.events==0,'claim is checked again before nonce publication')
drift.drift_after_read=false;drift.state.action.claim=copy(drift.claim);drift.tick()
check(#drift.events==1 and drift.events[1].act=='spawn.authorize','a rejected pre-send observation does not burn the still-unsent challenge')
drift.tick();check(#drift.events==1,'restored exact authorization still sends only once')
for _,loss in ipairs({'missing','stale'})do
 local f=fixture();f[loss..'_action_read']=f.action_reads+2;f.tick()
 check(#f.events==0,'final '..loss..' authorization origin has not submitted an event')
 f.tick();f.tick()
 check(#f.events==1 and f.events[1].act=='spawn.authorize','restored authorization submits exactly once after '..loss..' origin')
end
local ambiguous_authorize=fixture();ambiguous_authorize.event_error=true;ambiguous_authorize.tick();ambiguous_authorize.event_error=false;ambiguous_authorize.tick()
check(#ambiguous_authorize.events==1 and ambiguous_authorize.events[1].act=='spawn.authorize','throwing authorization submission remains marked')
local background=fixture()
background.primary_state=copy(background.state);background.primary_state.action.action_id='busy-worker-publication';background.primary_state.action.claim.grant_id='busy-worker-grant'
background.primary_request=copy(background.request);background.primary_request.action_id='busy-worker-publication';background.primary_request.request_id='busy-worker-request'
background.tick()
check(#background.events==1 and background.events[1].act=='spawn.authorize','another worker live claim remains usable behind the selected busy-worker publication')
local background_authorization=background.c.strict_decode(background.events[1].value,65536)
check(background.p.equal(background_authorization.orch_claim,background.claim) and background.p.equal(background.c.strict_decode(background_authorization.request_json,8192),background.request),'background authorization preserves its exact request and grant rather than borrowing the selected worker claim')
for _,missing in ipairs({'missing_action','missing_request'})do
 local absent=fixture();absent[missing]=true;absent.tick()
 check(#absent.events==0,'missing action-scoped evidence cannot fall back to a still-valid selected projection: '..missing)
end
local scoped_stale=fixture();scoped_stale.primary_state=copy(scoped_stale.state);scoped_stale.state.action.phase='uncertain';scoped_stale.tick()
check(#scoped_stale.events==0,'a selected claimed projection cannot override uncertain action-scoped evidence')
local function wake_fixture(ack)
 local f=fixture()
 local publication=f.request
 local r={schema=1,origin='orchplus',op='native_wake',request_id='notify',action_id='action-notify',controller_pane=publication.controller_pane,controller_generation=publication.controller_generation,origin_binding=copy(publication.origin_binding),target_request_id=if ack then 'ack-publication' else 'reply-publication',target_action_id=if ack then 'ack-action' else 'reply-action'}
 f.request=r;f.current=copy(r);f.state.action.action_id=r.action_id
 f.projection={schema=1,kind='wake',request=copy(f.request),phase='resolved',orch_claim=copy(f.claim),pane_binding={pane_id='55',window_epoch='epoch',window_key='',native_session_id='3',window_host_id='7'}}
 return issued(f)
end
control_handoffs(wake_fixture,'wake','asks')
for _,loss in ipairs({'missing','stale'})do
 for _,stage in ipairs({'resolved','launching','final-idle-check'})do
  local f=wake_fixture()
  if stage~='resolved' then begin_effect(f)end
  local before=#f.events
  if stage=='final-idle-check' then f.busy_on_list=f.idle_reads+2 else f.agent_state='working'end
  f[loss..'_action_read']=f.action_reads+(if stage=='final-idle-check' then 3 else 2)
  f.tick()
  check(f.asks==0 and #f.events==before,'pre-submit '..loss..' origin cannot submit wake deferral at '..stage)
  f.agent_state='working';f.tick();f.tick()
  check(f.asks==0 and #f.events==before+1 and f.events[before+1].act=='spawn.wakedefer','restored origin submits exactly one wake deferral at '..stage)
  f.agent_state='idle';f.tick()
  check(f.asks==0 and #f.events==before+1,'submitted deferral never later asks under the same grant at '..stage)
 end
 local f=wake_fixture();begin_effect(f);f[loss..'_action_read']=f.action_reads+2;f.tick()
 check(f.asks==0 and #f.events==2,'final '..loss..' origin blocks native ask without an invocation')
 f.tick();f.tick()
 check(f.asks==1 and #f.events==3,'restored pre-effect wake authority asks exactly once')
end
local ambiguous_defer=wake_fixture();ambiguous_defer.agent_state='working';ambiguous_defer.event_error=true;ambiguous_defer.tick()
ambiguous_defer.event_error=false;ambiguous_defer.tick();ambiguous_defer.agent_state='idle';ambiguous_defer.tick()
check(ambiguous_defer.asks==0 and #ambiguous_defer.events==1 and ambiguous_defer.events[1].act=='spawn.wakedefer','throwing submitted wake deferral is not repeated or converted to an ask')
local wake=wake_fixture();wake.tick()
check(#wake.events==1 and wake.events[1].act=='spawn.wakeclaim','separately authorized notification may claim native wake')
local stale=wake_fixture();stale.state.action.claim.grant_id='replacement-grant';stale.tick()
check(#stale.events==0,'same publication under a different grant cannot authorize old wake')
local other=wake_fixture();other.state.action.action_id='unrelated';other.tick()
check(#other.events==0,'unrelated active action cannot authorize delayed wake')
local function begin_wake(f)
 f.tick();adopt_claim(f);f.tick();f.projection.phase='launching'
end
-- Two same-window native sessions: selection is presentation, captured ownership is authority.
local cross_session=wake_fixture();cross_session.selected_session=4;cross_session.focus=66
begin_wake(cross_session);cross_session.tick()
check(cross_session.asks==1 and cross_session.asked_pane==55 and #cross_session.events==3
 and cross_session.focus==66 and not cross_session.focus_calls and cross_session.starts==0,
 'exact owned idle native wake completes in its original session while another session is selected, without focus changes')
local retained_result=cross_session.relay_events[3].value
cross_session.clock=1000;cross_session.tick()
check(cross_session.asks==1 and #cross_session.events==4 and cross_session.relay_events[4].value==retained_result
 and cross_session.focus==66 and not cross_session.focus_calls,
 'background receipt retry retains immutable result bytes and never repeats the native wake or changes focus')
for _,fault in ipairs({'host','session-host','source-session','target-session','owner','generation','controller','claim'}) do
 local wrong=wake_fixture();wrong.selected_session=4;wrong.focus=66
 if fault=='host' then wrong.host.id=8
 elseif fault=='session-host' then wrong.session_host=8
 elseif fault=='source-session' then wrong.foreign_session=true
 elseif fault=='target-session' then wrong.target_foreign_session=true
 elseif fault=='owner' then wrong.state.owner_id='another-owner'
 elseif fault=='generation' then wrong.state.owner_generation=2
 elseif fault=='controller' then wrong.state.command_cursor.controller_pane='66'
 else wrong.state.action.claim.grant_id='another-grant' end
 wrong.tick();wrong.tick()
 check(wrong.asks==0 and wrong.starts==0 and wrong.focus==66 and not wrong.focus_calls,
  'background native wake refuses exact captured '..fault..' fence without selecting its session')
end
local continued=wake_fixture();begin_wake(continued)
local old_claim=copy(continued.state.action.claim);local old_request=copy(continued.current)
continued.state.command_cursor.origin.window_epoch='continued-epoch';continued.state.command_cursor.seq+=1
continued.state.action.execution_origin=copy(continued.state.command_cursor.origin);continued.state.action.reconciliation_only=true
continued.tick()
check(continued.asks==0 and #continued.events==2 and continued.p.equal(continued.state.action.claim,old_claim) and continued.p.equal(continued.current,old_request),'controller continuation rejects old-window effect despite retained claimed phase, immutable request and original grant')
local late=wake_fixture();begin_wake(late);late.continue_during_ask=true;late.tick();late.tick()
check(late.asks==1 and #late.events==2 and late.state.action.phase=='claimed','continuation during native ask rejects late old-window result callback without repeating effect or erasing claim')
for _,fence in ipairs({'reconciliation','execution-origin','controller-alias','cursor-origin','cursor-alias'})do
 local fenced=wake_fixture()
 if fence=='reconciliation' then fenced.state.action.reconciliation_only=true
 elseif fence=='execution-origin' then fenced.state.action.execution_origin.window_epoch='continued-epoch'
 elseif fence=='controller-alias' then fenced.state.action.execution_controller_pane='88'
 elseif fence=='cursor-origin' then fenced.state.command_cursor.origin.window_epoch='continued-epoch'
 else fenced.state.command_cursor.controller_pane='88' end
 fenced.tick()
 check(fenced.asks==0 and #fenced.events==0,'continued authority fence independently rejects stale native authorization: '..fence)
end
local advanced=wake_fixture();advanced.state.command_cursor.seq=999;begin_wake(advanced);advanced.tick()
check(advanced.asks==1,'newer same-origin owner intents do not invalidate an otherwise exact retained execution claim')
for _,ack in ipairs({false,true})do
 local submitted=wake_fixture(ack);begin_wake(submitted);submitted.tick()
 local result=submitted.c.strict_decode(submitted.events[3].value,65536)
 check(submitted.asks==1 and submitted.asked_pane==55 and result.result.status=='submitted','explicit ACK or manifest notification queues exactly one native ask')
 submitted.tick();check(submitted.asks==1 and #submitted.events==3,'replayed launching projection cannot duplicate an ask')
 local uncertain=wake_fixture(ack);uncertain.ask_error=true;begin_wake(uncertain);uncertain.tick();uncertain.tick()
 local lost=uncertain.c.strict_decode(uncertain.events[3].value,65536)
 check(uncertain.asks==1 and lost.result.status=='uncertain','throw after possible native ask is uncertain and never retried')
 local replaced=wake_fixture(ack);begin_wake(replaced);replaced.state.action.claim.grant_id='new-grant';replaced.tick()
 check(replaced.asks==0 and #replaced.events==2,'replacement publication grant cannot execute the original wake')
 local reassociated=wake_fixture(ack);begin_wake(reassociated);reassociated.projection.pane_binding.native_session_id='other';reassociated.tick()
 check(reassociated.asks==0 and #reassociated.events==2,'wrong native session binding blocks ask after durable begin')
 for _,state in ipairs({'working','waiting-input','exited','unknown'})do
  local busy=wake_fixture(ack);busy.agent_state=state;busy.tick()
  check(#busy.events==1 and busy.events[1].act=='spawn.wakedefer' and busy.asks==0,'non-idle native state returns conclusive pre-effect deferral: '..state)
 end
 for _,hold in ipairs({'delivery_error','unknown','unrecognized'})do
  local blocked=wake_fixture(ack);blocked[hold]=if hold=='delivery_error' then 'permission required' else true;blocked.tick()
  check(#blocked.events==1 and blocked.events[1].act=='spawn.wakedefer' and blocked.asks==0,'unavailable native recognition or permission defers without ask: '..hold)
 end
 local became_busy=wake_fixture(ack);begin_wake(became_busy);became_busy.agent_state='working';became_busy.tick()
 check(became_busy.asks==0 and #became_busy.events==3 and became_busy.events[3].act=='spawn.wakedefer','idle state is rechecked immediately before ask and never-started execution is released')
 became_busy.agent_state='idle';became_busy.tick()
 check(became_busy.asks==0,'deferred old grant cannot silently resume when idle')
 became_busy.claim.grant_id='retry-grant';became_busy.state.action.claim=copy(became_busy.claim)
 became_busy.projection.orch_claim=copy(became_busy.claim);became_busy.projection.phase='resolved';became_busy.projection.claim=nil
 became_busy.tick()
 local renewed=became_busy.c.strict_decode(became_busy.events[4].value,65536)
 became_busy.projection.claim={spawn_namespace='spawn-native',claim_nonce='native-nonce-bbbbbbbb',executor_id=renewed.executor_id,boot='fixture-boot'};became_busy.state.action.claim.spawn_claim={spawn_namespace='spawn-native',claim_nonce='native-nonce-bbbbbbbb'};became_busy.projection.phase='claimed';became_busy.tick();became_busy.projection.phase='launching';became_busy.tick()
 check(became_busy.asks==1,'new exact grant resumes only the proven never-started notification')
end
local chunk=wake_fixture();chunk.request.part='chunk';chunk.request.index=1;chunk.current=copy(chunk.request);chunk.projection.request=copy(chunk.request);chunk.tick()
check(#chunk.events==0 and chunk.asks==0,'reply chunks cannot authorize a publication wake')
local previous_window=wake_fixture(true);begin_wake(previous_window)
local reloaded_window=wake_fixture(true);reloaded_window.projection=copy(previous_window.projection);reloaded_window.projection.request.consumed=runtime.json.array();reloaded_window.tick()
check(reloaded_window.asks==0 and #reloaded_window.events==0,'new window executor cannot resume an older claimed ACK wake')
local retry=fixture();retry.projection.previous_claim=copy(retry.claim);retry.tick()
check(#retry.events==0,'capacity retry waits for a new live ORCH+ grant')
retry.state.action.claim.grant_id='new-retry-grant';retry.tick()
check(#retry.events==1 and retry.events[1].act=='spawn.authorize','new exact retry grant may answer the fresh challenge')
end
if section==nil or section=='retirement' then
 local function stop_fixture()
  local f=fixture()
  local r={schema=1,origin='orchplus',op='stop',request_id='stop',action_id='action-stop',controller_pane='44',controller_generation=1,origin_binding=copy(f.request.origin_binding),target_request_id='launch',target_action_id='launch-action',worker_id='worker',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',pane_binding={pane_id='55',window_epoch='epoch',window_key='',native_session_id='3',window_host_id='7'}}
  f.request=r;f.current=copy(r);f.state.action.action_id=r.action_id
  f.projection={schema=1,kind='stop',request=copy(r),phase='resolved',orch_claim=copy(f.claim),backend='native-agent'}
  return issued(f)
 end
 local function begin_stop(f)
  f.tick();adopt_claim(f);f.tick();f.projection.phase='launching'
 end
 for _,state in ipairs({'working','waiting_input','unknown','unobserved','delivery_error'})do
  local held=stop_fixture();held.stop_result='exited';begin_stop(held)
  local original=copy(held.projection.claim);local nonce=held.projection.nonce
  local markers=held.w.retained().markers
  if state=='unobserved' then held.unknown=true
  elseif state=='delivery_error' then held.delivery_error='pending delivery'
  else held.agent_state=state end
  held.tick();held.tick()
  check(held.stops==nil and held.closes==nil and #held.events==2 and held.w.retained().markers==markers
   and held.p.equal(held.projection.claim,original) and held.projection.nonce==nonce,
   'native stop retains its exact grant without an effect/result marker while '..state)
  held.unknown=false;held.delivery_error=nil;held.agent_state='idle';held.tick();held.tick()
  check(held.stops==1 and held.closes==nil and #held.events==3
   and held.p.equal(held.projection.claim,original) and held.projection.nonce==nonce
   and held.c.strict_decode(held.events[3].value,65536).result.status=='stopped',
   'fresh idle resumes the same '..state..' stop grant once without retry or replacement')
 end
 local late_busy=stop_fixture();late_busy.stop_result='exited';begin_stop(late_busy)
 local before_markers=late_busy.w.retained().markers
 late_busy.busy_on_list=late_busy.idle_reads+3;late_busy.tick()
 check(late_busy.stops==nil and late_busy.closes==nil and #late_busy.events==2 and late_busy.w.retained().markers==before_markers,
  'a native agent becoming busy at the final idle observation is never stopped or marked as an effect')
 late_busy.tick();late_busy.tick()
 check(late_busy.stops==1 and #late_busy.events==3,'the untouched stop grant remains usable after fresh idle returns')
 for _,observation in ipairs({'absent','exited'})do
  local already_dead=stop_fixture();begin_stop(already_dead)
  local original=copy(already_dead.projection.claim)
  local markers=already_dead.w.retained().markers
  if observation=='absent' then already_dead.absent=true;already_dead.host.panes={44,66}
  else already_dead.agent_state='exited';already_dead.exit_status=0 end
  already_dead.tick()
  local result=already_dead.c.strict_decode(already_dead.events[3].value,65536).result
  check(already_dead.stops==nil and already_dead.closes==nil and already_dead.w.retained().stopping==0
   and already_dead.w.retained().markers==markers+1 and result.status=='stopped' and result.observation==observation
   and already_dead.p.equal(result.pane_binding,already_dead.request.pane_binding)
   and already_dead.p.equal(already_dead.projection.claim,original),
   'positive exact native '..observation..' settles the original stop claim with only an observation marker, never a stop effect')
  local bytes=already_dead.relay_events[3].value
  already_dead.absent=false;already_dead.host.panes={44,55,66};already_dead.agent_state='idle';already_dead.exit_status=nil
  already_dead.clock=1000;already_dead.tick()
  check(already_dead.stops==nil and already_dead.closes==nil and #already_dead.events==4
   and already_dead.relay_events[4].value==bytes and already_dead.w.retained().markers==markers+1,
   'retained '..observation..' observation retries exact bytes and never closes a pane that later reappears')
 end
 control_handoffs(function()local f=stop_fixture();f.stop_result='exited';return f end,'','stops')
 for _,loss in ipairs({'missing','stale'})do
  local f=stop_fixture();f.stop_result='exited';begin_effect(f)
  f[loss..'_action_read']=f.action_reads+2;f.tick()
  check(f.stops==nil and f.closes==nil and #f.events==2,'stop final '..loss..' origin refuses all native effects')
  f.tick();f.tick()
  check(f.stops==1 and f.closes==nil and #f.events==3 and f.c.strict_decode(f.events[3].value,65536).result.status=='stopped','restored pre-effect stop origin invokes stop exactly once')
  for _,rejection in ipairs({'absent','unrecognized'})do
   local rejected=stop_fixture();begin_effect(rejected);rejected[rejection]=true
   rejected[loss..'_action_read']=rejected.action_reads+2;rejected.tick()
   check(rejected.stops==nil and rejected.closes==nil and #rejected.events==2,'pre-submit '..loss..' origin does not consume stop '..rejection..' rejection')
   rejected.tick();rejected.tick()
   check(rejected.stops==nil and rejected.closes==nil and #rejected.events==3 and rejected.c.strict_decode(rejected.events[3].value,65536).result.status=='uncertain','restored origin submits stop '..rejection..' rejection exactly once without native effects')
   rejected[rejection]=false;rejected.tick()
   check(rejected.stops==nil and rejected.closes==nil and #rejected.events==3,'submitted stop '..rejection..' rejection forbids later execution under that projection')
  end
 end
 local ambiguous_rejection=stop_fixture();begin_effect(ambiguous_rejection);ambiguous_rejection.unrecognized=true;ambiguous_rejection.event_error=true;ambiguous_rejection.tick()
 ambiguous_rejection.event_error=false;ambiguous_rejection.unrecognized=false;ambiguous_rejection.tick();ambiguous_rejection.tick()
 check(ambiguous_rejection.stops==nil and ambiguous_rejection.closes==nil and #ambiguous_rejection.events==3,'throwing submitted stop rejection remains terminal and never invokes native stop')
 for _,observation in ipairs({'absent','exited'})do
  local f=stop_fixture();f.stop_result=observation;begin_stop(f);f.tick()
  local result=f.c.strict_decode(f.events[3].value,65536).result
  check(f.stops==1 and result.status=='stopped' and result.observation==observation and f.p.equal(result.pane_binding,f.request.pane_binding),'authorized native stop observes exact fresh '..observation)
  f.tick();check(f.stops==1 and #f.events==3,'duplicate native stop projection never repeats effects')
 end
 local terminal=stop_fixture();terminal.unrecognized=true;terminal.pane_kind='agent';terminal.projection.backend='ssh-command';terminal.stop_result='absent';begin_stop(terminal);terminal.tick()
 check(terminal.closes==1 and terminal.stops==nil and terminal.c.strict_decode(terminal.events[3].value,65536).result.status=='stopped','enrolled terminal uses documented pane close and fresh absence')
 local unsupported=stop_fixture();unsupported.unrecognized=true;begin_stop(unsupported);unsupported.tick()
 check(unsupported.stops==nil and unsupported.closes==nil and unsupported.c.strict_decode(unsupported.events[3].value,65536).result.status=='uncertain','unrecognized native agent never falls back to pane close')
 local missing=stop_fixture();missing.absent=true;begin_stop(missing);missing.tick()
 check(missing.stops==nil and missing.c.strict_decode(missing.events[3].value,65536).result.status=='uncertain','absence before authorized effect is not closure proof')
 local busy=stop_fixture();begin_stop(busy)
 for _=1,22 do busy.tick()end
 check(busy.stops==1 and busy.c.strict_decode(busy.events[3].value,65536).result.status=='uncertain','pcall success without exit observation becomes bounded uncertainty')
 local lost=stop_fixture();lost.stop_error=true;begin_stop(lost);lost.tick();lost.tick()
 check(lost.stops==1 and lost.c.strict_decode(lost.events[3].value,65536).result.status=='uncertain','lost native outcome never repeats stop')
 local stale=stop_fixture();begin_stop(stale);stale.state.action.claim.grant_id='different-grant';stale.tick()
 check(stale.stops==nil and #stale.events==2,'stale origin cannot stop after durable begin')
 local drift=stop_fixture();drift.stop_drift=true;begin_stop(drift);drift.tick();drift.tick()
 check(drift.stops==1 and #drift.events==2,'origin change during stop never publishes false completion')
 local rebound=stop_fixture();rebound.projection.request.pane_binding.window_epoch='old-window';rebound.current=copy(rebound.projection.request);rebound.tick()
 check(#rebound.events==0,'old issued window epoch cannot acquire stop claim')
 local observing=stop_fixture();begin_stop(observing);observing.tick()
 check(observing.stops==1 and observing.w.retained().stopping==1,'an invoked stop awaiting its exit observation is retained')
 observing.state.action.phase='uncertain';observing.tick()
 check(observing.w.retained().stopping==1 and observing.stops==1,'an uncertain ORCH+ stop keeps its observation and effect marker')
 observing.state.action.phase='complete';observing.tick()
 control_projection(observing,'reconcile_session',{1});observing.tick()
 local stopped=observing.w.retained()
 check(stopped.stopping==0 and stopped.markers==0 and observing.stops==1,'a settled ORCH+ stop releases its observation and markers without another stop')
 -- Explicit verified attach: one native ask to the exact attested idle agent pane, never a start.
 local function adopt_fixture()
  local f=fixture()
  local prompt='Complete the attached work'
  local r={schema=1,origin='orchplus',op='adopt',request_id='adopt',action_id='action-adopt',controller_pane='44',controller_generation=1,origin_binding=copy(f.request.origin_binding),record_id='worker',record_revision=0,work_id='work',prompt=prompt,mailbox_handle='mailbox',enrolment={worker_id='worker',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',assignment_sha256=f.c.sha256(prompt)},pane_binding={pane_id='55',window_epoch='epoch',window_key='',native_session_id='3',window_host_id='7'},attestation='operator_verified_exact_agent_pane'}
  f.request=r;f.current=copy(r);f.state.action.action_id=r.action_id
  f.projection={schema=1,kind='adopt',request=copy(r),phase='resolved',orch_claim=copy(f.claim),prompt='report-files-v1 preface\nASSIGNMENT_BYTES_BEGIN\n'..prompt}
  return issued(f)
 end
 control_handoffs(adopt_fixture,'','asks')
 local adopted=adopt_fixture();begin_effect(adopted);adopted.tick()
 local delivered=adopted.c.strict_decode(adopted.events[3].value,65536).result
 check(adopted.asks==1 and adopted.starts==0 and adopted.asked_pane==55 and delivered.status=='submitted' and adopted.p.equal(delivered.pane_binding,adopted.request.pane_binding),'adopt delivers the preface once by native ask to the exact pane and starts nothing')
 adopted.tick();adopted.tick()
 check(adopted.asks==1 and #adopted.events==3,'a delivered adoption projection never repeats the native ask')
 for _,case in ipairs({{'agent_state','working'},{'unrecognized',true},{'delivery_error','held'}})do
  local refused=adopt_fixture();begin_effect(refused);refused[case[1]]=case[2];refused.tick()
  local outcome=refused.c.strict_decode(refused.events[3].value,65536).result
  check(refused.asks==0 and refused.starts==0 and outcome.status=='refused','adopt refuses a '..tostring(case[1])..' pane before any native ask')
  refused[case[1]]=nil;refused.agent_state='idle';refused.tick();refused.tick()
  check(refused.asks==0 and #refused.events==3,'a submitted adoption refusal is terminal under that projection')
 end
 local scoped=adopt_fixture();scoped.projection.request.pane_binding.window_epoch='old-window';scoped.current=copy(scoped.projection.request);scoped.request=copy(scoped.projection.request)
 issued(scoped);begin_effect(scoped);scoped.tick()
 check(scoped.asks==0,'an out-of-window adoption target never receives a native ask')
 local ambiguous=adopt_fixture();ambiguous.ask_error=true;begin_effect(ambiguous);ambiguous.tick();ambiguous.tick()
 check(ambiguous.asks==1 and ambiguous.c.strict_decode(ambiguous.events[3].value,65536).result.status=='uncertain' and #ambiguous.events==3,'an ambiguous native ask is reported uncertain and never repeated')
 local function enrol_fixture(delivery)
  local f=adopt_fixture()
  local r=f.request;r.op='enrol';r.attestation=nil;r.delivery=delivery;r.preserve_context=true
  r.prompt=f.c.OPEN_CONVERSATION_ASSIGNMENT;r.enrolment.assignment_sha256=f.c.sha256(r.prompt)
  f.current=copy(r);f.projection.request=copy(r);f.projection.kind='enrol'
  f.projection.prompt='private enrollment instructions\nASSIGNMENT_BYTES_BEGIN\n'..r.prompt
  if delivery=='clipboard' then f.pane_kind='terminal';f.unrecognized=true end
  return issued(f)
 end
 local enrolled=enrol_fixture('native_ask');enrolled.agent_state='working';begin_effect(enrolled);enrolled.tick();enrolled.tick()
 check(enrolled.asks==0 and enrolled.starts==0 and #enrolled.events==2,'busy native enrollment waits without submitting, refusing, or replaying old task text')
 enrolled.agent_state='idle';enrolled.tick();enrolled.tick()
 check(enrolled.asks==1 and enrolled.asked_prompt==enrolled.projection.prompt and #enrolled.events==3,'idle transition delivers exact enrollment instructions once without a fresh start')
 local copied=enrol_fixture('clipboard');copied.pane_kind='agent';begin_effect(copied);copied.tick();copied.tick()
 local outcome=copied.c.strict_decode(copied.events[3].value,65536).result
 check(copied.copies==1 and copied.copied_text==copied.projection.prompt and copied.asks==0 and copied.starts==0,'terminal enrollment only copies the one-time capability and never invokes native ask, start or PTY')
 check(outcome.status=='copied' and copied.p.equal(outcome.pane_binding,copied.request.pane_binding),'clipboard reports copied bound delivery, never submitted or accepted')
 copied.clock=1000;copied.tick();copied.tick()
 check(copied.copies==1 and #copied.events==4 and copied.relay_events[4].value==copied.relay_events[3].value,'clipboard callback may retry but never recopies the enrollment token')
 local unknown=enrol_fixture('clipboard');unknown.copy_error=true;begin_effect(unknown);unknown.tick();unknown.tick()
 check(unknown.copies==1 and unknown.c.strict_decode(unknown.events[3].value,65536).result.status=='uncertain','throw after clipboard effect retains uncertainty and never copies the token again')
 local foreign=enrol_fixture('clipboard');foreign.request.pane_binding.window_epoch='foreign'
 foreign.current=copy(foreign.request);foreign.projection.request=copy(foreign.request);issued(foreign);begin_effect(foreign);foreign.tick()
 check(not foreign.copies and foreign.asks==0,'exact same-window binding is required even for clipboard delivery')
end
if section==nil or section=='window' then
 -- SPAWN window half (window.luau) with the real config/launch modules against a modelled host
 -- Config block and layout. A world outlives a window fixture, so a second fixture is a reload.
 local function spawn_record(id)
  return {id=id,provider='custom',account_label=id,backend='local-terminal',command='ordinary-cli',arguments={},enabled=true,placement='tab'}
 end
 local function new_world(records)
  return {kv={},files={},blocks={},next_pane=100,host={id=1,state='connected',name='fixture',kind='local',sessions={1},panes={}},
   authority={authority_id='authority-1',session_key='session-1',config_revision=1,records=records or {spawn_record('alpha')},replies={},request_sequences={}},
   requests={},contexts={},acks={},closes=0,opened=0,agents={},starts=0}
 end
 local function add_block(world,opts)
  world.next_pane+=1
  local id=world.next_pane
  world.blocks[id]={parked=opts~=nil and opts.parked==true,intents=opts and opts.intents or {},queue_id='fixture-queue-'..id,page_context=opts and opts.page_context}
  table.insert(world.host.panes,id)
  return id
 end
 local function intent(id,kind,revision,record_id)return {intent_id=id,kind=kind,config_revision=revision or 1,record_id=record_id}end
 -- Pure modules load once; only window.luau runs again (one compile) for each fixture.
 local pure={}
 local function load_pure(name)
  name=name:gsub('^%./','');if pure[name]then return pure[name]end
  local fn=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
  setfenv(fn,setmetatable({require=load_pure},{__index=environment}));pure[name]=fn() or true;return pure[name]
 end
 local read_node=load_pure('dispatch_window').read_node
 local window_chunk=assert(loadstring(runtime.fs.read(root..'/window.luau'),'window'))
 local function window(world,window_key)
  window_key=window_key or 'win'
  local f={timers={},commands={},toasts={},picks={},handlers={}}
  local cx=nil
  local fake=setmetatable({
   context='window',
   fs={exists=function(path)return world.files[path]~=nil end,mkdir=function()end,
    read=function(path)return assert(world.files[path],'missing fixture file '..path)end,
    remove=function(path)world.files[path]=nil end,
    write=function(path,bytes)world.files[path]=bytes end},
   chrome={program_icon=function()end,status=function()end},
   files={button=function()end},
   route={link=function(fn)f.link=fn end},
   timer=function(ms,fn)table.insert(f.timers,{ms=ms,fn=fn});return {} end,
   on=function(event,fn)f.handlers[event]=fn end,
   command=function(spec)f.commands[spec.id]=spec.run end,
   css=function()end,
   kv={get=function(key)return copy(world.kv[key])end,set=function(key,value)world.kv[key]=copy(value)end},
   json=runtime.json,
  },{__index=runtime})
  local stubs={
   native_cli={inspect=function(_,_,callback)
    f.inspections=(f.inspections or 0)+1
    callback({status=0,timed_out=false,stdout=runtime.json.encode({clients={{kind='window',window=window_key,conn=world.conn or 1,since=world.since or 1}}})},nil,cx)
   end},
   dispatch_window=if world.migration then nil else {start=function()end,observe_migration=function()end,consent_migration=function()end,read_node=read_node},
   ['updater/window']={register=function()end},
  }
  local function load(name)
   name=name:gsub('^%./','')
   if (name=='managed_route_window' or name=='window_journal' or (name=='dispatch_window' and world.migration)) and not stubs[name] then
    local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
    setfenv(chunk,setmetatable({tern=fake,require=load},{__index=environment}))
    stubs[name]=chunk()
    if name=='managed_route_window' then
     -- Observe the real module: how many approvals were captured and how many were cancelled.
     local real_capture,real_cancel=stubs[name].capture_reviewed,stubs[name].cancel_reviewed
     stubs[name].capture_reviewed=function(...)local captured,why=real_capture(...);if captured then world.captures=(world.captures or 0)+1 end;return captured,why end
     stubs[name].cancel_reviewed=function(captured,...)if captured then world.cancels=(world.cancels or 0)+1 end;return real_cancel(captured,...) end
    end
   end
   return stubs[name] or load_pure(name)
  end
  local journal_module=load('window_journal')
  fake.context='host'
  assert(journal_module.host_initialize(function()return world.desktop_namespace or 'ns' end))
  fake.context='window'
  local function info(id)
   if world.agents[id] then return {pane=id,kind='agent',tab=1,cwd=world.agents[id].cwd} end
   local b=world.blocks[id];if not b then return nil end
   return {pane=id,block=b.block or 'spawn.spawner',kind='plugin',title='SPAWN',cwd=world.cwd or '/fixture',tab=if b.parked then nil else 1,parked=b.parked,focused=world.focus==id}
  end
  local function node(key,role,text)return {surface={role='plugin.spawn.spawner'},main={id='main.'..key,k='text',p={role=role,spans={{t=text}}}}}end
  cx={
   hosts={current=function()return world.host end,list=function()return {world.host}end},
   sessions={current=function()return {id=world.sdk_session or 1,host=world.host.id}end,list=function()return {{id=world.sdk_session or 1,host=world.host.id}}end},
   settings={get=function(_,key)assert(key=='agent_command');if world.settings_error then error('settings unavailable')end;return world.default_command end},
   agents={
    list=function()local out={};for _,agent in pairs(world.agents)do table.insert(out,copy(agent))end;if world.duplicate_agent and out[1]then table.insert(out,copy(out[1]))end;return out end,
    start=function(_,opts)
     world.starts+=1;world.started=copy(opts)
     local persisted=false
     for path,bytes in pairs(world.files)do
      if path:sub(-14)=='/observer.json' then local journal=runtime.json.decode(bytes);if journal.setup and journal.setup.effect_intent then persisted=true end end
     end
     assert(persisted and world.job.stage=='submission_intent','native effect requires both journals before start')
     if world.start_error then error('ambiguous native start')end
     local id=900+world.starts;world.agents[id]={pane=id,command=opts.command,cwd=opts.cwd,state='idle'}
     table.insert(world.host.panes,id);return id
    end,
    ask=function(_,pane,message)
     assert(world.imports and #world.authority.records>0,'a helper save receipt requires durable imported records')
     world.receipts=world.receipts or {};table.insert(world.receipts,{pane=pane,message=message})
    end,
    transcript=function()error('setup must never read a transcript')end,
    wait=function()error('setup must never extract a last message')end,
   },
   window_key=function()return window_key end,
   toast=function(_,level,text,sub)table.insert(f.toasts,{level=level,text=text,sub=sub})end,
   pick=function(_,spec)local p={spec=spec};table.insert(f.picks,p);return {next=function(_,fn)p.fn=fn end}end,
   new_block=function(_,block,args,how,opts)
    assert(block=='spawn.spawner','only SPAWN Config is opened');world.opened+=1
    world.last_open={args=copy(args),how=how,opts=copy(opts)}
    local id=add_block(world);if opts and opts.focus then world.focus=id end;return id
   end,
  }
  cx.layout={
   close=function(_,id)
    assert(world.blocks[id],'close of an unknown pane');world.blocks[id]=nil;world.closes+=1
    for i,p in ipairs(world.host.panes)do if p==id then table.remove(world.host.panes,i);break end end
    if world.focus==id then world.focus=nil end
   end,
   focus=function(_,id)world.focus=id end,
   move=function(_,id,target,dir)world.arranged={id=id,target=target,dir=dir};return true end,
   park=function()error('SPAWN closes Config; it never parks it')end,
   unpark=function()error('SPAWN never adopts a parked Config')end,
  }
  cx.session={
   pane=function(_,id)return info(id)end,
   panes=function()local out={};for id in pairs(world.blocks)do table.insert(out,info(id))end;table.sort(out,function(a,b)return a.pane<b.pane end);return out end,
   tabs=function()return {{id=1,session=world.sdk_session or 1}}end,
   tab_of=function(_,id)local i=info(id);return i and i.tab end,
   focused=function()return world.focus end,
   view=function(_,id)local b=world.blocks[id];return if b and not b.parked then node('main','root','') else nil end,
   surface=function(_,id,opts)
    local b=world.blocks[id];if not b then return nil end
    if world.migration then
     if b.block=='orchplus.orchestrator' then
      local peer=world.migration.peer
      local key,role,value
      if opts.root=='main.migration-state' then key='migration-state';role='orchplus.migration';value=peer
      elseif opts.root=='main.setup-index' then key='setup-index';role='orchplus.setup';value={version=1,host_pane_id=peer.host_pane_id,source_nonce=peer.source_nonce}
      else return nil end
      local tree=node(key,role,runtime.json.encode(value));tree.surface.role='plugin.orchplus.orchestrator';return tree
     end
     if opts.root=='main.spawn-managed-migration' then return node('spawn-managed-migration','spawn.managed.migration',runtime.json.encode(world.migration.challenge))end
    end
    local a=world.authority
    if opts.root=='main.spawn-state' then
     -- Numbered state reads (counted from a test's reset) place a change between two exact steps.
     world.state_reads=(world.state_reads or 0)+1
     local state_hook=if world.state_hooks then world.state_hooks[world.state_reads] else nil
     if state_hook then world.state_hooks[world.state_reads]=nil;state_hook() end
     local state={version=2,ready=true,host_key='host:fixture',authority_id=a.authority_id,session_key=a.session_key,config_revision=a.config_revision,attempt_revision=0,records=a.records,attempts={},jobs={},replies=a.replies,request_sequences=a.request_sequences,host_cwd=if world.host_cwd==false then nil else world.host_cwd or '/fixture'}
     state.setup={schema=1,state=world.setup_state or 'not_started',config_revision=a.config_revision,readiness={state='not_run',config_revision=a.config_revision,summary=''}}
     for key,extra in pairs(a.extra or {})do state[key]=extra end
     return node('spawn-state',nil,'SPAWN_STATE_V2 '..runtime.json.encode(state))
    end
    if opts.root=='main.spawn-managed-prepare' and world.preparation then return node('spawn-managed-prepare','spawn.managed.prepare',runtime.json.encode(world.preparation))end
    if opts.root=='main.spawn-launch-intent' then return node('spawn-launch-intent','spawn.launch.intent',runtime.json.encode({schema=1,queue_id=b.queue_id,intents=b.intents}))end
    if opts.root=='main.spawn-page-context' and b.page_context then return node('spawn-page-context','spawn.page.context',runtime.json.encode(b.page_context))end
    if opts.root=='main.spawn-native-accounts' and b.native_accounts then return node('spawn-native-accounts','spawn.native.accounts',runtime.json.encode(b.native_accounts))end
    if opts.root=='main.spawn-setup-topology' and b.topology then return node('spawn-setup-topology','spawn.setup.topology',runtime.json.encode(b.topology))end
    if opts.root=='main.spawn-managed-route' and world.route then return node('spawn-managed-route','spawn.managed.route',runtime.json.encode(world.route))end
    if opts.root=='main.spawn-setup-result' and b.selected==world.job.id and world.pending then
     world.result_read_limit=opts.max_chars
     -- Numbered reads let a test change the source at an exact stage of the automatic save:
     -- 1 = result collection, 2 = the commit's own source check (before capture),
     -- 3 = the dispatch preflight (after capture, while the import waits to be sent).
     world.result_reads=(world.result_reads or 0)+1
     local hook=if world.result_hooks then world.result_hooks[world.result_reads] else nil
     if hook then world.result_hooks[world.result_reads]=nil;hook() end
     local result=node('spawn-setup-result','spawn.setup.result',world.pending)
     if world.clipped_result then result.more=1 end
     return result
    end
    return nil
   end,
   event=function(_,id,ev)
    local b=assert(world.blocks[id],'event sent to a closed Config')
    if ev.act=='spawn.launch-intent-claim' then
     local recipient=runtime.json.decode(ev.value)
     for _,queued in ipairs(b.intents)do
      if queued.intent_id==recipient.intent_id and queued.recipient==nil then
       queued.recipient={observer_id=recipient.observer_id,window_key=recipient.window_key,conn=recipient.conn,since=recipient.since}
      end
     end
    elseif ev.act=='spawn.launch-intent-ack' then
     local recipient=runtime.json.decode(ev.value)
     for i,queued in ipairs(b.intents)do
      if queued.intent_id==recipient.intent_id and journal_module.same_recipient(queued.recipient,recipient) then
       table.insert(world.acks,recipient.intent_id)
       if not world.keep_intent then table.remove(b.intents,i)end
       break
      end
     end
    elseif ev.act=='spawn.page-context' then
     table.insert(world.contexts,{pane=id,value=runtime.json.decode(ev.value)});b.page_context=nil
    elseif ev.act=='spawn.native-accounts' then
     world.native_accounts=world.native_accounts or {};table.insert(world.native_accounts,{pane=id,value=runtime.json.decode(ev.value)});b.native_accounts=nil
    elseif ev.act=='spawn.setup-devices' then
     local observed=runtime.json.decode(ev.value);world.devices=observed
     b.topology.request=nil;b.topology.observation={devices=observed.devices,current=observed.current.id};b.topology.selected=observed.current.id
    elseif ev.act=='managed-reviewed-prepare' then
     local value=runtime.json.decode(ev.value)
     local accepted
     for _,r in ipairs(world.requests)do if r.request_id==value.reviewed.import_request_id then accepted=r end end
     assert(accepted and accepted.op=='import_records' and accepted.data.preparation and world.job.setup_consumed,'combined preparation requires the actual accepted import receipt')
     local exact=accepted.data.preparation
     assert(load_pure('bridge_protocol').equal(exact.entries,value.entries) and load_pure('bridge_protocol').equal(exact.consents,value.consents) and exact.nonce==value.nonce,'combined scope is the original clicked approval, not a new account selection')
     world.preparation_calls=(world.preparation_calls or 0)+1;world.preparation_input=value
     world.preparation={schema=1,nonce=value.nonce,revision=value.config_revision,entries=value.entries,status='preparing',window=value.window}
    elseif ev.act=='spawn.setup-result-select' then
     local selected=runtime.json.decode(ev.value).attempt_id
     world.selections=(world.selections or 0)+1
     if world.defer_selection then b.awaiting_selection=selected else b.selected=selected end
    elseif ev.act=='managed-route-consent' then
     local value=runtime.json.decode(ev.value);local route=copy(assert(world.route_request))
     assert(value.nonce==route.nonce and value.config_revision==route.config_revision,'diagnostic consent matches the actual clicked request')
     world.route_consents=(world.route_consents or 0)+1;world.last_route_consent=value
     route.window=value.window;route.native_namespace=value.native_namespace
     route.native_conn=value.native_conn;route.native_since=value.native_since;route.window_consent=value.window_consent
     world.route=route
    elseif ev.act=='managed-route-preflight' then
     world.preflights=(world.preflights or 0)+1
    elseif ev.act=='managed-migration-consent' then
     local value=runtime.json.decode(ev.value)
     table.insert(world.migration.consents,{pane=id,value=value})
     local challenge=world.migration.challenge
     challenge.native_window=value.window;challenge.native_namespace=value.native_namespace
     challenge.native_conn=value.native_conn;challenge.native_since=value.native_since
     challenge.window_consent=if world.stale_migration_token then 'stale-window-consent' else value.window_consent
    elseif ev.act=='spawn.migration-result' then
     table.insert(world.migration.results,{pane=id,value=runtime.json.decode(ev.value)})
    elseif ev.act=='spawn.request' then
     -- Model authority transport only; setup cases exercise the real window and strict projections.
     local r=runtime.json.decode(ev.value);table.insert(world.requests,r)
     local a=world.authority
     for _,acked in ipairs(r.acknowledged_requests)do a.replies[acked]=nil end
     if world.setup_enabled and r.op~='launch_record' then
      local result={}
      if r.op=='start_setup' then
       assert(r.data.record_id==nil,'setup admission cannot require a saved record')
       local d=r.data
       local state={version=1,revision=0,next_attempt=1,attempts={}}
       world.attempt=assert(load_pure('launch_state').reserve(state,{id='setup-default',backend='setup-default'},a.session_key,'fixture-namespace/executor','setup'))
       world.job={id='attempt-1',attempt_id='attempt-1',record_id='setup-default',purpose='setup',config_revision=a.config_revision,observer_id=r.observer_id,
        session_key=a.session_key,native_session=1,token='fixture-token',stage='admitted',provider='Tern default',account_label='Guided setup',
        backend='setup-default',placement='tab',cwd=d.cwd,pane_reused=false,setup_run_id=d.setup_run_id,initial_prompt='Exact provider-neutral prompt Ω\\nsubmit explicitly',
        setup={command=d.command,cwd=d.cwd,window=d.window,config_pane=d.config_pane,host_config_pane=321,result_path='/fixture/result.json',
         binding='fixture-binding',host_key='host:fixture',authority_id=a.authority_id,request_sequence=r.request_sequence,native_session=1}}
       result={attempt=copy(world.attempt),job=copy(world.job)}
      elseif r.op=='setup_claim' then
       assert(world.job.stage=='admitted');world.job.stage='claimed';result={job=copy(world.job)}
       world.attempt.sequence+=1
      elseif r.op=='setup_begin' then
       assert(world.job.stage=='claimed');world.job.stage='submission_intent';result={job=copy(world.job)}
       world.attempt.sequence+=1
      elseif r.op=='setup_bind' then
       assert(world.job.stage=='submission_intent' and world.starts==1);world.job.stage='submitted'
       world.job.setup.agent_pane=r.data.pane;world.job.native_pane=7001;world.job.native_window=window_key
       world.attempt.phase='Running';world.attempt.pane=7001;world.attempt.sequence+=1
       result={job=copy(world.job)}
      elseif r.op=='setup_uncertain' then world.job.stage='unknown';result={job=copy(world.job)}
      elseif r.op=='import_records' then
       assert(r.data.confirmed==true and r.data.attempt_id==world.job.id and r.data.setup_run_id==world.job.setup_run_id and r.data.pending_digest==world.job.pending_digest)
       assert(r.data.records==nil and not world.job.setup_consumed,'import only consumes immutable authority bytes once')
       local decoded=assert(load_pure('config').decode_setup_json(world.pending))
       local review=assert(load_pure('setup_review').prepare(decoded,r.data.setup_run_id))
       a.records=review.records;a.config_revision+=1;world.job.setup_consumed=true;world.imports=(world.imports or 0)+1;result={imported=#review.records}
       if world.after_import then local hook=world.after_import;world.after_import=nil;hook() end
      elseif r.op=='discard_setup_result' then
       assert(r.data.confirmed==true and r.data.attempt_id==world.job.id and r.data.setup_run_id==world.job.setup_run_id and r.data.pending_digest==world.job.pending_digest and not world.job.setup_consumed)
       world.job.setup_consumed=true;world.job.setup_discarded=true;world.discards=(world.discards or 0)+1;result={discarded=true}
      elseif r.op~='refresh' then error('unexpected setup operation '..r.op)end
      a.extra={attempts={world.attempt},jobs={world.job}}
      a.replies[r.request_id]={request_id=r.request_id,observer_id=r.observer_id,request_sequence=r.request_sequence,ok=true,result=result,config_revision=a.config_revision,attempt_revision=0}
      a.request_sequences[r.observer_id]=r.request_sequence
      if world.after_request then world.after_request(r,world)end
      return
     end
     if not world.hold then
      a.replies[r.request_id]={request_id=r.request_id,observer_id=r.observer_id,request_sequence=r.request_sequence,ok=false,error='disabled',config_revision=a.config_revision,attempt_revision=0}
      a.request_sequences[r.observer_id]=r.request_sequence
     end
    end
   end,
  }
  setfenv(window_chunk,setmetatable({tern=fake,require=load},{__index=environment}));window_chunk()
  f.cx=cx
  f.round=function(n)for _=1,n or 1 do local due=f.timers;f.timers={};for _,t in ipairs(due)do t.fn(cx)end end end
  -- Only the window's existing 1 s tick (reconcile + intent poll), not other timers.
  f.ticks=function(n)for _=1,n or 1 do local due=f.timers;f.timers={};for _,t in ipairs(due)do if t.ms==1000 then t.fn(cx) else table.insert(f.timers,t)end end end end
  -- Every timer except that tick: request polls and continuations settle without an intent poll.
  f.others=function(n)for _=1,n or 1 do local due=f.timers;f.timers={};for _,t in ipairs(due)do if t.ms~=1000 then t.fn(cx) else table.insert(f.timers,t)end end end end
  f.choose=function(action)
   local p=f.picks[#f.picks]
   for _,item in ipairs(p.spec.items)do if item.action==action then p.fn(item,nil,cx);return end end
   error('no menu item '..action)
  end
  f.labels=function()local out={};for _,item in ipairs(f.picks[#f.picks].spec.items)do out[item.label]=true end;return out end
  f.toasted=function(text)for _,t in ipairs(f.toasts)do if t.text==text or t.sub==text then return true end end;return false end
  f.spawners=function()local n=0;for _ in pairs(world.blocks)do n+=1 end;return n end
  f.launches=function()local n=0;for _,r in ipairs(world.requests)do if r.op=='launch_record' then n+=1 end end;return n end
  f.approve_setup=function(pane)
   pane=pane or next(world.blocks) or add_block(world)
   world.blocks[pane].topology={mode='single',selected=world.host.id,window=window_key,observation=assert(load_pure('setup_discovery').devices({world.host},world.host))}
   table.insert(world.blocks[pane].intents,intent('approved-guided-setup','setup',world.authority.config_revision))
   f.others(1);f.ticks(2)
   return pane
  end
  return f
 end
 do
 -- Run the actual route callback, observer hooks and compact ORCH surface reader
 -- with remote SDK IDs. The HOST IDs intentionally belong to another domain.
 local function migration_world(operation)
  local world=new_world()
  world.sdk_session=281474976710659;world.host.id=9;world.host.kind='remote';world.host.sessions={world.sdk_session}
  world.next_pane=281474976710700;world.desktop_namespace='clicked-desktop'
  local pane=add_block(world);local peer=add_block(world);world.blocks[peer].block='orchplus.orchestrator'
  world.migration={consents={},results={},
   challenge={schema=1,nonce='directed-migration',operation=operation or 'inspect',native_window='',native_namespace='clicked-desktop',native_conn=1,native_since=1,native_session=3,host_pane_id='500',expected={source_revision=1,source_sha256=string.rep('a',64)}},
   peer={protocol=2,phase='legacy',source_nonce='orch-source',host_pane_id='600',authority_revision=12,source_sha256=string.rep('c',64),
    qualification={proof={source_schema=3,source_revision=12,source_sha256=string.rep('c',64),candidate_namespace='orch-candidate',protocol=1,state='ready',phase='stable',managed_sha256=string.rep('b',64),pending_immutable=0,blockers=0},
     selection={logical_session_ids=runtime.json.array(),mailbox_handles=runtime.json.array()}}}}
  return world,pane
 end
 local function migration_click(view,pane,operation)
  return view.link({url='tern-spawn://managed-migration/500/'..(operation or 'inspect')..'/directed-migration',pane=pane},view.cx)
 end
 for _,operation in ipairs({'inspect','prepare','finish'}) do
  local world,pane=migration_world(operation);local view=window(world,'')
  check(migration_click(view,pane,operation).handled==true,'WINDOW routes directed '..operation..' consent')
  view.ticks(2)
  local consent=world.migration.consents[1];local result=world.migration.results[1]
  check(#world.migration.consents==1 and #world.migration.results==1 and consent.pane==pane and result.pane==pane,'remote encoded SDK Config receives exactly one migration consent and result')
  check(consent.value.window=='' and consent.value.native_namespace=='clicked-desktop' and consent.value.native_conn==1 and consent.value.native_since==1,'migration hooks capture the exact desktop recipient despite empty window key')
  check(result.value.operation==operation and result.value.intent_id=='directed-migration' and result.value.window_consent==consent.value.window_consent and result.value.native_namespace=='clicked-desktop','migration result is bound to the directed operation, nonce and WINDOW token')
  check(result.value.native_session==nil and result.value.native_window.native_session==nil and world.sdk_session~=world.migration.challenge.native_session,'remote SDK session is neither compared with nor echoed as HOST native session')
  check(result.value.peer_qualification.host_pane_id=='600' and result.value.peer_qualification.qualification.proof.source_revision==12,'migration result uses actual qualified ORCH native surface bytes')
  local reloaded=window(world,'');reloaded.ticks(3)
  check(#world.migration.consents==1 and #world.migration.results==1 and reloaded.inspections==1,'WINDOW reload initializes its journal but cannot replay retained migration publication')
 end
 local ownerWorld,ownerPane=migration_world();local ownerView=window(ownerWorld,'')
 migration_click(ownerView,ownerPane)
 local foreignWorld,foreignPane=migration_world();foreignWorld.desktop_namespace='foreign-desktop'
 foreignWorld.migration.challenge=copy(ownerWorld.migration.challenge)
 local foreignView=window(foreignWorld,'');foreignView.ticks(3)
 check(foreignPane==ownerPane and #foreignWorld.migration.consents==0 and #foreignWorld.migration.results==0 and foreignView.inspections==1,'foreign desktop with equal empty key, conn/since and SDK IDs cannot adopt another WINDOW consent')
 local staleWorld,stalePane=migration_world();staleWorld.stale_migration_token=true
 local staleView=window(staleWorld,'');migration_click(staleView,stalePane);staleView.ticks(3)
 check(#staleWorld.migration.consents==1 and #staleWorld.migration.results==0 and staleView.inspections==1,'stale WINDOW consent token cannot authorize even an otherwise exact migration challenge')
 for _,field in ipairs({'nonce','operation','host_pane_id','native_namespace','native_conn','native_since'}) do
  local world,pane=migration_world();world.stale_migration_token=true
  local view=window(world,'');migration_click(view,pane)
  world.migration.challenge.window_consent=world.migration.consents[1].value.window_consent
  world.migration.challenge[field]=if field=='native_conn' or field=='native_since' then 99 elseif field=='operation' then 'prepare' elseif field=='host_pane_id' then '501' else 'other'
  view.ticks(2)
  check(#world.migration.results==0 and view.inspections==1,'directed migration excludes mismatched challenge '..field)
 end
 end
 -- The main palette opens a real panel, not another floating menu.
 local empty=new_world({});local e=window(empty);e.commands.spawn_menu(e.cx)
 check(empty.opened==1 and #e.picks==0 and #empty.requests==0,'empty roster opens a pane without a decision popup or execution')
 local done=new_world();local shown=add_block(done);local d=window(done);d.commands.spawn_menu(d.cx)
 check(done.focus==shown and #d.picks==0 and #done.requests==0,'configured roster reuses its real pane without a floating submenu or launch')
 check(d.commands.spawn_setup~=nil and d.commands.spawn_running~=nil,'dedicated setup and current-agent commands remain available')
 -- R1: launch intents from a visible Config, queued oldest first by the host.
 local once=new_world();once.keep_intent=true
 local clicked=add_block(once,{intents={intent('intent-1','record',1,'alpha')}})
 local o=window(once);o.round(4)
 check(o.launches()==1 and #once.acks>=2 and once.acks[1]=='intent-1' and once.acks[#once.acks]=='intent-1','an intent read on several ticks starts its single agent exactly once and is acknowledged each time')
 check(once.blocks[clicked]~=nil and once.opened==0 and once.closes==0,'a clicked launch runs from that Config, which stays open, and opens no other block')
 table.insert(once.blocks[clicked].intents,intent('intent-2','record',1,'alpha'));o.round(4)
 check(o.launches()==2 and once.requests[2].data.record_id=='alpha','a newer queued intent for one saved agent runs the Spawn specific path for that record')
 local again=window(once);again.round(3)
 check(o.launches()==2,'the native incarnation journal keeps a reloaded window from running still-queued intents again')
 local competitors=new_world();competitors.keep_intent=true
 local competitivePane=add_block(competitors,{intents={intent('cross-window-once','record',1,'alpha')}})
 local firstWindow=window(competitors,'first-window')
 local secondWindow=window(competitors,'second-window')
 firstWindow.round(1);secondWindow.round(1)
 for _=1,6 do secondWindow.round(1);firstWindow.round(1)end
 check(firstWindow.launches()==1 and competitors.blocks[competitivePane].intents[1].recipient.window_key=='first-window','HOST pending recipient excludes another ordinary window despite separate native intent files')
 competitors.conn=2;competitors.since=2
 local reusedWindow=window(competitors,'first-window');reusedWindow.round(6)
 check(firstWindow.launches()==1,'reused positional key with a fresh connection cannot execute a previous recipient obligation')
 competitors.conn=1;competitors.since=1
 local reloadedWinner=window(competitors,'first-window');reloadedWinner.round(6)
 check(firstWindow.launches()==1,'original recipient reload reads its native journal and acknowledges without repeating the ordinary execution')
 -- Order in which each intent was first acked (a kept queue is re-acked on later ticks).
 local function acked(world,ids)
  local seen,first={},{};for _,id in ipairs(world.acks)do if not first[id] then first[id]=true;table.insert(seen,id)end end
  if #seen~=#ids then return false end
  for i,id in ipairs(ids)do if seen[i]~=id then return false end end
  return true
 end
 local rapid=new_world();rapid.keep_intent=true
 add_block(rapid,{intents={intent('rapid-1','record',1,'alpha'),intent('rapid-2','record',1,'alpha'),intent('rapid-3','record',1,'alpha')}})
 local r=window(rapid);r.round(12)
 check(r.launches()==3 and rapid.requests[2].data.record_id=='alpha','three intents in one read launch three times, in click order')
 check(acked(rapid,{'rapid-1','rapid-2','rapid-3'}),'each queued intent is acked after it runs, oldest first')
 r.round(6)
 check(r.launches()==3,'re-reading a queue of already-run intents launches nothing')
 local deferred=new_world();deferred.hold=true
 local queue=add_block(deferred,{intents={intent('wait-1','record',1,'alpha'),intent('wait-2','record',1,'alpha')}})
 local dw=window(deferred);dw.round(5)
 check(dw.launches()==1 and acked(deferred,{'wait-1'}) and #deferred.blocks[queue].intents==1,'while a batch from this window runs, the next intent waits unjournalled and unacked')
 local function answer(world)
  world.hold=false
  local a=world.authority
  for _,held in ipairs(world.requests)do
   if not a.replies[held.request_id] and (a.request_sequences[held.observer_id] or 0)<held.request_sequence then
    a.replies[held.request_id]={request_id=held.request_id,observer_id=held.observer_id,request_sequence=held.request_sequence,ok=false,error='disabled',config_revision=a.config_revision,attempt_revision=0}
    a.request_sequences[held.observer_id]=held.request_sequence
   end
  end
 end
 answer(deferred)
 dw.round(10)
 check(dw.launches()==2 and acked(deferred,{'wait-1','wait-2'}) and #deferred.blocks[queue].intents==0,'the waiting intent runs once the batch settles')
 local mixed=new_world()
 add_block(mixed,{intents={intent('old-1','record',0,'alpha'),intent('new-1','record',1,'alpha'),intent('old-2','record',0,'alpha'),intent('new-2','record',1,'alpha')}})
 local mx=window(mixed);mx.round(12)
 local refusals=0;for _,t in ipairs(mx.toasts)do if t.sub=='Config changed; press again' then refusals+=1 end end
 check(mx.launches()==2 and refusals==2 and mixed.requests[2].data.record_id=='alpha' and acked(mixed,{'old-1','new-1','old-2','new-2'}),'stale intents are refused and acked in place, valid ones launch once each in order')
 local stale=new_world();local refused=add_block(stale,{intents={intent('stale-1','record',0,'alpha')}})
 local s=window(stale);s.round(3)
 check(#stale.requests==0 and s.toasted('Config changed; press again') and stale.acks[1]=='stale-1' and #stale.blocks[refused].intents==0,'a stale config_revision is refused with a toast and acked, and nothing launches')
 local hidden=new_world();local parked=add_block(hidden,{parked=true,intents={intent('parked-1','record',1,'alpha')}})
 local h=window(hidden);h.ticks(3)
 check(#hidden.requests==0 and #hidden.acks==0 and hidden.blocks[parked]~=nil,'an intent on a parked Config is never run or acked')
 local addressed=new_world();local navigation=intent('navigation-owner','readiness');navigation.native_window='another-window'
 local addressedPane=add_block(addressed,{intents={navigation}})
 local nw=window(addressed);nw.ticks(2)
 check(#addressed.acks==0 and #addressed.requests==0 and #addressed.blocks[addressedPane].intents==1,'other windows neither consume nor settle an owner-addressed readiness click')
 addressed.blocks[addressedPane].intents[1].native_window='win';nw.ticks(2)
 check(addressed.acks[1]=='navigation-owner' and #addressed.requests==0 and #nw.toasts>0,'owner window reports unavailable ORCH navigation without creating a task')
 local routeWorld=new_world();local routePane=add_block(routeWorld)
 routeWorld.route_request={schema=1,nonce='two-window-diagnostic',command='exact-offline-helper',cwd='/fixture',native_session=1,source_pane=routePane,config_revision=1,status='running',cleanup_pending=true,backend='local-terminal'}
 local foreignWindow=window(routeWorld,'foreign-window');foreignWindow.ticks(2)
 check(#routeWorld.acks==0 and routeWorld.route_consents==nil and routeWorld.preflights==nil,'foreign window cannot replace the owner-directed diagnostic click with a polled intent')
 local ownerWindow=window(routeWorld,'owner-window')
 ownerWindow.link({url='tern-spawn://managed-route/'..tostring(routePane)..'/1/two-window-diagnostic',pane=routePane},ownerWindow.cx)
 ownerWindow.ticks(3)
 check(routeWorld.route_consents==1 and routeWorld.preflights==1 and #routeWorld.acks==0 and #routeWorld.blocks[routePane].intents==0,'owning window sends directed diagnostic consent and exactly one launch preflight without a legacy queued intent')
 check(routeWorld.route.native_namespace=='ns' and routeWorld.route.window=='owner-window' and routeWorld.route.native_conn==1 and routeWorld.route.native_since==1 and routeWorld.route.window_consent==routeWorld.last_route_consent.window_consent,'diagnostic publication keeps the exact desktop tuple and WINDOW consent token')
 foreignWindow.ticks(2);ownerWindow.ticks(2)
 check(routeWorld.preflights==1 and routeWorld.route_consents==1,'later foreign and owner ticks cannot replay the consented native diagnostic')
 local contextWorld=new_world();contextWorld.kv.config={schema=1,agents={spawn_record('owner-legacy')}}
 local contextPane=add_block(contextWorld,{page_context={nonce='owner-context',entry={kind='page',page='managed',native_window='another-window'}}})
 local cw=window(contextWorld);cw.ticks(2)
 check(#contextWorld.contexts==0 and contextWorld.blocks[contextPane].page_context~=nil,'foreign window ignores a page-context request without reporting a false failure or consuming it')
 contextWorld.blocks[contextPane].page_context.entry.native_window='win';cw.ticks(2)
 local handoff=contextWorld.contexts[1]
 check(#contextWorld.contexts==1 and handoff.pane==contextPane and handoff.value.nonce=='owner-context' and handoff.value.context.native_window=='win','own window hands native context to the exact visible SPAWN pane once')
 check(handoff.value.context.host.id==1 and handoff.value.context.host.kind=='local' and handoff.value.context.client_config.agents[1].id=='owner-legacy' and #contextWorld.requests==0,'own context carries only SPAWN legacy settings through its existing owner builder, without launching')
 do
  local world=new_world();local pane=add_block(world)
  world.default_command="sudo -n -u selected -H -- '/tools/native Ω' --profile 'work account'"
  world.blocks[pane].native_accounts={nonce='native-accounts-one',window='another-window'}
  local view=window(world);view.ticks(2)
  check(world.native_accounts==nil and world.starts==0,'foreign native-account discovery requests cannot read settings into the wrong owner window')
  world.blocks[pane].native_accounts.window='win';view.ticks(3)
  check(world.native_accounts and #world.native_accounts==1 and world.native_accounts[1].pane==pane,'native account discovery returns once to its captured visible SPAWN pane')
  check(world.native_accounts[1].value.choices[1].command==world.default_command and world.native_accounts[1].value.choices[1].label=='Tern default agent','supported effective-default discovery preserves exact selected account command without labels-to-users inference')
  check(world.starts==0 and #world.requests==0 and world.opened==0,'discovering actual native account routes neither launches a helper nor rewrites the roster')
 end
 -- Host restart notice: count or attempts, extra keys ignored; a 0.4.0 lost list never fails the snapshot.
 local function restart_view(extra)
  local world=new_world();add_block(world);world.authority.extra=extra
  local v=window(world);v.commands.spawn_running(v.cx)
  local line=nil
  for _,item in ipairs(v.picks[#v.picks] and v.picks[#v.picks].spec.items or {})do if item.group=='Host restart' then line=item.label end end
  return v,line
 end
 local counted,counted_line=restart_view({host_restart_notice={restart_id='restart-a',count=2,later_field=true}})
 check(counted.toasted('Host restarted: 2 SPAWN agents ended (cleared automatically)') and counted_line=='Host restarted: 2 SPAWN agents ended (cleared automatically)','a {restart_id,count} notice shows one info toast and an action-free Running agents line')
 local listed=restart_view({host_restart_notice={restart_id='restart-b',attempts={'attempt-1','attempt-2','attempt-3'}}})
 check(listed.toasted('Host restarted: 3 SPAWN agents ended (cleared automatically)'),'a {restart_id,attempts} notice counts its attempts')
 local legacy_host,legacy_line=restart_view({host_restart={restart_id='restart-c',attempts={'attempt-9'}}})
 check(#legacy_host.picks==1 and legacy_line==nil and not legacy_host.toasted('Host restarted: 1 SPAWN agent ended (cleared automatically)'),'a 0.4.0 host_restart list is tolerated and never shown as automatic cleanup')
 -- Review setup result clicked in Config with no setup run in this window.
 local elsewhere=new_world();add_block(elsewhere,{intents={intent('result-1','result')}})
 local ew=window(elsewhere);ew.round(3)
 check(#ew.picks==0 and #elsewhere.requests==0 and elsewhere.acks[1]=='result-1','a result click without this window binding is acknowledged without import or invented provenance')
 -- A panel opened by the user remains available after its single launch settles.
 local user=new_world();local u=window(user)
 u.commands.spawn_config(u.cx);local mine=next(user.blocks)
 table.insert(user.blocks[mine].intents,intent('user-one','record',1,'alpha'));u.round(4)
 check(#user.requests==1 and user.opened==1 and user.closes==0 and user.blocks[mine]~=nil,'the user panel remains open after one explicit saved-agent launch')
 local leftover=new_world();local forgotten=add_block(leftover,{parked=true})
 window(leftover).round(1)
 check(leftover.blocks[forgotten]==nil and leftover.closes==1,'window load closes a parked Config with no pending request')
 -- Upgrade boundary: an old journalled Mark-no-longer-running request.
 local legacy=new_world();add_block(legacy)
 local observer_id='window-ns-1-1-win'
 legacy.kv['window-observer-namespace']='ns'
 legacy.kv['window-observer:'..observer_id]={version=2,id=observer_id,transports={['authority-1']={sequence=3,acknowledgments={},pending={request_id=observer_id..':3',op='resolve_lost_attempts'}}},tracked={},next_run=1}
 legacy.kv['window-observer-index:ns']={['window-observer:'..observer_id]={window='win',saved=1}}
 local lg=window(legacy);lg.round(1)
 local journal=nil
 for path,bytes in pairs(legacy.files)do if path:sub(-14)=='/observer.json' then journal=runtime.json.decode(bytes).transports['authority-1'] end end
 check(lg.toasted('An old Mark-no-longer-running request was cleared; SPAWN now does this automatically') and journal.pending==nil and journal.acknowledgments[1]==observer_id..':3' and #legacy.requests==0,'an old journalled resolve request is dropped with the info toast and never replayed')
 table.insert(legacy.blocks[next(legacy.blocks)].intents,intent('after-upgrade','record',1,'alpha'));lg.round(3)
 check(#legacy.requests==1 and legacy.requests[1].op=='launch_record' and legacy.requests[1].acknowledged_requests[1]==observer_id..':3','the next request launches normally and acknowledges the dropped one')
 -- Provider-neutral setup exercises the window, not account-choice or wording snapshots.
 for _,missing in ipairs({'missing','null','blank','whitespace'})do
  local world=new_world({})
  if missing=='null' then world.default_command=runtime.json.null
  elseif missing=='blank' then world.default_command=''
  elseif missing=='whitespace' then world.default_command=' \t\n 'end
  local pane=add_block(world);local view=window(world);view.commands.spawn_setup(view.cx)
  check(world.starts==0 and #world.requests==0 and #view.picks==0,'opening topology setup alone never starts a helper: '..missing)
  view.approve_setup(pane);view.round(3)
  check(world.starts==0 and #world.requests==0 and #view.picks==0,'missing effective default blocks approved setup before admission: '..missing)
 end
 do
  local world=new_world({});local pane=add_block(world);local view=window(world)
  world.blocks[pane].topology={mode='single',request={nonce='read-actual-devices'},window='win'}
  view.round(4)
  check(world.devices and world.devices.current.id==world.host.id and #world.devices.devices==1 and world.starts==0 and #world.requests==0,'native known-device discovery returns actual current membership without creating helper jobs or transport panes')
  world.blocks[pane].topology.selected=999
  table.insert(world.blocks[pane].intents,intent('undiscovered-primary','setup',1))
  view.round(4)
  check(world.starts==0 and #world.requests==0 and world.opened==0,'an undiscovered primary machine cannot admit setup, open a transport pane or fall back to the desktop')
 end
 local settingsFailure=new_world({});settingsFailure.settings_error=true
 local settingsView=window(settingsFailure);settingsView.approve_setup();settingsView.round(3)
 check(settingsFailure.starts==0 and #settingsFailure.requests==0 and not settingsView.toasted('Set a default agent in Tern settings, then try setup again.'),'native settings failure is not misreported as a missing default')
 local function setup_world()
  local world=new_world({});world.setup_enabled=true;world.default_command='non-omp --profile "opaque Ω"'
  local pane=add_block(world)
  local view=window(world);view.approve_setup(pane);view.round(16)
  return world,view,pane
 end
 local function submit(world)
  world.pending=runtime.json.encode({schema=2,setup_run_id=world.job.setup_run_id,confirmed=true,agents={spawn_record('reviewed')}})
  world.job.pending_bytes=#world.pending;world.job.pending_digest=load_pure('wire/codec').sha256(world.pending);world.job.setup_consumed=false
 end
 local review_serial=0
 local function review(world,view,pane,before_round)
  world.focus=pane -- A real native review click focuses that exact Config.
  review_serial+=1
  table.insert(world.blocks[pane].intents,intent('setup-review-'..review_serial,'result',world.authority.config_revision))
  if before_round then before_round() end
  view.round(4)
 end
 local native,setupView,setupPane=setup_world()
 check(native.starts==1 and #native.authority.records==0 and #setupView.picks==0,'empty roster uses the effective default with one native start and no account picker')
 check(native.started.command==native.default_command and native.started.cwd=='/fixture' and native.started.prompt==native.job.initial_prompt and native.started.how==native.job.placement,'native start preserves opaque command, host cwd, exact prompt and admitted placement rather than native defaults')
 check(#native.requests==4 and native.requests[1].op=='start_setup' and native.requests[2].op=='setup_claim' and native.requests[3].op=='setup_begin' and native.requests[4].op=='setup_bind','admission, claim, persisted effect and returned-pane binding follow existing authority transport')
 check(native.job.setup.agent_pane==901 and native.job.native_pane==7001,'SDK and host-native pane domains remain separate')
 check(native.arranged and native.arranged.id==901 and native.arranged.target==setupPane and native.arranged.dir=='left','guided helper is arranged left of its original SPAWN pane after one native start')
 local reloadView=window(native);reloadView.round(5)
 check(native.starts==1 and #native.requests==4,'reload observes admitted setup without repeating native start')
 review(native,reloadView,setupPane)
 check(#reloadView.picks==0 and native.imports==nil,'finished/idle native agent with no explicit submission produces no review or import')
 submit(native);review(native,reloadView,setupPane)
 check(#reloadView.picks==0 and native.imports==1 and native.starts==1,'explicit immutable host submission is saved automatically with no review popup and no launch (the helper held the one approval)')
 reloadView.round(4)
 check(native.imports==1 and #native.authority.records==1 and native.authority.records[1].id=='reviewed' and native.starts==1,'explicit Import reviewed records saves only reviewed records and causes no launch')
 check(native.receipts==nil,'durable writer receipt reaches the UI without billing an extra setup-helper model turn')
 local importRequest=native.requests[#native.requests]
 check(importRequest.op=='import_records' and importRequest.data.records==nil and importRequest.data.confirmed==true and #importRequest.acknowledged_requests==1,'import consumes authority-held bytes and acknowledges the preceding durable reply')
 review(native,reloadView,setupPane);reloadView.round(3)
 check(native.imports==1 and native.starts==1,'a repeated result click cannot import twice or launch')
 local postImport=window(native);postImport.round(3);review(native,postImport,setupPane)
 do
  local remote=new_world({});remote.setup_enabled=true;remote.default_command='native-default';remote.cwd='\\fixture'
  local pane=add_block(remote);local view=window(remote);view.approve_setup(pane);view.round(16)
  check(remote.starts==1 and remote.started.cwd=='/fixture','a Windows desktop starts setup in the actual POSIX execution-host folder, not its displayed path')
  remote.agents[901].cwd='\\fixture';submit(remote);review(remote,view,pane);view.round(4)
  check(remote.imports==1 and remote.starts==1,'desktop-formatted remote agent folders do not strand a host-bound proposal or repeat startup')
  local absent=new_world({});absent.setup_enabled=true;absent.default_command='native-default';absent.host_cwd=false
  local missingPane=add_block(absent);local missingView=window(absent);missingView.approve_setup(missingPane);missingView.round(5)
  check(absent.starts==0 and #absent.requests==0,'missing host-folder evidence cannot fall back to the desktop folder or start a helper')
 end
 do
  local combined,combinedView,combinedPane=setup_world();submit(combined);review(combined,combinedView,combinedPane)
  combinedView.round(4)
  local approvedRequest=combined.requests[#combined.requests]
  check(combined.imports==1 and combined.preparation_calls==1 and approvedRequest.data.preparation~=nil and combined.preparation_input.reviewed.import_request_id==approvedRequest.request_id,'one final native decision persists exact consent with the reviewed save, then starts preparation without another click')
  check(combined.starts==1 and combined.receipts==nil and combined.preparation.status=='preparing','saved settings alone do not report preparation success or cause an extra setup-helper model turn')
  local changed,changedView,changedPane=setup_world();submit(changed)
  review(changed,changedView,changedPane,function()changedView.cx.window_key=function()return 'different-native-window'end end)
  check(changed.preparation_calls==nil and changed.starts==1,'post-click native window change never retargets the captured preparation or model consent')
 end
 check(native.imports==1 and native.starts==1,'post-import reload and acknowledged review intent have no effects')
 local cancelled,cancelView,cancelPane=setup_world();submit(cancelled)
 local cancelIntent=intent('discard-cancelled-1','discard',cancelled.authority.config_revision,cancelled.job.id)
 cancelIntent.native_window='win';table.insert(cancelled.blocks[cancelPane].intents,cancelIntent)
 cancelView.round(4);cancelView.choose('cancel');cancelView.round(2)
 check(cancelled.discards==nil and cancelled.imports==nil and not cancelled.job.setup_consumed and cancelled.starts==1,'cancelling the explicit discard decision preserves the pending proposal and helper')
 local discardAgain=intent('discard-cancelled-2','discard',cancelled.authority.config_revision,cancelled.job.id)
 discardAgain.native_window='win';table.insert(cancelled.blocks[cancelPane].intents,discardAgain)
 cancelView.round(4);cancelView.choose('discard');cancelView.round(4)
 check(cancelled.discards==1 and cancelled.imports==nil and cancelled.job.setup_discarded==true and #cancelled.authority.records==0 and cancelled.starts==1,'native discard confirms only the exact pending proposal without importing, launching or closing its helper')
 local closed,closedView,closedPane=setup_world();submit(closed)
 closed.agents[901]=nil;closedView.handlers.pane_closed({pane=901},closedView.cx)
 local discardIntent=intent('discard-after-helper-closed','discard',closed.authority.config_revision,closed.job.id)
 discardIntent.native_window='win';table.insert(closed.blocks[closedPane].intents,discardIntent)
 closedView.round(4);closedView.choose('discard');closedView.round(4)
 check(closed.discards==1 and closed.imports==nil and closed.job.setup_consumed and closed.starts==1,'panel discard remains available after the helper closes rather than requiring the unavailable automatic-import source')
 for _,mutation in ipairs({'default','revision','sequence','native-pane','sdk-pane','run','binding','attempt-sequence','bytes','consumed','duplicate','closed','config-block','other-window','delivery-error'})do
  local world,view,pane=setup_world();submit(world)
  local function mutate()
  if mutation=='default' then world.default_command='different-default'
  elseif mutation=='revision' then world.authority.config_revision+=1
  elseif mutation=='sequence' then world.authority.request_sequences[world.job.observer_id]+=1
  elseif mutation=='native-pane' then world.job.native_pane=7002
  elseif mutation=='sdk-pane' then world.job.setup.agent_pane=902
  elseif mutation=='run' then world.job.setup_run_id='different-run'
  elseif mutation=='binding' then world.job.setup.binding='different-binding'
  -- Changes only after the result was read and reviewed, so the commit's exact-source fence must catch it.
  elseif mutation=='attempt-sequence' then world.result_hooks={[1]=function()world.attempt.sequence+=1 end}
  elseif mutation=='bytes' then world.pending=world.pending:gsub('ordinary%-cli','differentcli')
  elseif mutation=='consumed' then world.job.setup_consumed=true
  elseif mutation=='duplicate' then world.duplicate_agent=true
  elseif mutation=='closed' then world.agents[901]=nil;view.handlers.pane_closed({pane=901},view.cx)
  elseif mutation=='config-block' then world.blocks[pane]=nil
  elseif mutation=='other-window' then view.cx.window_key=function()return 'another-window'end
  elseif mutation=='delivery-error' then world.agents[901].delivery_error='native delivery failed'end
  end
  -- The helper's approval is the only one: a changed source is refused before the automatic save.
  review(world,view,pane,mutate)
  check(#view.picks==0 and world.imports==nil and #world.authority.records==0 and world.starts==1 and #world.requests==4,'automatic save rechecks a changed source before any import request: '..mutation)
 end
 -- The same fences, but changed AFTER a successful capture, while the saved import still waits
 -- to be dispatched: the preflight must refuse it, nothing is saved or prepared, and the captured
 -- approval is cancelled (a fresh review of the restored source can then be captured again).
 do
  local late={
   {'attempt-sequence',2,function(w)local old=w.attempt.sequence;w.attempt.sequence+=1;return function()w.attempt.sequence=old end end},
   {'native-pane',2,function(w)local old=w.job.native_pane;w.job.native_pane=7002;return function()w.job.native_pane=old end end},
   {'sdk-pane',2,function(w)local old=w.job.setup.agent_pane;w.job.setup.agent_pane=902;return function()w.job.setup.agent_pane=old end end},
   {'run',2,function(w)local old=w.job.setup_run_id;w.job.setup_run_id='different-run';return function()w.job.setup_run_id=old end end},
   {'binding',2,function(w)local old=w.job.setup.binding;w.job.setup.binding='different-binding';return function()w.job.setup.binding=old end end},
   {'consumed',2,function(w)w.job.setup_consumed=true;return function()w.job.setup_consumed=false end end},
   {'delivery-error',2,function(w)w.agents[901].delivery_error='native delivery failed';return function()w.agents[901].delivery_error=nil end end},
   {'bytes',3,function(w)local old=w.pending;w.pending=w.pending:gsub('ordinary%-cli','differentcli');return function()w.pending=old end end},
  }
  for _,case in ipairs(late)do
   local name,read,apply=case[1],case[2],case[3]
   local world,view,pane=setup_world();submit(world)
   local restore
   world.result_hooks={[read]=function()restore=apply(world)end}
   review(world,view,pane)
   check(restore~=nil,'the late change was applied after a successful capture: '..name)
   check(world.imports==nil and #world.authority.records==0 and world.preparation_calls==nil and #view.picks==0,'late source change is refused before the import is dispatched: '..name)
   restore();world.result_hooks=nil;world.result_reads=0
   review(world,view,pane);view.round(4)
   check(world.imports==1 and world.preparation_calls==1,'the cancelled approval does not block a fresh capture of the restored source: '..name)
  end
  -- The native window changes after the capture, before the dispatch is accepted.
  local moved,movedView,movedPane=setup_world();submit(moved)
  moved.result_hooks={[2]=function()movedView.cx.window_key=function()return 'different-native-window'end end}  -- read 2 is BEFORE capture: capture itself refuses
  review(moved,movedView,movedPane)
  check(moved.imports==nil and moved.preparation_calls==nil,'a window change after capture refuses the dispatch and never reaches preparation')
  movedView.cx.window_key=function()return 'win' end
  moved.result_hooks=nil;moved.result_reads=0
  review(moved,movedView,movedPane);movedView.round(4)
  check(moved.imports==1 and moved.preparation_calls==1,'the window-change refusal cancelled its captured approval, so a fresh review can capture again')
  -- The window changes AFTER a successful capture and before the dispatch is accepted: the
  -- existing capture must be cancelled, nothing saved or prepared, and a fresh capture must work.
  local exercised=0
  for nth=1,10 do
   local late,lateView,latePane=setup_world();submit(late)
   late.state_reads=0
   late.state_hooks={[nth]=function()lateView.cx.window_key=function()return 'different-native-window'end end}
   review(late,lateView,latePane)
   if late.captures and late.captures>0 and late.imports==nil then
    exercised+=1
    check(late.preparation_calls==nil and #late.authority.records==0,'a window change after a successful capture refuses the dispatch: nothing saved or prepared (state read '..nth..')')
    check((late.cancels or 0)>0,'the existing capture is cancelled when the window changes before dispatch (state read '..nth..')')
    local captures_before=late.captures
    lateView.cx.window_key=function()return 'win' end
    late.state_hooks=nil
    review(late,lateView,latePane);lateView.round(4)
    check(late.captures>captures_before and late.imports==1 and late.preparation_calls==1,'a fresh capture succeeds after the cancelled one (state read '..nth..')')
   end
  end
  check(exercised>0,'at least one window change landed after a successful capture and before dispatch')
  -- The window changes after the save, before preparation starts: saved, never retargeted.
  local after,afterView,afterPane=setup_world();submit(after)
  after.after_import=function()afterView.cx.window_key=function()return 'different-native-window'end end
  review(after,afterView,afterPane);afterView.round(4)
  check(after.imports==1 and after.preparation_calls==nil,'a window change after the save never retargets the captured preparation')
  -- A native account the helper did not disclose a paid check for is saved but never prepared.
  local scoped,scopedView,scopedPane=setup_world()
  local omp=spawn_record('omp-a');omp.provider='OMP';omp.backend='native-agent';omp.command='omp';omp.prompt='Begin.'
  local function submit_scope(world,paid)
   local value={schema=2,setup_run_id=world.job.setup_run_id,confirmed=true,agents={spawn_record('reviewed'),omp}}
   if paid then value.paid_checks=paid end
   world.pending=runtime.json.encode(value)
   world.job.pending_bytes=#world.pending;world.job.pending_digest=load_pure('wire/codec').sha256(world.pending);world.job.setup_consumed=false
  end
  submit_scope(scoped,nil);review(scoped,scopedView,scopedPane);scopedView.round(4)
  local ids={};for _,entry in ipairs(scoped.preparation_input and scoped.preparation_input.entries or {})do table.insert(ids,entry.record_id)end
  check(scoped.imports==1 and #scoped.authority.records==2 and #ids==1 and ids[1]=='reviewed','an undisclosed native account is saved but not part of the automatic preparation')
  local disclosed,disclosedView,disclosedPane=setup_world();submit_scope(disclosed,{'omp-a'});review(disclosed,disclosedView,disclosedPane);disclosedView.round(4)
  ids={};for _,entry in ipairs(disclosed.preparation_input and disclosed.preparation_input.entries or {})do table.insert(ids,entry.record_id)end
  check(disclosed.imports==1 and #ids==2,'a native account the helper listed in paid_checks is prepared with the roster')
 end
 local automatic,automaticView,automaticPane=setup_world();submit(automatic)
 automatic.focus=901;automaticView.round(4)
 check(#automaticView.picks==0 and automatic.selections==1 and automatic.blocks[automaticPane].selected==automatic.job.id and automatic.imports==1,'a submitted result is saved automatically only through its live initiating Config while its own helper is focused')
 local background,backgroundView,backgroundPane=setup_world();submit(background)
 background.focus=add_block(background);backgroundView.round(4)
 check(#backgroundView.picks==0 and background.selections==nil and background.imports==nil,'another focused Config cannot awaken automatic review of a background setup result')
 local cross,crossView,crossPane=setup_world();submit(cross)
 local foreign=window(cross,'foreign');review(cross,foreign,crossPane)
 check(#foreign.picks==0 and cross.imports==nil and cross.starts==1,'a second native window cannot borrow the original run submission')
 local another=add_block(cross);review(cross,crossView,another)
 check(#crossView.picks==0 and cross.imports==nil,'another Config in the same window cannot silently retarget result review')
 local clipped,clippedView,clippedPane=setup_world();submit(clipped);clipped.clipped_result=true;review(clipped,clippedView,clippedPane)
 check(#clippedView.picks==0 and clipped.imports==nil,'clipped immutable result cannot be reviewed or imported')
 local maximum,maximumView,maximumPane=setup_world();submit(maximum)
 maximum.pending..=string.rep(' ',120000-#maximum.pending)
 maximum.job.pending_bytes=#maximum.pending;maximum.job.pending_digest=load_pure('wire/codec').sha256(maximum.pending)
 review(maximum,maximumView,maximumPane)
 check(#maximumView.picks==0 and maximum.result_read_limit>120000,'complete 120000-byte result retains independent native framing headroom and needs no review popup')
 maximumView.round(4)
 check(maximum.imports==1 and maximum.starts==1,'exact-limit complete result imports once without a second native launch')
 local oversized,oversizedView,oversizedPane=setup_world();submit(oversized)
 oversized.pending..=string.rep(' ',120001-#oversized.pending)
 oversized.job.pending_bytes=#oversized.pending;oversized.job.pending_digest=load_pure('wire/codec').sha256(oversized.pending)
 review(oversized,oversizedView,oversizedPane)
 check(#oversizedView.picks==0 and oversized.imports==nil and oversized.starts==1,
  'one byte beyond the result cap cannot use surface framing headroom to reach review or import')
 local delayed,delayedView,delayedPane=setup_world();submit(delayed);delayed.defer_selection=true
 review(delayed,delayedView,delayedPane)
 check(#delayedView.picks==0 and delayed.selections==1 and delayed.starts==1,'asynchronous host selection is observed without resending the action or native start')
 delayed.blocks[delayedPane].selected=delayed.blocks[delayedPane].awaiting_selection;delayedView.round(3)
 check(#delayedView.picks==0 and delayed.selections==1 and delayed.imports==1,'fresh result bytes are saved automatically after the host finishes selection')
 local nullResult,nullView,nullPane=setup_world();submit(nullResult)
 nullResult.pending=nullResult.pending:sub(1,-2)..',"unexpected":null}'
 nullResult.job.pending_bytes=#nullResult.pending;nullResult.job.pending_digest=load_pure('wire/codec').sha256(nullResult.pending)
 review(nullResult,nullView,nullPane)
 check(#nullView.picks==0 and nullResult.imports==nil,'raw null-valued fields cannot disappear into a falsely valid decoded review')
 local interrupted=new_world({});interrupted.setup_enabled=true;interrupted.default_command='other-provider';add_block(interrupted)
 local interruptedView=window(interrupted);interruptedView.approve_setup()
 local interruptedReload=window(interrupted);interruptedReload.round(8)
 check(interrupted.starts==0 and #interrupted.requests==1 and interrupted.job.stage=='admitted','reload before the admission callback preserves its pending result without claiming or starting')
 local uncertain=new_world({});uncertain.setup_enabled=true;uncertain.default_command='other-provider';uncertain.start_error=true;add_block(uncertain)
 local uncertainView=window(uncertain);uncertainView.approve_setup();uncertainView.round(16)
 local uncertainReload=window(uncertain);uncertainReload.round(5)
 check(uncertain.starts==1 and uncertain.job.stage=='unknown' and uncertain.requests[#uncertain.requests].op=='setup_uncertain','ambiguous native start is durably uncertain and never retried on reload')
 for _,drift in ipairs({'default','revision','sequence'})do
  local world=new_world({});world.setup_enabled=true;world.default_command='other-provider';add_block(world)
  world.after_request=function(r,w)
   if r.op~='setup_begin' then return end
   if drift=='default' then w.default_command='changed'
   elseif drift=='revision' then w.authority.config_revision+=1
   else w.authority.request_sequences[r.observer_id]+=1 end
  end
  local view=window(world);view.approve_setup();view.round(16)
  check(world.starts==0 and world.job.stage=='submission_intent','fresh pre-effect revalidation refuses '..drift..' drift after durable begin')
 end
end
return 'PASS window_dispatch '..tostring(checks)
