-- Window-only executor. Recreated VMs get new IDs and cannot reuse old claims.
local P=require('./bridge_protocol')
local Codec=require('./codec')
local M={}
local executor=string.format('spawn-%d-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647))
local sent={}
-- Control/effect markers grouped per ORCH+ request. A group is dropped only once that ORCH+
-- action reads back terminal (complete/resolved) from its own controller pane; claimed,
-- uncertain, missing or unreadable evidence keeps every marker. One group is checked per tick.
local groups,group_order,group_cursor={},{},0
local function mark(r,key)
 sent[key]=true
 local g=r.origin_binding.logical_session_id..'/'..r.request_id
 local entry=groups[g]
 if not entry then entry={source=r.controller_pane,action_id=r.action_id,binding=P.clone(r.origin_binding),keys={}};groups[g]=entry;table.insert(group_order,g) end
 entry.keys[key]=true
end
local timer=nil
local function read_node(cx,pane,block,key,role,limit)
 local info=cx.session:pane(pane);if not info or info.block~=block then return nil end
 local tree=cx.session:surface(pane,{as='table',root='main.'..key,nodes=4,depth=2,max_chars=limit})
 if type(tree)~='table' or type(tree.surface)~='table' or tree.surface.role~='plugin.'..block or tree.more and tree.more~=0 then return nil end
 local node=tree.main
 if type(node)~='table' or node.id~='main.'..key or node.k~='text' or node.more and node.more~=0 or type(node.p)~='table' or node.p.role~=role or type(node.p.spans)~='table' then return nil end
 local parts={};local size=0
 for _,span in ipairs(node.p.spans) do if type(span)~='table' or type(span.t)~='string' then return nil end size+=#span.t;if size>limit then return nil end table.insert(parts,span.t) end
 return table.concat(parts),node.id
end
local function member(cx,pane,host,session)
 local info=cx.session:pane(pane);if not info or not info.tab then return false end
 local found=false;for _,id in ipairs(host.panes) do if id==pane then found=true end end
 if not found then return false end
 for _,tab in ipairs(cx.session:tabs()) do if tab.id==info.tab and tab.session==session.id then return true end end
 return false
end
local function origin_ok(cx,bridge,r,expected_claim)
 local b=r.origin_binding;local host=cx.hosts:current();local session=cx.sessions:current()
 if not host or not session or host.state~='connected' or tostring(host.id)~=b.window_host_id or tostring(session.id)~=b.native_session_id or session.host~=host.id or cx:window_key()~=b.window_key then return false end
 local source=tonumber(r.controller_pane)
 if not source or not member(cx,source,host,session) or not member(cx,bridge,host,session) then return false end
 local bytes=read_node(cx,source,'orchplus.orchestrator','dispatch-action-'..r.action_id,'orchplus.dispatch',8192)
 local data=if bytes then Codec.strict_decode(bytes,8192) else nil
 if not data or data.version~=1 or data.source_nonce~=b.alias_nonce or data.host_pane_id~=b.host_pane_id or data.orch_session_id~=b.logical_session_id or data.owner_id~=b.owner_id or data.owner_generation~=b.owner_generation then return false end
 local action=data.action
 if not action or action.action_id~=r.action_id or action.phase~='claimed' or not P.fields(action.claim,{executor=P.id,grant_id=P.id,epoch=function(v)return P.integer(v,1)end}) or action.claim.executor~=b.window_epoch or expected_claim and not P.equal(action.claim,expected_claim) then return false end
 -- Continuation retains immutable requests and old claims for status inspection,
 -- not native authority. The durable route fence must win over those old bytes.
 if action.reconciliation_only~=false or not P.equal(action.execution_origin,b) or action.execution_controller_pane~=r.controller_pane then return false end
 local cursor=data.command_cursor
 if cursor and (not P.equal(cursor.origin,b) or cursor.controller_pane~=r.controller_pane) then return false end
 local request_bytes=read_node(cx,source,'orchplus.orchestrator','dispatch-request-'..r.action_id,'orchplus.request',8192)
 local current=if request_bytes then P.decode(request_bytes) else nil
 return current~=nil and P.equal(current,r),P.clone(action.claim)
end
local function event(cx,pane,r,op,result,claim,key)
 if key and sent[key] or not origin_ok(cx,pane,r,claim) then return false end
 local value=tern.json.encode({request_json=tern.json.encode(r),executor_id=executor,result=result,orch_claim=claim})
 if #value>65536 then return false end
 -- Only submission consumes a control marker. Missing evidence before this
 -- boundary can recover on a later observation; a throwing event is ambiguous.
 if key then mark(r,key) end
 cx.session:event(pane,{ev='action',id='main.spawn-dispatch-response',act='spawn.'..op,value=value})
 return origin_ok(cx,pane,r,claim)
end
local function native_idle(cx,pane_binding,r)
 if not P.pane(pane_binding) or pane_binding.window_key~=r.origin_binding.window_key or pane_binding.window_epoch~=r.origin_binding.window_epoch or pane_binding.native_session_id~=r.origin_binding.native_session_id or pane_binding.window_host_id~=r.origin_binding.window_host_id then return false end
 local pane=tonumber(pane_binding.pane_id)
 if not member(cx,pane,cx.hosts:current(),cx.sessions:current()) then return false end
 local recognized=pcall(function()cx.agents:get(pane)end)
 if not recognized then return false end
 for _,agent in ipairs(cx.agents:list()) do
  if agent.pane==pane then return agent.state=='idle' and (agent.delivery_error==nil or agent.delivery_error==tern.json.null) end
 end
 return false
end
local function authorize(cx,pane,projection)
 local r=projection.request
 if not r or not P.decode(tern.json.encode(r)) or not P.id(projection.nonce) then return end
 local granted,claim=origin_ok(cx,pane,r);if not granted then return end
 if r.op=='attach_worker' or r.op=='adopt' then
  local p,b=r.pane_binding,r.origin_binding
  if p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id or not member(cx,tonumber(p.pane_id),cx.hosts:current(),cx.sessions:current()) then return end
 end
 if projection.previous_claim and projection.previous_claim.grant_id==claim.grant_id then return end
 local k='authorize/'..projection.nonce
 if sent[k] then return end
 local value=tern.json.encode({request_json=tern.json.encode(r),nonce=projection.nonce,executor_id=executor,orch_claim=claim})
 if #value>65536 or not origin_ok(cx,pane,r,claim) then return end
 mark(r,k)
 cx.session:event(pane,{ev='action',id='main.spawn-dispatch-response',act='spawn.authorize',value=value})
end
local function wake(cx,pane,projection)
 local r=projection.request
 if not r or r.op~='native_wake' or not P.decode(tern.json.encode(r)) or not projection.orch_claim or not origin_ok(cx,pane,r,projection.orch_claim) then return end
 local k=r.origin_binding.logical_session_id..'/'..r.request_id..'/wake/'..projection.orch_claim.grant_id
 local p,b=projection.pane_binding,r.origin_binding
 if not P.pane(p) or p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id or sent[k..'/defer'] then return end
 if not native_idle(cx,projection.pane_binding,r) then
  if not sent[k..'/effect'] and not sent[k..'/defer'] and (not projection.claim or projection.claim.executor_id==executor) then
   event(cx,pane,r,'wakedefer',nil,projection.orch_claim,k..'/defer')
  end
  return
 end
 if projection.phase=='resolved' and not projection.claim then
  event(cx,pane,r,'wakeclaim',nil,projection.orch_claim,k..'/claim')
  return
 end
 if not projection.claim or projection.claim.executor_id~=executor then return end
 if projection.phase=='claimed' then
  event(cx,pane,r,'wakebegin',nil,projection.orch_claim,k..'/begin')
  return
 end
 if projection.phase~='launching' or sent[k..'/effect'] then return end
 if not origin_ok(cx,pane,r,projection.orch_claim) then return end
 if not native_idle(cx,projection.pane_binding,r) then
  event(cx,pane,r,'wakedefer',nil,projection.orch_claim,k..'/defer')
  return
 end
 mark(r,k..'/effect')
 local ok=pcall(function()
  cx.agents:ask(tonumber(projection.pane_binding.pane_id),'Drain receipts in your already provisioned report-files-v1 mailbox using your durable producer journal first. Then consume the next complete immutable reply, if any, using your durable consumer journal. Validate the exact action/enrolment before recording reply_ack. An ACK-only notification needs no new reply, heartbeat or synthetic ACK; this wake is not receipt or permission for an unrelated effect.')
 end)
 if origin_ok(cx,pane,r,projection.orch_claim) then event(cx,pane,r,'wakeresult',{status=if ok then 'submitted' else 'uncertain'},projection.orch_claim) end
end
local function execute(cx,pane,projection)
 local r=projection.request
 if not r or r.op~='launch' or not P.decode(tern.json.encode(r)) or not projection.orch_claim or not origin_ok(cx,pane,r,projection.orch_claim) then return end
 local k=r.origin_binding.logical_session_id..'/'..r.request_id
 if projection.phase=='resolved' and not projection.claim then
  event(cx,pane,r,'claim',nil,projection.orch_claim,k..'/claim')
  return
 end
 local claim=projection.claim
 if not claim or claim.executor_id~=executor then return end
 if projection.phase=='claimed' then
  event(cx,pane,r,'begin',nil,projection.orch_claim,k..'/begin')
  return
 end
 if projection.phase~='launching' or sent[k..'/effect'] then return end
 local launch=projection.launch
 if type(launch)~='table' or type(launch.command)~='string' or type(launch.cwd)~='string' or launch.placement~=r.placement then return end
 if launch.backend=='native-agent' and (type(launch.prompt)~='string' or not launch.prompt:find('%S')) then return end
 if not origin_ok(cx,pane,r,projection.orch_claim) then return end
 -- Validate first, then mark BEFORE native invocation: a throw may be an effect.
 mark(r,k..'/effect')
 local ok,created=pcall(function()
  if launch.backend=='native-agent' then
   return cx.agents:start({command=launch.command,prompt=launch.prompt,cwd=launch.cwd,how=launch.placement})
  end
  local options={command=launch.command,cwd=launch.cwd}
  if launch.placement=='split' then return cx.layout:split(tonumber(r.controller_pane),'right',options,{focus=true}) end
  -- Managed terminal placement was validated by the shared backend before claim.
  return cx.layout:new_tab(options,{focus=true})
 end)
 if not origin_ok(cx,pane,r,projection.orch_claim) then return end
 local result
 if ok and type(created)=='number' and member(cx,created,cx.hosts:current(),cx.sessions:current()) then
  result={status='submitted',pane_binding={pane_id=tostring(created),window_epoch=r.origin_binding.window_epoch,window_key=r.origin_binding.window_key,native_session_id=r.origin_binding.native_session_id,window_host_id=r.origin_binding.window_host_id}}
 else result={status='uncertain',message='Native launch may have occurred; inspect the recorded claim before recovery'} end
 event(cx,pane,r,'result',result,projection.orch_claim)
end
-- Explicit verified attach: deliver the exact preface + assignment once to the attested existing
-- native agent pane. Never starts an agent and never types into a terminal or shell.
local function adopt(cx,pane,projection)
 local r=projection.request
 if not r or r.op~='adopt' or not P.decode(tern.json.encode(r)) or not projection.orch_claim or not origin_ok(cx,pane,r,projection.orch_claim) then return end
 local k=r.origin_binding.logical_session_id..'/'..r.request_id..'/adopt'
 if projection.phase=='resolved' and not projection.claim then
  event(cx,pane,r,'claim',nil,projection.orch_claim,k..'/claim')
  return
 end
 local claim=projection.claim
 if not claim or claim.executor_id~=executor then return end
 if projection.phase=='claimed' then
  event(cx,pane,r,'begin',nil,projection.orch_claim,k..'/begin')
  return
 end
 if projection.phase~='launching' or sent[k..'/effect'] or sent[k..'/result'] then return end
 if type(projection.prompt)~='string' or not projection.prompt:find('%S') then return end
 if not origin_ok(cx,pane,r,projection.orch_claim) then return end
 -- Pre-effect refusal: a busy, unrecognized (non-agent) or out-of-scope pane receives nothing.
 if not native_idle(cx,r.pane_binding,r) then
  event(cx,pane,r,'result',{status='refused',message='Target pane is not an idle native agent in the exact window, session and host; nothing was sent'},projection.orch_claim,k..'/result')
  return
 end
 -- Validate first, then mark BEFORE native invocation: a throw may be an effect.
 mark(r,k..'/effect')
 local ok=pcall(function() cx.agents:ask(tonumber(r.pane_binding.pane_id),projection.prompt) end)
 if not origin_ok(cx,pane,r,projection.orch_claim) then return end
 event(cx,pane,r,'result',if ok then {status='submitted',pane_binding=P.clone(r.pane_binding)} else {status='uncertain',message='Native ask may have been delivered; never repeat it'},projection.orch_claim,k..'/result')
end
local stopping={}
local function stop(cx,pane,projection)
 local r=projection.request
 if not r or r.op~='stop' or not P.decode(tern.json.encode(r)) or not projection.orch_claim or not origin_ok(cx,pane,r,projection.orch_claim) then return end
 local p=r.pane_binding;local b=r.origin_binding
 if p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id then return end
 local k=b.logical_session_id..'/'..r.request_id..'/stop'
 if projection.phase=='resolved' and not projection.claim then
  event(cx,pane,r,'claim',nil,projection.orch_claim,k..'/claim')
  return
 end
 if not projection.claim or projection.claim.executor_id~=executor then return end
 if projection.phase=='claimed' then
  event(cx,pane,r,'begin',nil,projection.orch_claim,k..'/begin')
  return
 end
 if projection.phase~='launching' or sent[k..'/result'] then return end
 local target=tonumber(p.pane_id)
 local function uncertain(message)
  stopping[k]=nil
  event(cx,pane,r,'result',{status='uncertain',message=message},projection.orch_claim,k..'/result')
 end
 if not sent[k..'/effect'] then
  if not member(cx,target,cx.hosts:current(),cx.sessions:current()) then uncertain('Recorded pane is absent, parked or outside the exact session before stop; retain ownership');return end
  local info=cx.session:pane(target)
  local recognized,agent=pcall(function()return cx.agents:get(target)end)
  local native=recognized and agent~=nil and agent.pane==target
  if not native and (projection.backend~='local-terminal' and projection.backend~='ssh-command' or not info or info.kind~='terminal') then uncertain('Native agent recognition or enrolled terminal pane-close prerequisite is unavailable; retain ownership');return end
  if not origin_ok(cx,pane,r,projection.orch_claim) or not member(cx,target,cx.hosts:current(),cx.sessions:current()) then return end
  -- Recognition and exact-origin checks precede the effect marker. A submitted
  -- pre-effect rejection uses /result instead and cannot later execute.
  mark(r,k..'/effect')
  stopping[k]={turns=0,native=native}
  local ok=pcall(function()
   if native then cx.agents:stop(target) else cx.layout:close(target) end
  end)
  if not ok then uncertain('Native stop/close may have executed but returned an error; do not repeat it');return end
 end
 local pending=stopping[k];if not pending then return end
 if not origin_ok(cx,pane,r,projection.orch_claim) then return end
 if pending.turns>=20 then uncertain('Native stop observation repeatedly failed; retain ownership and do not repeat the effect');return end
 pending.turns+=1
 local info=cx.session:pane(target);local observation=nil
 if not info then
  local listed=false;for _,id in ipairs(cx.hosts:current().panes) do if id==target then listed=true end end
  if not listed then observation='absent' end
 elseif member(cx,target,cx.hosts:current(),cx.sessions:current()) then
  if type(info.exited)=='number' then observation='exited'
  elseif pending.native then
   for _,agent in ipairs(cx.agents:list()) do if agent.pane==target and agent.state=='exited' then observation='exited';break end end
  end
 end
 if observation then
  stopping[k]=nil
  event(cx,pane,r,'result',{status='stopped',pane_binding=p,observation=observation},projection.orch_claim,k..'/result')
 elseif pending.turns>=20 then uncertain('Native stop/close has no fresh exact-window exit or absence observation; do not repeat it') end
end
local function prune(cx)
 if #group_order==0 then return end
 group_cursor=group_cursor%#group_order+1
 local g=group_order[group_cursor];local entry=groups[g];local b=entry.binding
 local source=tonumber(entry.source)
 local bytes=if source then read_node(cx,source,'orchplus.orchestrator','dispatch-action-'..entry.action_id,'orchplus.dispatch',8192) else nil
 local data=if bytes then Codec.strict_decode(bytes,8192) else nil
 if not data or data.version~=1 or data.source_nonce~=b.alias_nonce or data.orch_session_id~=b.logical_session_id or type(data.action)~='table' or data.action.action_id~=entry.action_id then return end
 if data.action.phase~='complete' and data.action.phase~='resolved' then return end
 for key in pairs(entry.keys) do sent[key]=nil end
 stopping[g..'/stop']=nil
 groups[g]=nil;table.remove(group_order,group_cursor);group_cursor-=1
end
local function tick(cx)
 if not cx then return end
 local host=cx.hosts:current();local session=cx.sessions:current()
 if not host or not session or host.state~='connected' then return end
 local visited=0
 for _,pane in ipairs(cx.session:panes()) do
  if pane.block~='spawn.dispatch' or not member(cx,pane.pane,host,session) then continue end
  visited+=1;if visited>32 then break end
  local bytes=read_node(cx,pane.pane,'spawn.dispatch','spawn-dispatch-execution','spawn.dispatch.execution',65536)
  if bytes and bytes:sub(1,19)=='SPAWN_EXECUTION v1 ' then
   local projection=Codec.strict_decode(bytes:sub(20),65536)
   if projection and projection.schema==1 then
    if projection.kind=='authorize' then authorize(cx,pane.pane,projection) elseif projection.kind=='wake' then wake(cx,pane.pane,projection) elseif projection.kind=='stop' then stop(cx,pane.pane,projection) elseif projection.kind=='adopt' then adopt(cx,pane.pane,projection) else execute(cx,pane.pane,projection) end
   end
  end
 end
 prune(cx)
end
function M.start()
 if timer then return end
 local function turn(cx)
  -- Rearm before work (as ORCH+ arm() does): a tick that trips the 50 ms
  -- window budget aborts this callback, and a rearm placed after the work
  -- would end every later authorization, claim and result observation.
  timer=tern.timer(250,turn)
  pcall(tick,cx)
  -- Later observations may deliver unsent controls, never repeat invoked effects.
 end
 timer=tern.timer(250,turn)
end
M.origin_ok=origin_ok
M.read_node=read_node
-- Diagnostic: markers and stop observations this window VM still retains.
function M.retained()
 local markers,watching=0,0
 for _ in pairs(sent) do markers+=1 end
 for _ in pairs(stopping) do watching+=1 end
 return {markers=markers,stopping=watching,requests=#group_order}
end
return M
