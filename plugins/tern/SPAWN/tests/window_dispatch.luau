-- Pure window fixtures: exact native surfaces are injected, never real panes/effects.
local root,section=...
assert(type(root)=='string','pass package directory')
assert(section==nil or section=='wake' or section=='retirement' or section=='window','unknown window dispatch section')
local runtime,environment=tern,getfenv()
local checks=0
local function check(v,m)assert(v,m);checks+=1 end
local function copy(v)if type(v)~='table'then return v end local n={}for k,x in pairs(v)do n[k]=copy(x)end return n end
local function fixture()
 local modules={};local scheduled;local events={};local request_reads=0
 local injected=setmetatable({timer=function(_,fn)scheduled=fn;return 1 end},{__index=runtime})
 local function load(name)
  name=name:gsub('^%./','');if modules[name]then return modules[name]end
  local fn=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
  setfenv(fn,setmetatable({tern=injected,require=load},{__index=environment}));modules[name]=fn();return modules[name]
 end
 local p,c,w=load('bridge_protocol'),load('codec'),load('dispatch_window')
 local origin={logical_session_id='session',owner_id='owner',owner_generation=1,host_pane_id='12',alias_nonce='alias',window_key='',window_epoch='epoch',native_session_id='3',window_host_id='7'}
 local r={schema=1,origin='orchplus',op='mailbox_publish_reply',request_id='publication',action_id='action-publication',controller_pane='44',controller_generation=1,origin_binding=copy(origin),logical_session_id='session',worker_id='worker',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',handle='mailbox',expected_generation=1,message_id='message',reply_seq=1,action_revision=1,reply_sha256=c.sha256('reply'),part='manifest',object_b64='e30=',object_sha256=c.sha256('{}')}
 local claim={executor='epoch',epoch=1,grant_id='grant-one'}
 local state={version=1,source_nonce='alias',host_pane_id='12',orch_session_id='session',owner_id='owner',owner_generation=1,command_cursor={origin=copy(origin),controller_pane='44',seq=1},action={action_id=r.action_id,phase='claimed',claim=copy(claim),execution_origin=copy(origin),execution_controller_pane='44',reconciliation_only=false}}
 local f={p=p,c=c,w=w,request=r,current=copy(r),state=state,claim=claim,events=events,asks=0,starts=0,action_reads=0,idle_reads=0,agent_state='idle',focus=44,projection={schema=1,kind='authorize',request=copy(r),nonce='challenge'}}
 local host={id=7,state='connected',panes={44,45,55}}
 local session={id=3,host=7}
 local function surface(block,key,role,bytes)return {surface={role='plugin.'..block},main={id='main.'..key,k='text',p={role=role,spans={{t=bytes}}}}}end
 local function close_target(native)
  if native then f.stops=(f.stops or 0)+1 else f.closes=(f.closes or 0)+1 end
  if f.stop_error then error('ambiguous native stop') end
  if f.stop_drift then state.action.claim.grant_id='stale-after-stop';return end
  if f.stop_result=='absent' then f.absent=true;host.panes={44,45}
  elseif f.stop_result=='exited' then f.agent_state='exited';f.exit_status=0 end
 end
 local cx={hosts={current=function()return host end},sessions={current=function()return session end},window_key=function()return ''end,agents={
  get=function()if f.unrecognized then error('not a native agent')end return {pane=55}end,
  list=function()
   f.idle_reads+=1
   return if f.unknown then {} else {{pane=55,state=if f.idle_reads==f.busy_on_list then 'working' else f.agent_state,delivery_error=f.delivery_error}}
  end,
  ask=function(_,pane)
   f.asks+=1;f.asked_pane=pane
   if f.continue_during_ask then
    state.command_cursor.origin.window_epoch='continued-epoch';state.command_cursor.seq+=1
    state.action.execution_origin=copy(state.command_cursor.origin);state.action.reconciliation_only=true
   end
   if f.ask_error then error('possible delivery')end
  end,
  start=function()
   f.starts+=1
   if f.start_error then error('ambiguous native start')end
   local created=if f.start_panes then table.remove(f.start_panes,1) else 55
   -- Native start focuses the new agent pane unless a test models late (macOS) focus.
   if not f.start_keeps_focus then f.focus=created end
   return created
  end,
  stop=function()close_target(true)end,
 }}
 cx.layout={close=function()close_target(false)end,focus=function(_,id)
  f.focus_calls=(f.focus_calls or 0)+1
  if f.focus_error then error('focus refused') end
  f.focus=id;f.refocused=(f.refocused or 0)+1
 end}
 cx.session={
  focused=function()return f.focus end,
  pane=function(_,id)if id==55 and f.absent then return nil end return {block=if id==44 then 'orchplus.orchestrator' elseif id==45 or id==46 then 'spawn.dispatch' else 'agent',tab=1,kind=if id==55 then f.pane_kind or 'agent' else 'plugin',exited=if id==55 then f.exit_status else nil}end,
  tabs=function()return {{id=1,session=3}}end,
  panes=function()return if f.second then {{pane=45,block='spawn.dispatch'},{pane=46,block='spawn.dispatch'}} else {{pane=45,block='spawn.dispatch'}}end,
  surface=function(_,id,opts)
   -- An optional second dispatch pane carries its own exact launch action and request.
   local second=f.second
   if second then
    local key=second.request.action_id
    if id==46 then return surface('spawn.dispatch','spawn-dispatch-execution','spawn.dispatch.execution','SPAWN_EXECUTION v1 '..runtime.json.encode(second.projection))end
    if opts.root=='main.dispatch-action-'..key then return surface('orchplus.orchestrator','dispatch-action-'..key,'orchplus.dispatch',runtime.json.encode(second.state))end
    if opts.root=='main.dispatch-request-'..key then return surface('orchplus.orchestrator','dispatch-request-'..key,'orchplus.request',runtime.json.encode(second.request))end
   end
   if id==45 then return surface('spawn.dispatch','spawn-dispatch-execution','spawn.dispatch.execution','SPAWN_EXECUTION v1 '..runtime.json.encode(f.projection))end
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
  event=function(_,_,value)
   table.insert(events,copy(value))
   if f.event_error then error('ambiguous event submission')end
  end,
 }
 f.cx=cx;f.host=host
 -- Injectable monotonic clock for the focus guard deadline; the real clock otherwise.
 injected.now=function()return if f.clock then f.clock else runtime.now()end
 f.tick=function()if not scheduled then w.start()end scheduled(cx)end
 return f
end
local function adopt_claim(f)
 local claim=f.c.strict_decode(f.events[1].value,65536)
 f.projection.claim={executor_id=claim.executor_id,boot='fixture-boot'};f.projection.phase='claimed'
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
end
if section==nil then
 local function launch_fixture()
  local f=fixture()
  local r={schema=1,origin='orchplus',op='launch',request_id='launch',action_id='action-launch',controller_pane='44',controller_generation=1,origin_binding=copy(f.request.origin_binding),record_id='worker',record_revision=0,work_id='work',prompt='Complete the assigned work',cwd='/work',placement='tab',fresh=true,mailbox_handle='mailbox',enrolment={worker_id='worker',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',assignment_sha256=f.c.sha256('Complete the assigned work')}}
  f.request=r;f.current=copy(r);f.state.action.action_id=r.action_id
  f.projection={schema=1,kind='launch',request=copy(r),phase='resolved',orch_claim=copy(f.claim),launch={backend='native-agent',command='omp',prompt=r.prompt,cwd=r.cwd,placement=r.placement}}
  return f
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
 check(late.focus==55 and late.refocused==1 and #late.events==3,'a late restore happens once and the guard is then dropped')
 local operator=launch_fixture();begin_effect(operator);operator.start_keeps_focus=true;operator.tick()
 operator.focus=66;operator.tick();operator.focus=55;operator.tick()
 check(operator.focus==55 and operator.refocused==nil,'focus seen on a third pane drops the guard, so a later deliberate visit to the new pane is never stolen back')
 local expired=launch_fixture();begin_effect(expired);expired.start_keeps_focus=true;expired.clock=1000;expired.tick()
 expired.clock=6001;expired.focus=55;expired.tick()
 check(expired.focus==55 and expired.refocused==nil,'focus that reaches the new pane after the 5 s guard is left alone')
 -- Back to back: the second launch starts while focus still sits on the first new pane (its
 -- restore threw); its guard inherits the first guard's controller pane, not the earlier worker.
 local pair=launch_fixture();begin_effect(pair)
 local second=copy(pair.request);second.request_id='launch-two';second.action_id='action-launch-two'
 local second_state=copy(pair.state);second_state.action.action_id=second.action_id
 local second_projection=copy(pair.projection);second_projection.request=copy(second)
 pair.second={request=second,state=second_state,projection=second_projection};pair.host.panes={44,45,46,55,56}
 pair.start_panes={55,56};pair.focus_error=true;pair.tick()
 check(pair.starts==2 and pair.focus==56 and pair.focus_calls==2 and #pair.events==4 and result_of(pair,3).status=='submitted' and result_of(pair,4).pane_binding.pane_id=='56','two launches in one tick both submit although each immediate restore threw')
 pair.focus_error=false;pair.tick()
 check(pair.focus==44 and pair.refocused==1,'focus on the second new pane returns to the original controller pane, not the first worker')
 pair.focus=55;pair.tick()
 check(pair.focus==44 and pair.refocused==2 and #pair.events==4,'the first launch guard still restores its own late focus to the controller pane')
 local moved=launch_fixture();begin_effect(moved);moved.focus=45;moved.tick()
 check(moved.starts==1 and moved.focus==45 and moved.refocused==1,'focus returns to the pane the owner had focused, not a fixed controller pane')
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
 local released=settled.w.retained()
 check(released.markers==0 and released.requests==0 and settled.starts==1 and #settled.events==3,'a settled ORCH+ action releases its markers and starts nothing')
end
if section~='retirement' and section~='window' then
local good=fixture()
check(good.p.decode(runtime.json.encode(good.request))~=nil,'fixture uses valid immutable publication')
check(good.w.origin_ok(good.cx,45,good.request,good.claim),'exact live action and claim match')
good.tick()
check(#good.events==1 and good.events[1].act=='spawn.authorize','only exact live request emits private nonce response')
local observation=good.c.strict_decode(good.events[1].value,65536)
check(good.p.equal(observation.orch_claim,good.claim) and observation.nonce=='challenge','nonce response carries exact observed action claim')
good.tick();check(#good.events==1,'one window emits nonce once')
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
 return f
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
 f.tick()
 local claim=f.c.strict_decode(f.events[1].value,65536)
 f.projection.claim={executor_id=claim.executor_id,boot='fixture-boot'};f.projection.phase='claimed'
 f.tick();f.projection.phase='launching'
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
 became_busy.projection.claim={executor_id=renewed.executor_id,boot='fixture-boot'};became_busy.projection.phase='claimed';became_busy.tick();became_busy.projection.phase='launching';became_busy.tick()
 check(became_busy.asks==1,'new exact grant resumes only the proven never-started notification')
end
local chunk=wake_fixture();chunk.request.part='chunk';chunk.request.index=1;chunk.current=copy(chunk.request);chunk.projection.request=copy(chunk.request);chunk.tick()
check(#chunk.events==0 and chunk.asks==0,'reply chunks cannot authorize a publication wake')
local previous_window=wake_fixture(true);begin_wake(previous_window)
local reloaded_window=wake_fixture(true);reloaded_window.projection=copy(previous_window.projection);reloaded_window.tick()
check(reloaded_window.asks==0 and #reloaded_window.events==0,'new window executor cannot resume an older claimed ACK wake')
local retry=fixture();retry.projection.previous_claim=copy(retry.claim);retry.tick()
check(#retry.events==0,'capacity retry waits for a new live ORCH+ grant')
retry.state.action.claim.grant_id='new-retry-grant';retry.tick()
check(#retry.events==1 and retry.events[1].act=='spawn.authorize','new exact retry grant may answer the fresh challenge')
end
if section~='wake' and section~='window' then
 local function stop_fixture()
  local f=fixture()
  local r={schema=1,origin='orchplus',op='stop',request_id='stop',action_id='action-stop',controller_pane='44',controller_generation=1,origin_binding=copy(f.request.origin_binding),target_request_id='launch',target_action_id='launch-action',worker_id='worker',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',work_id='work',pane_binding={pane_id='55',window_epoch='epoch',window_key='',native_session_id='3',window_host_id='7'}}
  f.request=r;f.current=copy(r);f.state.action.action_id=r.action_id
  f.projection={schema=1,kind='stop',request=copy(r),phase='resolved',orch_claim=copy(f.claim),backend='native-agent'}
  return f
 end
 local function begin_stop(f)
  f.tick()
  local claim=f.c.strict_decode(f.events[1].value,65536)
  f.projection.claim={executor_id=claim.executor_id,boot='fixture-boot'};f.projection.phase='claimed'
  f.tick();f.projection.phase='launching'
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
 local terminal=stop_fixture();terminal.unrecognized=true;terminal.pane_kind='terminal';terminal.projection.backend='ssh-command';terminal.stop_result='absent';begin_stop(terminal);terminal.tick()
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
 local stopped=observing.w.retained()
 check(stopped.stopping==0 and stopped.markers==0 and observing.stops==1,'a settled ORCH+ stop releases its observation and markers without another stop')
 -- Explicit verified attach: one native ask to the exact attested idle agent pane, never a start.
 local function adopt_fixture()
  local f=fixture()
  local prompt='Complete the attached work'
  local r={schema=1,origin='orchplus',op='adopt',request_id='adopt',action_id='action-adopt',controller_pane='44',controller_generation=1,origin_binding=copy(f.request.origin_binding),record_id='worker',record_revision=0,work_id='work',prompt=prompt,mailbox_handle='mailbox',enrolment={worker_id='worker',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',assignment_sha256=f.c.sha256(prompt)},pane_binding={pane_id='55',window_epoch='epoch',window_key='',native_session_id='3',window_host_id='7'},attestation='operator_verified_exact_agent_pane'}
  f.request=r;f.current=copy(r);f.state.action.action_id=r.action_id
  f.projection={schema=1,kind='adopt',request=copy(r),phase='resolved',orch_claim=copy(f.claim),prompt='report-files-v1 preface\nASSIGNMENT_BYTES_BEGIN\n'..prompt}
  return f
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
 begin_effect(scoped);scoped.tick()
 check(scoped.asks==0,'an out-of-window adoption target never receives a native ask')
 local ambiguous=adopt_fixture();ambiguous.ask_error=true;begin_effect(ambiguous);ambiguous.tick();ambiguous.tick()
 check(ambiguous.asks==1 and ambiguous.c.strict_decode(ambiguous.events[3].value,65536).result.status=='uncertain' and #ambiguous.events==3,'an ambiguous native ask is reported uncertain and never repeated')
end
if section==nil or section=='window' then
 -- SPAWN window half (window.luau) with the real config/launch modules against a modelled host
 -- Config block and layout. A world outlives a window fixture, so a second fixture is a reload.
 local function spawn_record(id)
  return {id=id,provider='custom',account_label=id,backend='local-terminal',command='ordinary-cli',arguments={},enabled=true,include_all=true,placement='tab'}
 end
 local function new_world(records)
  return {kv={},blocks={},next_pane=100,host={id=1,state='connected',name='fixture',sessions={1},panes={}},
   authority={authority_id='authority-1',session_key='session-1',config_revision=1,records=records or {spawn_record('alpha')},replies={},request_sequences={}},
   requests={},acks={},closes=0,opened=0}
 end
 local function add_block(world,opts)
  world.next_pane+=1
  local id=world.next_pane
  world.blocks[id]={parked=opts~=nil and opts.parked==true,intents=opts and opts.intents or {}}
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
 local function window(world)
  local f={timers={},commands={},toasts={},picks={}}
  local cx=nil
  local fake=setmetatable({
   chrome={program_icon=function()end,status=function()end},
   files={button=function()end},
   timer=function(ms,fn)table.insert(f.timers,{ms=ms,fn=fn});return {} end,
   on=function()end,
   command=function(spec)f.commands[spec.id]=spec.run end,
   css=function()end,
   kv={get=function(key)return copy(world.kv[key])end,set=function(key,value)world.kv[key]=copy(value)end},
   json=runtime.json,
  },{__index=runtime})
  local stubs={
   native_cli={inspect=function(_,_,callback)callback({status=0,timed_out=false,stdout=runtime.json.encode({clients={{kind='window',window='win',conn=1,since=1}}})},nil,cx)end},
   dispatch_window={start=function()end,read_node=read_node},
   ['updater/window']={register=function()end},
  }
  local function load(name)name=name:gsub('^%./','');return stubs[name] or load_pure(name)end
  local function info(id)
   local b=world.blocks[id];if not b then return nil end
   return {pane=id,block='spawn.spawner',kind='plugin',title='SPAWN',tab=if b.parked then nil else 1,parked=b.parked,focused=world.focus==id}
  end
  local function node(key,role,text)return {surface={role='plugin.spawn.spawner'},main={id='main.'..key,k='text',p={role=role,spans={{t=text}}}}}end
  cx={
   hosts={current=function()return world.host end,list=function()return {world.host}end},
   sessions={current=function()return {id=1,host=1}end,list=function()return {{id=1,host=1}}end},
   agents={list=function()return {}end},
   window_key=function()return 'win' end,
   toast=function(_,level,text,sub)table.insert(f.toasts,{level=level,text=text,sub=sub})end,
   pick=function(_,spec)local p={spec=spec};table.insert(f.picks,p);return {next=function(_,fn)p.fn=fn end}end,
   new_block=function(_,block,_,_,opts)
    assert(block=='spawn.spawner','only SPAWN Config is opened');world.opened+=1
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
   park=function()error('SPAWN closes Config; it never parks it')end,
   unpark=function()error('SPAWN never adopts a parked Config')end,
  }
  cx.session={
   pane=function(_,id)return info(id)end,
   panes=function()local out={};for id in pairs(world.blocks)do table.insert(out,info(id))end;table.sort(out,function(a,b)return a.pane<b.pane end);return out end,
   tabs=function()return {{id=1,session=1}}end,
   tab_of=function(_,id)local i=info(id);return i and i.tab end,
   focused=function()return world.focus end,
   surface=function(_,id,opts)
    local b=world.blocks[id];if not b then return nil end
    local a=world.authority
    if opts.root=='main.spawn-state' then
     local state={version=2,ready=true,host_key='host:fixture',authority_id=a.authority_id,session_key=a.session_key,config_revision=a.config_revision,attempt_revision=0,records=a.records,attempts={},jobs={},replies=a.replies,request_sequences=a.request_sequences}
     for key,extra in pairs(a.extra or {})do state[key]=extra end
     return node('spawn-state',nil,'SPAWN_STATE_V2 '..runtime.json.encode(state))
    end
    if opts.root=='main.spawn-launch-intent' and #b.intents>0 then return node('spawn-launch-intent','spawn.launch.intent',runtime.json.encode({schema=1,intents=b.intents}))end
    return nil
   end,
   event=function(_,id,ev)
    local b=assert(world.blocks[id],'event sent to a closed Config')
    if ev.act=='spawn.launch-intent-ack' then
     table.insert(world.acks,ev.value)
     if not world.keep_intent then for i,queued in ipairs(b.intents)do if queued.intent_id==ev.value then table.remove(b.intents,i);break end end end
    elseif ev.act=='spawn.request' then
     -- The host refuses every launch as disabled: a skip-only batch settles without a ticket.
     local r=runtime.json.decode(ev.value);table.insert(world.requests,r)
     local a=world.authority
     for _,acked in ipairs(r.acknowledged_requests)do a.replies[acked]=nil end
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
  return f
 end
 local function only_menu(labels)return labels['Config'] and labels['Spawn all'] and labels['Spawn specific'] and not labels['Running agents'] and not labels['Review setup result'] end
 -- R2: the SPAWN menu.
 local empty=new_world({});add_block(empty)
 local e=window(empty);e.commands.spawn_menu(e.cx)
 check(e.labels()['Guided setup'] and only_menu(e.labels()),'no saved records: the menu offers Guided setup, Config, Spawn all and Spawn specific')
 local done=new_world();local shown=add_block(done)
 local d=window(done);d.commands.spawn_menu(d.cx)
 check(not d.labels()['Guided setup'] and only_menu(d.labels()),'a saved record hides Guided setup; Running agents and Review setup result are never offered')
 d.cx.layout:close(shown);d.commands.spawn_menu(d.cx)
 check(not d.labels()['Guided setup'],'with no Config open the menu keeps the saved-record count this client last read')
 check(d.commands.spawn_setup~=nil and d.commands.spawn_running~=nil,'palette commands SPAWN: Guided setup and SPAWN: Running agents stay')
 -- R1: launch intents from a visible Config, queued oldest first by the host.
 local once=new_world();once.keep_intent=true
 local clicked=add_block(once,{intents={intent('intent-1','all')}})
 local o=window(once);o.round(4)
 check(o.launches()==1 and #once.acks>=2 and once.acks[1]=='intent-1' and once.acks[#once.acks]=='intent-1','an intent read on several ticks runs Spawn all exactly once and is acked each time')
 check(once.blocks[clicked]~=nil and once.opened==0 and once.closes==0,'a clicked launch runs from that Config, which stays open, and opens no other block')
 table.insert(once.blocks[clicked].intents,intent('intent-2','record',1,'alpha'));o.round(4)
 check(o.launches()==2 and once.requests[2].data.record_id=='alpha','a newer queued intent for one saved agent runs the Spawn specific path for that record')
 local again=window(once);again.round(3)
 check(o.launches()==2,'the shared intent journal keeps a reloaded window from running still-queued intents again')
 -- Order in which each intent was first acked (a kept queue is re-acked on later ticks).
 local function acked(world,ids)
  local seen,first={},{};for _,id in ipairs(world.acks)do if not first[id] then first[id]=true;table.insert(seen,id)end end
  if #seen~=#ids then return false end
  for i,id in ipairs(ids)do if seen[i]~=id then return false end end
  return true
 end
 local rapid=new_world();rapid.keep_intent=true
 add_block(rapid,{intents={intent('rapid-1','all'),intent('rapid-2','record',1,'alpha'),intent('rapid-3','all')}})
 local r=window(rapid);r.round(12)
 check(r.launches()==3 and rapid.requests[2].data.record_id=='alpha','three intents in one read launch three times, in click order')
 check(acked(rapid,{'rapid-1','rapid-2','rapid-3'}),'each queued intent is acked after it runs, oldest first')
 r.round(6)
 check(r.launches()==3,'re-reading a queue of already-run intents launches nothing')
 local deferred=new_world();deferred.hold=true
 local queue=add_block(deferred,{intents={intent('wait-1','all'),intent('wait-2','all')}})
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
 add_block(mixed,{intents={intent('old-1','all',0),intent('new-1','all'),intent('old-2','record',0,'alpha'),intent('new-2','record',1,'alpha')}})
 local mx=window(mixed);mx.round(12)
 local refusals=0;for _,t in ipairs(mx.toasts)do if t.sub=='Config changed; press again' then refusals+=1 end end
 check(mx.launches()==2 and refusals==2 and mixed.requests[2].data.record_id=='alpha' and acked(mixed,{'old-1','new-1','old-2','new-2'}),'stale intents are refused and acked in place, valid ones launch once each in order')
 local stale=new_world();local refused=add_block(stale,{intents={intent('stale-1','record',0,'alpha')}})
 local s=window(stale);s.round(3)
 check(#stale.requests==0 and s.toasted('Config changed; press again') and stale.acks[1]=='stale-1' and #stale.blocks[refused].intents==0,'a stale config_revision is refused with a toast and acked, and nothing launches')
 local hidden=new_world();local parked=add_block(hidden,{parked=true,intents={intent('parked-1','all')}})
 local h=window(hidden);h.ticks(3)
 check(#hidden.requests==0 and #hidden.acks==0 and hidden.blocks[parked]~=nil,'an intent on a parked Config is never run or acked')
 -- A click queued in a SPAWN-opened Config during a multi-agent Spawn all runs after the batch.
 local queued=new_world({spawn_record('alpha'),spawn_record('beta')});queued.hold=true
 local qw=window(queued)
 qw.commands.spawn_menu(qw.cx);qw.choose('all')
 local carrier=next(queued.blocks)
 table.insert(queued.blocks[carrier].intents,intent('during-1','all'))
 qw.round(3)
 check(qw.launches()==1 and #queued.acks==0,'a click made while this window runs a batch waits')
 answer(queued);qw.others(6)
 check(queued.blocks[carrier]~=nil and queued.closes==0,'the batch settling never closes a Config holding a click not yet run')
 qw.round(14)
 check(qw.launches()==4 and acked(queued,{'during-1'}) and queued.blocks[carrier]~=nil and queued.closes==0,'the queued click runs once after the batch and its Config stays open')
 local raced=new_world({spawn_record('alpha'),spawn_record('beta')});raced.hold=true
 local rw=window(raced)
 rw.commands.spawn_menu(rw.cx);rw.choose('all')
 local raced_carrier=next(raced.blocks)
 table.insert(raced.blocks[raced_carrier].intents,intent('race-1','all'))
 answer(raced);rw.others(8)
 check(raced.blocks[raced_carrier]~=nil and raced.closes==0,'a batch settling before the intent poll still keeps a Config holding an unrun click')
 rw.round(16)
 check(rw.launches()==4 and acked(raced,{'race-1'}) and raced.blocks[raced_carrier]~=nil and raced.closes==0,'that click then runs once and its Config stays open')
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
 local ew=window(elsewhere);ew.round(2)
 check(ew.toasted('This setup was started in another window; paste its result in Config › Setup › Paste setup JSON') and elsewhere.acks[1]=='result-1','a result click without this window\'s setup run explains where to paste it')
 -- R5: no idle or parked Config left behind.
 local opened=new_world();local op=window(opened)
 op.commands.spawn_menu(op.cx);op.choose('all')
 check(opened.opened==1 and op.spawners()==1,'Spawn all opens one Config to carry the batch')
 op.round(3)
 check(opened.closes==1 and op.spawners()==0,'the Config SPAWN opened is closed once its skip-only batch settles')
 local user=new_world();local u=window(user)
 u.commands.spawn_config(u.cx);local mine=next(user.blocks);user.focus=nil
 u.commands.spawn_menu(u.cx);u.choose('all');u.round(3)
 check(#user.requests==1 and user.opened==1 and user.closes==0 and user.blocks[mine]~=nil,'a Config the user opened carries the batch and stays open')
 local watched=new_world();local w=window(watched)
 w.commands.spawn_menu(w.cx);w.choose('all');watched.focus=next(watched.blocks);w.round(3)
 check(watched.closes==0 and w.spawners()==1,'a SPAWN-opened Config the user is looking at stays open')
 local pending=new_world();pending.hold=true;local pe=window(pending)
 pe.commands.spawn_menu(pe.cx);pe.choose('all');pe.round(4)
 local busy=next(pending.blocks)
 check(pending.closes==0 and pending.blocks[busy]~=nil,'a Config with an unanswered request is never closed')
 pending.blocks[busy].parked=true
 pe.commands.spawn_menu(pe.cx);pe.choose('all');pe.round(2)
 check(pending.closes==0 and pending.blocks[busy]~=nil and pending.opened==2,'leftover cleanup never closes a parked Config whose request is pending')
 local cold=new_world();window(cold).round(2)
 local c=window(cold)
 c.commands.spawn_menu(c.cx);c.choose('all')
 check(c.spawners()==1,'cold start after a reload: the next Spawn opens exactly one Config')
 c.round(3)
 check(c.spawners()==0 and cold.opened==1,'cold start after a reload: no spawn.spawner block is left once the batch settles')
 local steady=new_world();window(steady).round(2)
 local old=add_block(steady,{parked=true})
 local st=window(steady)
 st.commands.spawn_menu(st.cx);st.choose('all')
 check(steady.blocks[old]==nil and st.spawners()==1,'steady state after a reload: the old parked Config is closed before a new one opens')
 st.round(3)
 check(st.spawners()==0,'steady state after a reload: no spawn.spawner block is left once the batch settles')
 local leftover=new_world();local forgotten=add_block(leftover,{parked=true})
 window(leftover).round(1)
 check(leftover.blocks[forgotten]==nil and leftover.closes==1,'window load closes a parked Config with no pending request')
 -- Upgrade boundary: an old journalled Mark-no-longer-running request.
 local legacy=new_world();add_block(legacy)
 local observer_id='window-ns-1-1-win'
 legacy.kv['window-observer-namespace']='ns'
 legacy.kv['window-observer:'..observer_id]={version=2,id=observer_id,transports={['authority-1']={sequence=3,acknowledgments={},pending={request_id=observer_id..':3',op='resolve_lost_attempts'}}},tracked={},next_run=1}
 local lg=window(legacy);lg.round(1)
 local journal=legacy.kv['window-observer:'..observer_id].transports['authority-1']
 check(lg.toasted('An old Mark-no-longer-running request was cleared; SPAWN now does this automatically') and journal.pending==nil and journal.acknowledgments[1]==observer_id..':3' and #legacy.requests==0,'an old journalled resolve request is dropped with the info toast and never replayed')
 lg.commands.spawn_menu(lg.cx);lg.choose('all');lg.round(3)
 check(#legacy.requests==1 and legacy.requests[1].op=='launch_record' and legacy.requests[1].acknowledged_requests[1]==observer_id..':3','the next request launches normally and acknowledges the dropped one')
end
return 'PASS window_dispatch '..tostring(checks)
