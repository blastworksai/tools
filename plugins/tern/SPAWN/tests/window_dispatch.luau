-- Pure window fixture: exact native surfaces are injected, never real panes/effects.
local root,section=...
assert(type(root)=='string','pass package directory')
assert(section==nil or section=='wake' or section=='retirement','unknown window dispatch section')
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
if section~='retirement' then
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
if section~='wake' then
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
return 'PASS window_dispatch '..tostring(checks)
