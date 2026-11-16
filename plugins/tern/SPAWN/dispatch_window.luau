-- Window-only executor. Recreated VMs get new IDs and cannot reuse old claims.
local P=require('./bridge_protocol')
local Codec=require('./wire/codec')
local Native=require('./native_cli')
local WindowJournal=require('./window_journal')
local M={}
local executor=string.format('spawn-%d-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647))
local sent={}
-- Markers survive missing actions and lost ACKs. Only a fresh current-control consumed
-- observation reconstructed by ORCH from peer outstanding work releases a group.
local groups,group_order,group_cursor={},{},0
local function mark(r,key,revision)
 sent[key]=true
 local g=r.origin_binding.logical_session_id..'/'..r.request_id
 local entry=groups[g]
 if not entry then entry={request=P.clone(r),keys={}};groups[g]=entry;table.insert(group_order,g) end
 entry.last_authority_revision=math.max(entry.last_authority_revision or 0,revision or 0)
 entry.keys[key]=true
 return entry
end
local timer=nil
-- Bounded focus guards, keyed by the pane a managed launch created. A native agent tab can take
-- focus after agents:start returns (on macOS once its composer is ready), so the one immediate
-- check misses it. For 5 s each tick restores `previous` at most once, and only while focus sits
-- on the created pane; focus seen on any other pane (the operator moved) drops the guard.
-- Focus is presentation only: guards never touch launch markers or results.
local GUARD_MS,GUARD_CAP=5000,32
local focus_guards,guard_order={},{}
local function unguard(created)
 focus_guards[created]=nil
 for i,id in ipairs(guard_order) do if id==created then table.remove(guard_order,i);break end end
end
local function guard_focus(created,previous)
 -- Back-to-back launches: focus on an earlier guarded pane returns to that guard's controller.
 local earlier=focus_guards[previous]
 if earlier then previous=earlier.previous end
 unguard(created)
 local guard={previous=previous,deadline=tern.now()+GUARD_MS}
 focus_guards[created]=guard;table.insert(guard_order,created)
 while #guard_order>GUARD_CAP do focus_guards[table.remove(guard_order,1)]=nil end
 return guard
end
local function check_focus(cx)
 if #guard_order==0 then return end
 local now=tern.now();local focused=cx.session:focused()
 for _,created in ipairs(table.clone(guard_order)) do
  local guard=focus_guards[created]
  if not guard then continue end
  if now>guard.deadline then unguard(created)
  elseif focused==created then
   unguard(created)
   pcall(cx.layout.focus,cx.layout,guard.previous)
   focused=cx.session:focused()
  elseif focused~=nil and focused~=guard.previous and not focus_guards[focused] then
   -- A third pane that no managed launch created: the operator chose it; never steal it back.
   unguard(created)
  end
 end
end
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
-- Numeric pane reads/events/agent operations address every session in this window.
-- Resolve the recorded native context from SDK membership, not user selection.
local function pane_context(cx,pane,binding)
 local info=cx.session:pane(pane)
 if not info or info.parked or not info.tab then return nil end
 for _,host in ipairs(cx.hosts:list()) do
  if host.state~='connected' or not table.find(host.panes,pane) then continue end
  for _,session in ipairs(cx.sessions:list()) do
   if session.host~=host.id or binding and (binding.window_key~=cx:window_key()
    or tostring(host.id)~=binding.window_host_id or tostring(session.id)~=binding.native_session_id) then continue end
   if member(cx,pane,host,session) then return host,session end
  end
 end
 return nil
end
local function bound_member(cx,pane,binding)
 return pane_context(cx,pane,binding)~=nil
end
-- The genuine ORCH panel is an explicit same-user relay, never a SPAWN surface.
-- Carrier persistence is not native authority: each use re-observes this panel,
-- its source incarnation and the unchanged peer execution bytes.
local relay_projections=setmetatable({},{__mode='k'})
local function relay_token(value,limit)
 return type(value)=='string' and #value>0 and #value<=limit and value:match('^[A-Za-z0-9_.%-]+$')~=nil
end
local function relay_metadata(cx,pane,host,session)
 if not member(cx,pane,host,session) then return nil end
 local bytes=read_node(cx,pane,'orchplus.orchestrator','orchplus-spawn-relay','orchplus.spawn-relay',65536)
 local data,_,shapes=Codec.strict_decode(bytes or '',65536)
 local function object(v)return type(v)=='table' and shapes[v]=='object'end
 local function list(v,limit)
  return type(v)=='table' and #v<=limit and (shapes[v]=='array' or object(v) and next(v)==nil)
 end
 if not object(data) or not P.fields(data,{
  schema=function(v)return v==1 end,peer=function(v)return v=='spawn' end,
  host_pane_id=function(v)return P.text(v,32,false) and v:match('^%d+$')~=nil end,
  source_nonce=function(v)return P.text(v,256,false)end,
  relay_endpoint=function(v)return relay_token(v,24)end,relay_boot=function(v)return relay_token(v,64)end,
  lanes=function(v)return list(v,32)end,releases=function(v)return list(v,32)end,
 },{held=function(v)return type(v)=='boolean'end,error=function(v)return relay_token(v,128)end}) or #data.lanes+#data.releases>32 then return nil end
 local released={}
 for _,release in ipairs(data.releases) do
  if not object(release) or not P.fields(release,{lane_id=function(v)return relay_token(v,24)end,peer_boot=function(v)return relay_token(v,64)end})
   or released[release.lane_id] then return nil end
  released[release.lane_id]=true
 end
 local seen,count={},0
 for index,lane in pairs(data.lanes) do
  count+=1
  if not P.integer(index,1) or index>#data.lanes or not object(lane) or not P.fields(lane,{
   lane_id=function(v)return relay_token(v,24)end,messages=object,
  },{peer_boot=function(v)return relay_token(v,64)end,error=function(v)return relay_token(v,128)end,held=function(v)return type(v)=='boolean'end,
   bind_id=function(v)return type(v)=='string' and #v>0 and #v<=80 and v:match('^[A-Za-z0-9_.:%-]+$')~=nil end,
   release_held=function(v)return type(v)=='boolean'end}) or seen[lane.lane_id] or released[lane.lane_id] then return nil end
  seen[lane.lane_id]=true
  for kind,proof in pairs(lane.messages) do
   if kind~='execution' and kind~='response' and kind~='current' and kind~='control' and kind~='catalog' then return nil end
   if not object(proof) or not P.fields(proof,{
    id=function(v)return type(v)=='string' and #v>0 and #v<=80 and v:match('^[A-Za-z0-9_.:%-]+$')~=nil end,
    incarnation=function(v)return relay_token(v,64) and v==lane.peer_boot end,
    route=function(v)return v=='spawn.'..kind end,
    binding=function(v)return v==data.relay_endpoint..':'..lane.lane_id end,
   }) then return nil end
  end
 end
 if count~=#data.lanes then return nil end
 return data
end
local function relay_member(cx,pane,host,session,origin,controller,alias,projection)
 if controller and tostring(pane)~=controller then return false end
 local data=relay_metadata(cx,pane,host,session)
 if not data or origin and (data.host_pane_id~=origin.host_pane_id or data.source_nonce~=(alias or origin.alias_nonce)) then return false end
 local relay=projection and relay_projections[projection]
 if projection and not relay then return false end
 if relay then
  if relay.pane~=pane or data.source_nonce~=relay.source_nonce or data.host_pane_id~=relay.host_pane_id
   or data.relay_endpoint~=relay.relay_endpoint or data.relay_boot~=relay.relay_boot then return false end
  local found=false
  for _,lane in ipairs(data.lanes) do
   if lane.lane_id==relay.lane.lane_id then
    if found or lane.peer_boot~=relay.lane.peer_boot or lane.bind_id~=relay.lane.bind_id
     or not P.equal(lane.messages.execution,relay.lane.messages.execution) then return false end
    found=true
   end
  end
  if not found then return false end
  local bytes=read_node(cx,pane,'orchplus.orchestrator','spawn-relay-'..relay.lane.lane_id..'-execution','orchplus.spawn-execution',65536)
  if bytes~=relay.bytes then return false end
 end
 return true
end
local function execution_receipt(projection)
 local relay=relay_projections[projection]
 local proof=relay and relay.lane.messages.execution
 return if proof then {id=proof.id,incarnation=proof.incarnation} else nil
end
local function relay_event(cx,pane,projection,act,bytes,key,revision,delivery)
 local relay=relay_projections[projection]
 local host,session=pane_context(cx,pane)
 if not relay or not host or not session or host.state~='connected'
  or not relay_member(cx,pane,host,session,nil,nil,nil,projection) then return false end
 local value=if delivery and delivery.envelope then delivery.envelope else tern.json.encode({schema=1,source_nonce=relay.source_nonce,relay_endpoint=relay.relay_endpoint,relay_boot=relay.relay_boot,lane_id=relay.lane.lane_id,peer_boot=relay.lane.peer_boot,act=act,bytes=bytes})
 if #value>65536 then return false end
 if delivery then delivery.envelope=value end
 -- Mark only after final source/projection validation; a throwing send is ambiguous.
 if key then mark(projection.request,key,revision) end
 cx.session:event(pane,{ev='action',id='main.orchplus-spawn-relay',act='spawn_relay',value=value})
 return true
end
-- Explicit Config administration is separate from managed admission and setup catalog.
-- Only a directed click grants this VM one observation; reloads never adopt a
-- published challenge. HOST owns migration writes and its native session identity.
local migration_attempts,migration_consents={},{}
local function migration_challenge(cx,pane)
 local bytes=read_node(cx,pane,'spawn.spawner','spawn-managed-migration','spawn.managed.migration',8192)
 local challenge=if bytes then Codec.strict_decode(bytes,8192) else nil
 if not P.fields(challenge,{
  schema=function(v)return v==1 end,nonce=P.id,
  operation=function(v)return v=='inspect' or v=='prepare' or v=='finish' end,
  native_window=function(v)return P.text(v,256,true) end,
  native_conn=function(v)return P.integer(v,0) end,native_since=function(v)return P.integer(v,0) end,
  native_session=function(v)return P.integer(v,1) end,
  native_namespace=function(v)return P.text(v,128,false) end,window_consent=P.id,
  host_pane_id=function(v)return type(v)=='string' and #v<=32 and v:match('^%d+$')~=nil end,
  expected=function(v)return type(v)=='table' end,
 }) then return nil end
 return challenge,bytes
end
local function migration_recipient(cx,binding,hooks)
 local recipient=hooks.recipient()
 return type(recipient)=='table' and recipient.namespace==binding.namespace and recipient.window_key==binding.window_key
  and cx:window_key()==binding.window_key and recipient.conn==binding.conn and recipient.since==binding.since
end
local function migration_origin(cx,pane,request,hooks)
 local current=hooks.capture(cx)
 return current and current.host==request.origin.host and current.session==request.origin.session
  and hooks.member(cx,request.origin,pane) and request.binding and migration_recipient(cx,request.binding,hooks)
end
local function migration_projection(bytes)
 local data,_,shapes=Codec.strict_decode(bytes or '',65536)
 if not data or shapes[data]~='object' or not P.fields(data,{
  protocol=function(v)return v==2 end,
  phase=function(v)return v=='legacy' or v=='prepared' or v=='stable'end,
  source_nonce=function(v)return P.text(v,256,false)end,
  host_pane_id=function(v)return P.text(v,32,false) and v:match('^%d+$')~=nil end,
  authority_revision=function(v)return P.integer(v,0)end,source_sha256=P.digest,
  qualification=function(v)return Codec.validate_dispatch_migration_qualification(v,'orch',shapes)end,
 },{authority_namespace=function(v)return P.text(v,128,false)end,compatibility=function(v)return type(v)=='table'end,result=function(v)return type(v)=='table'end}) then return nil end
 local proof=data.qualification.proof
 if proof.source_revision~=data.authority_revision or proof.source_sha256~=data.source_sha256
  or data.authority_namespace~=nil and data.authority_namespace~=proof.candidate_namespace then return nil end
 return data
end
local function migration_peer(cx,origin,hooks)
 local source=nil
 for _,pane in ipairs(cx.session:panes()) do
  if pane.block~='orchplus.orchestrator' or not hooks.member(cx,origin,pane.pane) then continue end
  if source then return nil end
  source=pane.pane
 end
 if not source then return nil end
 local bytes=read_node(cx,source,'orchplus.orchestrator','migration-state','orchplus.migration',65536)
 if not bytes then return nil end
 local data,_,shapes=Codec.strict_decode(bytes,65536)
 local index_bytes=read_node(cx,source,'orchplus.orchestrator','setup-index','orchplus.setup',65536)
 local index=if index_bytes then Codec.strict_decode(index_bytes,65536) else nil
 if not data or data.protocol~=2 or (data.phase~='legacy' and data.phase~='prepared' and data.phase~='stable') or not P.text(data.source_nonce,256,false) or not P.text(data.host_pane_id,32,false) or not P.integer(data.authority_revision,0) or not P.digest(data.source_sha256) then return nil end
 if not index or index.version~=1 or index.host_pane_id~=data.host_pane_id or index.source_nonce~=data.source_nonce then return nil end
 if data.authority_namespace~=nil and not P.text(data.authority_namespace,128,false) then return nil end
 local qualification=data.qualification
 if not Codec.validate_dispatch_migration_qualification(qualification,'orch',shapes) or qualification.proof.source_revision~=data.authority_revision or qualification.proof.source_sha256~=data.source_sha256 then return nil end
 if not P.fields(data,{protocol=true,phase=true,source_nonce=true,host_pane_id=true,authority_revision=true,source_sha256=true,qualification=true},{authority_namespace=true,compatibility=function(v)return type(v)=='table' end,result=function(v)return type(v)=='table' end}) then return nil end
 return data,bytes,source
end
function M.observe_migration(cx,pane,hooks)
 local request=migration_consents[pane]
 if not request or not request.binding then return end
 if tern.now()>request.deadline or not migration_origin(cx,pane,request,hooks) then
  migration_consents[pane]=nil;migration_attempts[pane]=nil;return
 end
 local challenge,bytes=migration_challenge(cx,pane)
 if not challenge or challenge.nonce~=request.nonce or challenge.operation~=request.operation
  or challenge.host_pane_id~=request.host_pane_id or challenge.window_consent~=request.token
  or challenge.native_namespace~=request.binding.namespace or challenge.native_window~=request.binding.window_key
  or challenge.native_conn~=request.binding.conn or challenge.native_since~=request.binding.since then return end
 local prior=migration_attempts[pane]
 if prior and (prior.submitted or prior.bytes==bytes) then return end
 local attempt={bytes=bytes};migration_attempts[pane]=attempt
 local started=pcall(function()
  Native.inspect(challenge.native_window,{timeout_ms=5000},function(result,problem,fresh)
   if migration_attempts[pane]~=attempt or migration_consents[pane]~=request then return end
   -- Failed read-only observations may be observed again; submitted admin callbacks
   -- stay marked for this consent, including a throwing send.
   migration_attempts[pane]=nil
   if problem or not fresh or tern.now()>request.deadline then return end
   local incarnation=WindowJournal.incarnation(challenge.native_window,result)
   if not incarnation or incarnation.conn~=challenge.native_conn or incarnation.since~=challenge.native_since or not migration_origin(fresh,pane,request,hooks) then return end
   local _,current=migration_challenge(fresh,pane);if current~=bytes then return end
   local peer,peer_bytes,source=migration_peer(fresh,request.origin,hooks);if not peer then return end
   local repeated,repeated_bytes,repeated_source=migration_peer(fresh,request.origin,hooks)
   if not repeated or repeated_bytes~=peer_bytes or repeated_source~=source then return end
   local _,final=migration_challenge(fresh,pane)
   if final~=bytes or not migration_origin(fresh,pane,request,hooks) then return end
   local value=tern.json.encode({intent_id=challenge.nonce,operation=challenge.operation,native_window={window_key=incarnation.window_key,conn=incarnation.conn,since=incarnation.since},native_namespace=challenge.native_namespace,window_consent=request.token,local_source=challenge.expected,peer_qualification=repeated})
   if #value>65536 then return end
   attempt.submitted=true;migration_attempts[pane]=attempt
   fresh.session:event(pane,{ev='action',id='main',act='spawn.migration-result',value=value})
  end)
 end)
 if not started and migration_attempts[pane]==attempt and not attempt.submitted then migration_attempts[pane]=nil end
end
function M.consent_migration(cx,link,hooks)
 if type(link.url)~='string' or not link.url:match('^tern%-spawn://managed%-migration/') then return nil end
 local host,operation,nonce=link.url:match('^tern%-spawn://managed%-migration/(%d+)/(%a+)/([%w_%-]+)$')
 local source=link.pane
 if not host or #host>32 or not P.integer(tonumber(host),1) or not P.id(nonce)
  or (operation~='inspect' and operation~='prepare' and operation~='finish') or not P.integer(source,1) then
  cx:toast('error','SPAWN','The migration request is invalid; no migration was started.');return {handled=true}
 end
 local prior=migration_consents[source]
 if prior and prior.nonce==nonce then return {handled=true} end
 local origin=hooks.capture(cx)
 if not origin or not hooks.member(cx,origin,source) then return {handled=true} end
 local request={nonce=nonce,operation=operation,host_pane_id=host,origin=origin,deadline=tern.now()+30000,
  token=string.format('consent-%d-%08x-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647))}
 migration_consents[source]=request;migration_attempts[source]=nil
 hooks.ensure(cx,function(fresh,err)
  if migration_consents[source]~=request then return end
  local current=if fresh then hooks.capture(fresh) else nil
  local recipient=hooks.recipient()
  if err or not current or current.host~=origin.host or current.session~=origin.session or not hooks.member(fresh,origin,source)
   or type(recipient)~='table' or not P.text(recipient.namespace,128,false) or not P.text(recipient.window_key,256,true)
   or not P.integer(recipient.conn,0) or not P.integer(recipient.since,0) or recipient.window_key~=fresh:window_key() or tern.now()>request.deadline then
   migration_consents[source]=nil
   if fresh then fresh:toast('error','SPAWN',err or 'The clicked window changed; no migration was started.') end
   return
  end
  request.binding={namespace=recipient.namespace,window_key=recipient.window_key,conn=recipient.conn,since=recipient.since}
  local sent,why=pcall(function()
   fresh.session:event(source,{ev='action',id='main',act='managed-migration-consent',value=tern.json.encode({nonce=nonce,operation=operation,window=recipient.window_key,native_namespace=recipient.namespace,native_conn=recipient.conn,native_since=recipient.since,window_consent=request.token})})
  end)
  if not sent then
   migration_consents[source]=nil;fresh:toast('error','SPAWN','Migration consent could not be delivered: '..tostring(why));return
  end
  M.observe_migration(fresh,source,hooks)
 end)
 return {handled=true}
end
local function setup_origin_ok(cx,relay_pane,r,projection)
 local b=r.setup_origin;local host=cx.hosts:current();local session=cx.sessions:current()
 if not b or not host or not session or host.state~='connected' or tostring(host.id)~=b.window_host_id or tostring(session.id)~=b.native_session_id or session.host~=host.id or cx:window_key()~=b.window_key then return false end
 local source,source_nonce=nil,nil;local visited=0
 for _,pane in ipairs(cx.session:panes()) do
  if pane.block~='orchplus.orchestrator' or not member(cx,pane.pane,host,session) then continue end
  visited+=1;if visited>32 then return false end
  local bytes=read_node(cx,pane.pane,'orchplus.orchestrator','setup-index','orchplus.setup',65536)
  local index=if bytes then Codec.strict_decode(bytes,65536) else nil
  if not index or index.version~=1 or index.host_pane_id~=b.host_pane_id then continue end
  local request_bytes=read_node(cx,pane.pane,'orchplus.orchestrator','setup-catalog-request','orchplus.setup.request',8192)
  local current=if request_bytes then P.decode(request_bytes) else nil
  if current and P.equal(current,r) and (projection.kind~='migration' or request_bytes==projection.request_json) then
   if source then return false end
   source=pane.pane;source_nonce=index.source_nonce
  end
 end
 return source~=nil and relay_member(cx,relay_pane,host,session,b,tostring(source),source_nonce,projection)
end
local function setup_catalog(cx,pane,projection)
 local r=projection.request
 if not r or not P.id(projection.observation_id) or not P.decode(tern.json.encode(r)) or not r.setup_origin or not setup_origin_ok(cx,pane,r,projection) then return end
 -- A repeated observation only repeats a read. No execution markers, owner or grant exist.
 relay_event(cx,pane,projection,'spawn.setup_catalog',tern.json.encode({request_json=tern.json.encode(r),observation_id=projection.observation_id,relay_execution=execution_receipt(projection)}))
end
-- Bootstrap witnesses the actual Create result and current native controller,
-- not a relay-authored substitute for ORCH's ownership surfaces.
local function bootstrap_witness(cx,pane,r,creation,relay)
 if not P.bootstrap_creation(creation) or creation.source_nonce~=relay.source_nonce then return false end
 local function node(key,role)
  local bytes=read_node(cx,pane,'orchplus.orchestrator',key,role,65536)
  local value,_,shapes=Codec.strict_decode(bytes or '',65536)
  return value,bytes,shapes
 end
 local result,result_bytes,rs=node('orchestration-result','orchplus.orchestration.result')
 local alias,alias_bytes,als=node('ownership-alias','orchplus.alias')
 local dispatch,dispatch_bytes,ds=node('dispatch-state','orchplus.dispatch')
 local function object(v,shapes)return type(v)=='table' and shapes[v]=='object'end
 local function natural(v)return P.integer(v,0)end
 local function positive(v)return P.integer(v,1)end
 if not object(result,rs) or not P.fields(result,{
  ok=function(v)return v==true end,code=function(v)return v=='controller_granted'end,
  request_id=P.id,orch_session_id=P.id,owner_id=P.id,generation=positive,revision=positive,
  execution_epoch=positive,message=function(v)return P.text(v,1000,false)end,
  owner=function(v)return object(v,rs)end,
 }) then return false end
 local owner=result.owner
 if not P.fields(owner,{owner_id=P.id,generation=positive,phase=function(v)return v=='active'end,
  owner_active=function(v)return v==true end,created_at_ms=natural,pending_executors=function(v)return v==0 end,
  pending_executor_evidence=function(v)return v=='observed'end,pane_binding=function(v)return object(v,rs)end})
  or not P.fields(owner.pane_binding,{host_pane_id=function(v)return v==r.setup_origin.host_pane_id end,
   alias_nonce=function(v)return v==creation.source_nonce end}) then return false end
 if not object(alias,als) or not P.fields(alias,{
  version=function(v)return v==2 end,authority_version=function(v)return v==5 end,
  authority_namespace=function(v)return v==creation.authority_namespace end,revision=natural,
  alias_nonce=function(v)return v==creation.source_nonce end,host_pane_id=function(v)return v==r.setup_origin.host_pane_id end,
  orch_session_id=function(v)return v==creation.orch_session_id end,session_closed=function(v)return v==false end,
  config_open=function(v)return type(v)=='boolean'end,owners=function(v)return object(v,als)end,
 }) then return false end
 local controller=alias.owners.controller
 if not object(controller,als) or not P.fields(controller,{
  owner_id=function(v)return v==creation.owner_id end,generation=function(v)return v==creation.generation end,
  alias_nonce=function(v)return v==creation.source_nonce end,
 }) then return false end
 if not object(dispatch,ds) or dispatch.version~=2 or dispatch.authority_version~=5
  or dispatch.authority_namespace~=creation.authority_namespace or dispatch.orch_session_id~=creation.orch_session_id
  or dispatch.source_nonce~=creation.source_nonce or dispatch.host_pane_id~=r.setup_origin.host_pane_id
  or dispatch.owner_id~=creation.owner_id or dispatch.owner_generation~=creation.generation or dispatch.controller_phase~='active'
  or not natural(dispatch.revision) or dispatch.revision~=alias.revision or dispatch.authority_revision~=alias.revision
  or result.revision>alias.revision
  or not object(dispatch.session_control,ds) or dispatch.session_control.admitted~=nil then return false end
 if result.request_id~=creation.request_id or result.orch_session_id~=creation.orch_session_id
  or result.owner_id~=creation.owner_id or result.generation~=creation.generation
  or owner.owner_id~=creation.owner_id or owner.generation~=creation.generation then return false end
 return read_node(cx,pane,'orchplus.orchestrator','orchestration-result','orchplus.orchestration.result',65536)==result_bytes
  and read_node(cx,pane,'orchplus.orchestrator','ownership-alias','orchplus.alias',65536)==alias_bytes
  and read_node(cx,pane,'orchplus.orchestrator','dispatch-state','orchplus.dispatch',65536)==dispatch_bytes
end
-- This is a native witness only. SPAWN HOST owns nonce consumption and the
-- deadline clock; observing this projection never grants a native effect.
local function migration(cx,pane,projection)
 if not P.fields(projection,{
  schema=function(v)return v==2 end,kind=function(v)return v=='migration'end,
  request=function(v)return type(v)=='table'end,request_json=function(v)return type(v)=='string' and #v<=8192 end,
  operation=function(v)return v=='source' or v=='bootstrap' or v=='inspect' or v=='prepare' or v=='finish'end,
  nonce=P.id,boot=P.id,deadline=function(v)return type(v)=='number' and v>=0 and v<math.huge end,
 },{expected=function(v)return type(v)=='table'end,peer=function(v)return type(v)=='table'end,creation=P.bootstrap_creation}) then return end
 local r=P.decode(projection.request_json)
 local relay=relay_projections[projection]
 if not r or not r.setup_origin or not P.equal(r,projection.request) or not relay
  or projection.boot~=relay.lane.peer_boot or not setup_origin_ok(cx,pane,r,projection) then return end
 local peer=nil
 if projection.operation=='source' then
  if projection.expected~=nil or projection.peer~=nil or projection.creation~=nil then return end
 elseif projection.operation=='bootstrap' then
  if projection.expected~=nil or projection.peer~=nil or not bootstrap_witness(cx,pane,r,projection.creation,relay) then return end
 else
  if not projection.expected or not projection.peer or projection.creation~=nil then return end
  local bytes=read_node(cx,pane,'orchplus.orchestrator','migration-state','orchplus.migration',65536)
  peer=migration_projection(bytes)
  if not peer or peer.source_nonce~=relay.source_nonce or peer.host_pane_id~=relay.host_pane_id
   or not P.equal(peer,projection.peer)
   or not Codec.validate_dispatch_compatibility({schema=1,kind='migration',orch=peer.qualification.proof,spawn=projection.expected}) then return end
  local repeated=read_node(cx,pane,'orchplus.orchestrator','migration-state','orchplus.migration',65536)
  if repeated~=bytes or not migration_projection(repeated) then return end
 end
 if not setup_origin_ok(cx,pane,r,projection) then return end
 relay_event(cx,pane,projection,'spawn.migration',tern.json.encode({
  request_json=projection.request_json,nonce=projection.nonce,executor_id=executor,
  relay_execution=execution_receipt(projection),peer=peer,creation=projection.creation,
 }))
end
local function origin_ok(cx,pane,r,expected_claim,projection,native_claim)
 if r.setup_origin or not projection or type(projection.request_json)~='string' or not P.integer(projection.last_authority_revision,0) then return false end
 local b=r.origin_binding
 if not b then return false end
 local host,session=pane_context(cx,tonumber(r.controller_pane),b)
 if not host or not session then return false end
 local source=tonumber(r.controller_pane)
 if not source or not member(cx,source,host,session) or not relay_member(cx,pane,host,session,b,r.controller_pane,nil,projection) then return false end
 local bytes=read_node(cx,source,'orchplus.orchestrator','dispatch-action-'..r.action_id,'orchplus.dispatch',8192)
 local data=if bytes then Codec.strict_decode(bytes,8192) else nil
 if not data or data.version~=2 or data.source_nonce~=b.alias_nonce or data.host_pane_id~=b.host_pane_id
  or data.orch_session_id~=b.logical_session_id or data.owner_id~=b.owner_id or data.owner_generation~=b.owner_generation then return false end
 local published=data.action
 if type(published)~='table' then return false end
 -- UI-only fields stay on the native node, outside the closed canonical proof.
 local action={authority_namespace=published.authority_namespace,authority_revision=published.authority_revision,logical_session_id=published.logical_session_id,admission_seq=published.admission_seq,request_serial=published.request_serial,action_id=published.action_id,request_sha256=published.request_sha256,phase=published.phase,reconciliation_only=published.reconciliation_only,execution_origin=published.execution_origin,execution_controller_pane=published.execution_controller_pane,claim=published.claim}
 if not Codec.validate_dispatch_projection(action,r,projection.request_json,projection.last_authority_revision,expected_claim,native_claim) then return false end
 if native_claim and (native_claim.executor_id~=executor or native_claim.boot~=projection.boot) then return false end
 local cursor=data.command_cursor
 if not cursor or not P.equal(cursor.origin,b) or cursor.controller_pane~=r.controller_pane then return false end
 local request_bytes=read_node(cx,source,'orchplus.orchestrator','dispatch-request-'..r.action_id,'orchplus.request',8192)
 if request_bytes~=projection.request_json then return false end
 local group=groups[r.logical_session_id..'/'..r.request_id]
 if group then group.last_authority_revision=math.max(group.last_authority_revision,action.authority_revision) end
 return true,P.clone(action.claim),action,data.result
end
local function event(cx,pane,projection,op,result,claim,key,post_effect)
 local r=projection.request
 if key and sent[key] then return false end
 local ok,_,proof=origin_ok(cx,pane,r,claim,projection,projection.claim)
 if not ok then return false end
 local value=tern.json.encode({request_json=projection.request_json,executor_id=executor,authorization_nonce=projection.nonce,result=result,orch_claim=claim,proof=proof,spawn_claim=projection.claim,relay_execution=execution_receipt(projection)})
 if #value>65536 then return false end
 local delivery=nil
 if post_effect then
  -- Retain the final native outcome or read-only exit observation before submission:
  -- a returned/throwing native event says nothing about carrier backpressure.
  local group=groups[r.origin_binding.logical_session_id..'/'..r.request_id]
  if not group then return false end
  if group.delivery then return false end
  delivery={pane=pane,projection=projection,act='spawn.'..op,bytes=value,next_retry=tern.now()+1000}
  group.delivery=delivery
 end
 if not relay_event(cx,pane,projection,'spawn.'..op,value,key,proof.authority_revision,delivery) then return false end
 return origin_ok(cx,pane,r,claim,projection,projection.claim)
end
local function retry_result(cx,pane,projection)
 local r=projection.request
 local group=r and r.origin_binding and groups[r.origin_binding.logical_session_id..'/'..r.request_id]
 local delivery=group and group.delivery
 if not delivery or projection.phase~='launching' then return false end
 -- Never refresh a callback's proof, receipt or nonce, and never turn its retry
 -- into a new begin. A new VM has no retained result or matching executor.
 local original=delivery.projection
 -- Session progress is not execution identity. All other execution fields,
 -- including nonce, deadline, base grant and native claim, must remain identical.
 local same=true
 for key,value in pairs(original) do
  if key~='last_authority_revision' and not P.equal(value,projection[key]) then same=false;break end
 end
 for key in pairs(projection) do if key~='last_authority_revision' and original[key]==nil then same=false;break end end
 local previous,current=relay_projections[original],relay_projections[projection]
 if not same or pane~=delivery.pane or not previous or not current
  or previous.source_nonce~=current.source_nonce or previous.host_pane_id~=current.host_pane_id
  or previous.relay_endpoint~=current.relay_endpoint or previous.relay_boot~=current.relay_boot
  or previous.lane.lane_id~=current.lane.lane_id or previous.lane.peer_boot~=current.lane.peer_boot
  or previous.lane.bind_id~=current.lane.bind_id
  or not P.equal(previous.lane.messages.execution,current.lane.messages.execution) then return true end
 if tern.now()<delivery.next_retry then return true end
 if not Codec.validate_spawn_claim(projection.claim,true) or projection.claim.executor_id~=executor
  or projection.claim.boot~=projection.boot or not origin_ok(cx,pane,r,original.orch_claim,projection,original.claim) then return true end
 delivery.next_retry=tern.now()+1000
 relay_event(cx,pane,projection,delivery.act,delivery.bytes,nil,nil,delivery)
 return true
end
local function peer_claim(cx,pane,projection)
 local r,native=projection.request,projection.claim
 if not Codec.validate_spawn_claim(native,true) or native.executor_id~=executor or native.boot~=projection.boot then return false end
 local ok,claim,proof,receipt=origin_ok(cx,pane,r,projection.orch_claim,projection)
 if not ok then return false end
 local group_id=r.logical_session_id..'/'..r.request_id
 local group=groups[group_id]
 if claim.spawn_claim and claim.spawn_claim.spawn_namespace==native.spawn_namespace and claim.spawn_claim.claim_nonce==native.claim_nonce then
  if group then group.witness=nil end
  return true
 end
 local key=group_id..'/peer/'..native.claim_nonce
 if sent[key] then
  local pending=group and group.witness
  if not pending or pending.key~=key or pending.grant_id~=claim.grant_id or proof.authority_revision<=pending.revision
   or not receipt or receipt.ok~=false or receipt.command~='spawn_claimed' or receipt.code~='stale_revision' or receipt.request_id~=pending.request_id
   or receipt.action_id~=r.action_id or receipt.grant_id~=claim.grant_id then return false end
 end
 -- A lost witness stays held. Only its exact no-write stale refusal permits a new
 -- observation of the still-current tuple; the old intent is never refreshed or replayed.
 local command={kind='dispatch',command='spawn_claimed',request_id='witness-'..Codec.sha256(native.claim_nonce..':'..string.format('%.0f',proof.authority_revision)),orch_session_id=r.logical_session_id,origin=r.origin_binding,controller_pane=r.controller_pane,authority_namespace=proof.authority_namespace,expected_revision=proof.authority_revision,action_id=r.action_id,grant_id=claim.grant_id,spawn_namespace=native.spawn_namespace,claim_nonce=native.claim_nonce}
 local fresh,_,current=origin_ok(cx,pane,r,projection.orch_claim,projection)
 if not fresh or current.authority_revision~=proof.authority_revision then return false end
 group=mark(r,key,proof.authority_revision)
 group.witness={key=key,request_id=command.request_id,grant_id=claim.grant_id,revision=proof.authority_revision}
 cx.session:event(tonumber(r.controller_pane),{ev='action',id='main.dispatch-state',act='dispatch-command',value=tern.json.encode(command)})
 return false
end
local function native_idle(cx,pane_binding,r)
 if not P.pane(pane_binding) or pane_binding.window_key~=r.origin_binding.window_key or pane_binding.window_epoch~=r.origin_binding.window_epoch or pane_binding.native_session_id~=r.origin_binding.native_session_id or pane_binding.window_host_id~=r.origin_binding.window_host_id then return false end
 local pane=tonumber(pane_binding.pane_id)
 if not bound_member(cx,pane,pane_binding) then return false end
 local recognized,agent=pcall(function()return cx.agents:get(pane)end)
 if not recognized or not agent or agent.pane~=pane then return false end
 for _,agent in ipairs(cx.agents:list()) do
  if agent.pane==pane then
   local ready=agent.delivery_error==nil or agent.delivery_error==tern.json.null
   return ready and agent.state=='idle',ready and (agent.state=='working' or agent.state=='waiting_input')
  end
 end
 return false
end
-- Read only the exact captured native window/session. Missing from one surface is
-- not absence: both the pane lookup and connected host membership must agree.
-- This is shared by ordinary stop completion and failed-startup authorization.
local function native_exit(cx,p,check_agents)
 if not P.pane(p) or cx:window_key()~=p.window_key then return nil end
 local host,session
 for _,candidate in ipairs(cx.hosts:list()) do if tostring(candidate.id)==p.window_host_id and candidate.state=='connected' then host=candidate;break end end
 for _,candidate in ipairs(cx.sessions:list()) do if tostring(candidate.id)==p.native_session_id and host and candidate.host==host.id then session=candidate;break end end
 if not host or not session then return nil end
 local target=tonumber(p.pane_id);local info=cx.session:pane(target)
 if not info then
  if not table.find(host.panes,target) then return 'absent' end
 elseif member(cx,target,host,session) then
  if type(info.exited)=='number' then return 'exited' end
  if check_agents then
   for _,agent in ipairs(cx.agents:list()) do if agent.pane==target and agent.state=='exited' then return 'exited' end end
  end
 end
 return nil
end
local function authorize(cx,pane,projection)
 local r=projection.request
 if not r or not P.decode(tern.json.encode(r)) or not P.id(projection.nonce) then return end
 local granted,claim=origin_ok(cx,pane,r,nil,projection);if not granted then return end
 if r.op=='attach_worker' or r.op=='adopt' or r.op=='enrol' then
  local p,b=r.pane_binding,r.origin_binding
  if p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id or not bound_member(cx,tonumber(p.pane_id),b) then return end
  if r.op=='attach_worker' and r.attestation=='same_native_conversation_no_pending_effects' then
   local previous=r.previous_pane_binding
   if previous.pane_id~=p.pane_id or previous.native_session_id~=p.native_session_id or previous.window_key~=p.window_key or previous.window_host_id~=p.window_host_id then return end
   local recognized=false
   local ok=pcall(function()
    local agent=cx.agents:get(tonumber(p.pane_id))
    if agent then
     for _,item in ipairs(cx.agents:list()) do if item.pane==tonumber(p.pane_id) then recognized=true end end
    end
   end)
   if not ok or not recognized then return end
  end
  if r.op=='attach_worker' and r.attestation=='same_terminal_process_no_pending_effects' then
   local previous=r.previous_pane_binding
   if previous.pane_id~=p.pane_id or previous.native_session_id~=p.native_session_id or previous.window_key~=p.window_key or previous.window_host_id~=p.window_host_id then return end
   local info=cx.session:pane(tonumber(p.pane_id))
   if not info or (info.kind~='terminal' and info.kind~='agent') or info.exited~=nil and info.exited~=tern.json.null or info.at_prompt==true then return end
  end
 end
 local startup=projection.startup_cleanup;local observed=nil
 if startup~=nil then
  if r.op~='mailbox_retire' or r.mode~='retire' or not P.fields(startup,{pane_binding=P.pane,backend=function(v)return v=='native-agent' or v=='local-terminal'end}) then return end
  local p,b=startup.pane_binding,r.origin_binding
  if p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id then return end
  observed=native_exit(cx,p,true)
  if not observed or p.window_epoch~=b.window_epoch and observed~='absent' then return end
  -- Across a continued epoch, only genuine absence can settle the original pane.
  -- An existing target may have been restored, even when it currently says exited.
 end
 if projection.previous_claim and projection.previous_claim.grant_id==claim.grant_id then return end
 local k='authorize/'..projection.nonce
 if sent[k] then return end
 local fresh,_,proof=origin_ok(cx,pane,r,claim,projection)
 if not fresh then return end
 if startup and native_exit(cx,startup.pane_binding,true)~=observed then return end
 local value=tern.json.encode({request_json=projection.request_json,nonce=projection.nonce,executor_id=executor,orch_claim=claim,proof=proof,
  native_observation=if startup then {pane_binding=P.clone(startup.pane_binding),observation=observed} else nil,relay_execution=execution_receipt(projection)})
 if #value>65536 then return end
 relay_event(cx,pane,projection,'spawn.authorize',value,k,proof.authority_revision)
end
local function control_peer(cx,pane,projection,pruning)
 local r=projection.request
 if not r or type(projection.request_json)~='string' then return nil end
 local decoded=P.decode(projection.request_json)
 if not decoded or not P.equal(decoded,r) or not r.control_origin then return nil end
 local origin=r.control_origin;local b=origin.binding
 local host,session=pane_context(cx,tonumber(origin.controller_pane),b)
 local source=tonumber(origin.controller_pane)
 if not host or not session or host.state~='connected' or session.host~=host.id or tostring(host.id)~=b.window_host_id or tostring(session.id)~=b.native_session_id or cx:window_key()~=b.window_key or not source or not member(cx,source,host,session) or not relay_member(cx,pane,host,session,b,origin.controller_pane,nil,if pruning then nil else projection) then return nil end
 local migration=r.compatibility.kind=='migration'
 local bytes=read_node(cx,source,'orchplus.orchestrator','dispatch-state','orchplus.dispatch',65536)
 if not bytes then return nil end
 local data,_,shapes=Codec.strict_decode(bytes,65536)
 local prepared=migration and (r.op=='admit_session' or r.op=='reconcile_session')
 if not data or data.protocol~=2 or (data.phase~='stable' and not (prepared and data.phase=='prepared')) or data.authority_namespace~=r.authority_namespace or data.authority_revision~=r.authority_revision or type(data.control)~='table' or data.control.request_bytes~=projection.request_json or not P.equal(data.control.request,r) then return nil end
 local native=if type(data.sessions)=='table' then data.sessions[r.logical_session_id] else nil
 if not native or native.admission_seq~=r.admission_seq or not Codec.validate_dispatch_control(native.control) then return nil end
 local expected=if r.compatibility.kind=='current' then r.compatibility.spawn_namespace else r.compatibility.spawn.candidate_namespace
 if data.spawn_namespace~=expected then return nil end
 local control=native.control
 if control.generation_floor~=r.generation_floor or control.next_request_serial~=r.next_request_serial or control.request_floor~=r.settled_before or control.last_authority_revision>data.authority_revision then return nil end
 if origin.kind=='active' then
  if not P.equal(control.binding,b) or control.phase~='open' and r.op~='close_session' then return nil end
 elseif r.op~='close_session' or control.phase~='closing' or control.close_id~=origin.close_id or control.close_id~=r.close_id then return nil end
 local peer={protocol=2,phase=data.phase,authority_namespace=data.authority_namespace,authority_revision=data.authority_revision,spawn_namespace=data.spawn_namespace,session={admission_seq=native.admission_seq,control=P.clone(control)}}
 if migration then
  if not P.equal(data.compatibility,r.compatibility) or not Codec.validate_dispatch_migration_selection(data.managed_selection,shapes) then return nil end
  peer.compatibility=data.compatibility
  peer.managed_selection=data.managed_selection
 end
 return peer
end
local function control_authorize(cx,pane,projection)
 if not P.id(projection.nonce) then return end
 local peer=control_peer(cx,pane,projection);if not peer then return end
 -- Repeated delivery is only a nonce-bound control observation, never an effect.
 local fresh=control_peer(cx,pane,projection);if not fresh or not P.equal(fresh,peer) then return end
 local value=tern.json.encode({request_json=projection.request_json,nonce=projection.nonce,executor_id=executor,peer=fresh,relay_execution=execution_receipt(projection)})
 if #value>65536 then return end
 relay_event(cx,pane,projection,'spawn.control_authorize',value)
end
local function wake(cx,pane,projection)
 local r=projection.request
 if not r or r.op~='native_wake' or not P.decode(tern.json.encode(r)) or not projection.orch_claim or not origin_ok(cx,pane,r,projection.orch_claim,projection) then return end
 local k=r.origin_binding.logical_session_id..'/'..r.request_id..'/wake/'..projection.orch_claim.grant_id
 local p,b=projection.pane_binding,r.origin_binding
 if not P.pane(p) or p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id or sent[k..'/defer'] then return end
 if projection.phase=='claimed' and not peer_claim(cx,pane,projection) then return end
 if not native_idle(cx,projection.pane_binding,r) then
  if not sent[k..'/effect'] and not sent[k..'/defer'] and (not projection.claim or projection.claim.executor_id==executor) then
   event(cx,pane,projection,'wakedefer',nil,projection.orch_claim,k..'/defer')
  end
  return
 end
 if projection.phase=='resolved' and not projection.claim then
  event(cx,pane,projection,'wakeclaim',nil,projection.orch_claim,k..'/claim')
  return
 end
 if not Codec.validate_spawn_claim(projection.claim,true) or projection.claim.executor_id~=executor or projection.claim.boot~=projection.boot then return end
 if projection.phase=='claimed' then
  event(cx,pane,projection,'wakebegin',nil,projection.orch_claim,k..'/begin')
  return
 end
 if projection.phase~='launching' or sent[k..'/effect'] then return end
 if not origin_ok(cx,pane,r,projection.orch_claim,projection,projection.claim) then return end
 if not native_idle(cx,projection.pane_binding,r) then
  event(cx,pane,projection,'wakedefer',nil,projection.orch_claim,k..'/defer')
  return
 end
 mark(r,k..'/effect')
 local ok=pcall(function()
  cx.agents:ask(tonumber(projection.pane_binding.pane_id),'Drain receipts in your already provisioned report-files-v1 mailbox using your durable producer journal first. Then consume the next complete immutable reply, if any, using your durable consumer journal. Validate the exact action/enrolment before recording reply_ack. If the producer journal confirms ACCEPTED acknowledged, continue any pending work in your original authorized assignment; do not wait for an extra assignment reply. Wait for coordinator_activation ONLY if your original transport preface explicitly includes COORDINATOR TRANSPORT ROLE; a coordinator-control-v1 capability alone does not confer that role. Other workers must not wait for coordinator activation. Review work still requires its review_request; landing and deployment still require their exact typed grants. An ACK-only notification needs no new reply, heartbeat or synthetic ACK; this wake is not receipt or permission for an unrelated effect. Return idle only when awaiting future control.')
 end)
 if origin_ok(cx,pane,r,projection.orch_claim,projection,projection.claim) then event(cx,pane,projection,'wakeresult',{status=if ok then 'submitted' else 'uncertain'},projection.orch_claim,nil,true) end
end
local function execute(cx,pane,projection)
 local r=projection.request
 if not r or r.op~='launch' or not P.decode(tern.json.encode(r)) or not projection.orch_claim or not origin_ok(cx,pane,r,projection.orch_claim,projection) then return end
 local k=r.origin_binding.logical_session_id..'/'..r.request_id
 local launch=projection.launch
 if type(launch)~='table' or type(launch.command)~='string' or type(launch.cwd)~='string' or launch.cwd~=r.cwd or launch.placement~=r.placement then return end
 if launch.backend=='native-agent' and (type(launch.prompt)~='string' or not launch.prompt:find('%S')) then return end
 -- Installed SDK agents:start/new_tab have no target-session option, and CLI new
 -- only starts terminal commands. Do not approximate native creation or switch focus.
 local current_host,current_session=cx.hosts:current(),cx.sessions:current()
 if (launch.backend=='native-agent' or launch.placement~='split' or r.presentation=='user_new_tab')
  and (tostring(current_host.id)~=r.origin_binding.window_host_id or tostring(current_session.id)~=r.origin_binding.native_session_id) then
  local group=groups[k]
  if not group or not group.launch_hold then
   group=mark(r,k..'/targeted-launch-hold',projection.last_authority_revision);group.launch_hold=true
   cx.session:event(tonumber(r.controller_pane),{ev='action',id='main.dispatch-state',act='dispatch-notice',value=tern.json.encode({
    source_nonce=r.origin_binding.alias_nonce,level='error',code='targeted_native_launch_unavailable',
    message='Launch needs a targeted native agent API. This SDK cannot create the authorized conversation in a nonselected session without changing focus. The exact grant remains held; no native launch was invoked.',
   })})
  end
  return
 end
 if projection.phase=='resolved' and not projection.claim then
  event(cx,pane,projection,'claim',nil,projection.orch_claim,k..'/claim')
  return
 end
 local claim=projection.claim
 if not Codec.validate_spawn_claim(projection.claim,true) or projection.claim.executor_id~=executor or projection.claim.boot~=projection.boot then return end
 if projection.phase=='claimed' then
  if not peer_claim(cx,pane,projection) then return end
  event(cx,pane,projection,'begin',nil,projection.orch_claim,k..'/begin')
  return
 end
 if projection.phase~='launching' or sent[k..'/effect'] then return end
 if not origin_ok(cx,pane,r,projection.orch_claim,projection,projection.claim) then return end
 -- Only a deliberate new-conversation launch keeps focus. Adjacent coordinators are
 -- moved by ORCH after creation; background launches preserve the user's current pane.
 local foreground=r.presentation=='user_new_tab'
 local focused=if not foreground then cx.session:focused() else nil
 -- Validate first, then mark BEFORE native invocation: a throw may be an effect.
 mark(r,k..'/effect')
 local ok,created=pcall(function()
  if launch.backend=='native-agent' then
   return cx.agents:start({command=launch.command,prompt=launch.prompt,cwd=launch.cwd,how=launch.placement})
  end
  local options={command=launch.command,cwd=launch.cwd}
  if launch.placement=='split' then return cx.layout:split(tonumber(r.controller_pane),'right',options,{focus=foreground}) end
  return cx.layout:new_tab(options,{focus=foreground})
 end)
 if foreground and ok and type(created)=='number' then
  pcall(function() if cx.session:focused()~=created then cx.layout:focus(created) end end)
 end
 if ok and type(created)=='number' and focused~=nil and focused~=created then
  -- Focus is presentation only; a failure here must never change the launch result.
  -- The guard stays after a successful immediate restore: late focus can still arrive.
  pcall(guard_focus,created,focused)
  local previous=if focus_guards[created] then focus_guards[created].previous else focused
  pcall(function()if cx.session:focused()==created then cx.layout:focus(previous) end end)
 end
 if not origin_ok(cx,pane,r,projection.orch_claim,projection,projection.claim) then return end
 local result
 if ok and type(created)=='number' and bound_member(cx,created,r.origin_binding) then
  result={status='submitted',pane_binding={pane_id=tostring(created),window_epoch=r.origin_binding.window_epoch,window_key=r.origin_binding.window_key,native_session_id=r.origin_binding.native_session_id,window_host_id=r.origin_binding.window_host_id}}
 else result={status='uncertain',message='Native launch may have occurred; inspect the recorded claim before recovery'} end
 event(cx,pane,projection,'result',result,projection.orch_claim,nil,true)
end
-- Existing conversation delivery is once-only: native idle ask or explicit clipboard copy.
-- Neither path starts an agent, injects PTY input, or replaces the conversation's task.
local function adopt(cx,pane,projection)
 local r=projection.request
 if not r or (r.op~='adopt' and r.op~='enrol') or not P.decode(tern.json.encode(r)) or not projection.orch_claim or not origin_ok(cx,pane,r,projection.orch_claim,projection) then return end
 local k=r.origin_binding.logical_session_id..'/'..r.request_id..'/'..r.op
 if projection.phase=='resolved' and not projection.claim then
  event(cx,pane,projection,'claim',nil,projection.orch_claim,k..'/claim')
  return
 end
 local claim=projection.claim
 if not Codec.validate_spawn_claim(projection.claim,true) or projection.claim.executor_id~=executor or projection.claim.boot~=projection.boot then return end
 if projection.phase=='claimed' then
  if not peer_claim(cx,pane,projection) then return end
  event(cx,pane,projection,'begin',nil,projection.orch_claim,k..'/begin')
  return
 end
 if projection.phase~='launching' or sent[k..'/effect'] or sent[k..'/result'] then return end
 if type(projection.prompt)~='string' or not projection.prompt:find('%S') then return end
 if not origin_ok(cx,pane,r,projection.orch_claim,projection,projection.claim) then return end
 local clipboard=r.op=='enrol' and r.delivery=='clipboard'
 local target,b=r.pane_binding,r.origin_binding
 if target.window_epoch~=b.window_epoch or target.window_key~=b.window_key or target.native_session_id~=b.native_session_id or target.window_host_id~=b.window_host_id or not bound_member(cx,tonumber(target.pane_id),b) then return end
 if clipboard and (tostring(cx.hosts:current().id)~=b.window_host_id or tostring(cx.sessions:current().id)~=b.native_session_id) then return end
 if clipboard then
  local info=cx.session:pane(tonumber(target.pane_id))
  if not info or (info.kind~='terminal' and info.kind~='agent') or info.exited~=nil and info.exited~=tern.json.null then
   event(cx,pane,projection,'result',{status='refused',message='Select a running terminal conversation in this window; nothing was copied'},projection.orch_claim,k..'/result')
   return
  end
 else
  local idle,waiting=native_idle(cx,target,r)
  if not idle then
   -- Enrollment never types into a busy composer: the same untouched intent waits for idle.
   if r.op=='enrol' and waiting then return end
   event(cx,pane,projection,'result',{status='refused',message='Target pane is not a supported idle native agent in this window; nothing was sent'},projection.orch_claim,k..'/result')
   return
  end
 end
 -- Mark before invocation: either API may throw after taking effect. Never copy/send again.
 mark(r,k..'/effect')
 local ok=pcall(function()
  if clipboard then cx:copy(projection.prompt) else cx.agents:ask(tonumber(target.pane_id),projection.prompt) end
 end)
 if not origin_ok(cx,pane,r,projection.orch_claim,projection,projection.claim) then return end
 event(cx,pane,projection,'result',if ok then {status=if clipboard then 'copied' else 'submitted',pane_binding=P.clone(target)} else {status='uncertain',message='Enrollment delivery may have occurred; never repeat it'},projection.orch_claim,k..'/result',true)
end
local stopping={}
local function stop(cx,pane,projection)
 local r=projection.request
 if not r or r.op~='stop' or not P.decode(tern.json.encode(r)) or not projection.orch_claim or not origin_ok(cx,pane,r,projection.orch_claim,projection) then return end
 local p=r.pane_binding;local b=r.origin_binding
 if p.window_epoch~=b.window_epoch or p.window_key~=b.window_key or p.native_session_id~=b.native_session_id or p.window_host_id~=b.window_host_id then return end
 local k=b.logical_session_id..'/'..r.request_id..'/stop'
 if projection.phase=='resolved' and not projection.claim then
  event(cx,pane,projection,'claim',nil,projection.orch_claim,k..'/claim')
  return
 end
 if not Codec.validate_spawn_claim(projection.claim,true) or projection.claim.executor_id~=executor or projection.claim.boot~=projection.boot then return end
 if projection.phase=='claimed' then
  if not peer_claim(cx,pane,projection) then return end
  event(cx,pane,projection,'begin',nil,projection.orch_claim,k..'/begin')
  return
 end
 if projection.phase~='launching' or sent[k..'/result'] then return end
 local target=tonumber(p.pane_id)
 local function uncertain(message)
  stopping[k]=nil
  event(cx,pane,projection,'result',{status='uncertain',message=message},projection.orch_claim,k..'/result',sent[k..'/effect']==true)
 end
 if not sent[k..'/effect'] then
  local known_backend=projection.backend=='native-agent' or projection.backend=='local-terminal' or projection.backend=='ssh-command'
  local observed=if known_backend then native_exit(cx,p,projection.backend=='native-agent') else nil
  if observed then
   if not origin_ok(cx,pane,r,projection.orch_claim,projection,projection.claim)
    or native_exit(cx,p,projection.backend=='native-agent')~=observed then return end
   -- Positive exact exit/absence is already the desired outcome. Deliver that
   -- observation on the original claim without invoking or marking a native stop.
   event(cx,pane,projection,'result',{status='stopped',pane_binding=p,observation=observed},projection.orch_claim,k..'/result',true)
   return
  end
  if not bound_member(cx,target,b) then uncertain('Recorded pane is absent, parked or outside the exact session before stop; retain ownership');return end
  local info=cx.session:pane(target)
  local recognized,agent=pcall(function()return cx.agents:get(target)end)
  local native=recognized and agent~=nil and agent.pane==target
  if not native and (projection.backend~='local-terminal' and projection.backend~='ssh-command' or not info or (info.kind~='terminal' and info.kind~='agent')) then uncertain('Native agent recognition or enrolled terminal pane-close prerequisite is unavailable; retain ownership');return end
  -- Busy/unknown native input is not permission to interrupt a conversation. Keep
  -- this exact stop authorization pending until fresh idle or positive exit proof.
  if native and not native_idle(cx,p,r) and native_exit(cx,p,true)==nil then return end
  if not origin_ok(cx,pane,r,projection.orch_claim,projection,projection.claim) or not bound_member(cx,target,b) then return end
  if native and not native_idle(cx,p,r) and native_exit(cx,p,true)==nil then return end
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
 if not origin_ok(cx,pane,r,projection.orch_claim,projection,projection.claim) then return end
 if pending.turns>=20 then uncertain('Native stop observation repeatedly failed; retain ownership and do not repeat the effect');return end
 pending.turns+=1
 local observation=native_exit(cx,p,pending.native)
 if observation then
  stopping[k]=nil
  event(cx,pane,projection,'result',{status='stopped',pane_binding=p,observation=observation},projection.orch_claim,k..'/result',true)
 elseif pending.turns>=20 then uncertain('Native stop/close has no fresh exact-window exit or absence observation; do not repeat it') end
end
local function prune(cx)
 if #group_order==0 then return end
 group_cursor=group_cursor%#group_order+1
 local g=group_order[group_cursor];local entry=groups[g];local r=entry.request
 local source=tonumber(r.controller_pane)
 local bytes=if source then read_node(cx,source,'orchplus.orchestrator','dispatch-state','orchplus.dispatch',65536) else nil
 local data=if bytes then Codec.strict_decode(bytes,65536) else nil
 local pending=if data and type(data.control)=='table' then data.control else nil
 if not pending or not pending.request or pending.request.authority_namespace~=r.authority_namespace or pending.request.logical_session_id~=r.logical_session_id or pending.request.admission_seq~=r.admission_seq then return end
 local peer=control_peer(cx,source,{request=pending.request,request_json=pending.request_bytes},true)
 if not peer or peer.authority_revision<entry.last_authority_revision then return end
 -- Consume the whole bounded ACK page while it is positively visible, not one
 -- marker per tick (the next peer page may already have reclaimed these results).
 local consumed={}
 for _,serial in ipairs(pending.request.consumed) do consumed[serial]=true end
 for i=#group_order,1,-1 do
  local key=group_order[i];local current=groups[key];local request=current.request
  if request.authority_namespace==r.authority_namespace and request.logical_session_id==r.logical_session_id and request.admission_seq==r.admission_seq and (consumed[request.request_serial] or request.request_serial<pending.request.settled_before) and peer.authority_revision>=current.last_authority_revision then
   for marker in pairs(current.keys) do sent[marker]=nil end
   stopping[key..'/stop']=nil;groups[key]=nil;table.remove(group_order,i)
  end
 end
 group_cursor=math.min(group_cursor,#group_order)
end
local function ordering_only(state)
 return not state.held and not state.error or state.error=='callback_pending'
end
local function callback_available(metadata,lane,projection)
 if not metadata.held and not metadata.error and not lane.held and not lane.error then return true end
 -- Ordering backpressure can outlive the view that advertised it. Only native
 -- observations may drain it, using the exact current lane execution receipt;
 -- it is never permission to claim, begin or invoke a different/new effect.
 if projection.kind~='setup_catalog' and projection.kind~='control_authorize' and projection.kind~='authorize' then return false end
 return ordering_only(metadata) and ordering_only(lane)
end
local function tick(cx)
 if not cx then return end
 -- Guards expire on their own deadline whatever the host state; a throw never blocks dispatch.
 pcall(check_focus,cx)
 local visited,panels=0,0
 for _,pane in ipairs(cx.session:panes()) do
  if pane.block~='orchplus.orchestrator' then continue end
  panels+=1;if panels>32 then break end
  local host,session=pane_context(cx,pane.pane)
  if not host or not session then continue end
  local metadata=relay_metadata(cx,pane.pane,host,session)
  if not metadata then continue end
  for _,lane in ipairs(metadata.lanes) do
   visited+=1;if visited>64 then break end
   if not lane.peer_boot or not lane.messages.execution then continue end
   local bytes=read_node(cx,pane.pane,'orchplus.orchestrator','spawn-relay-'..lane.lane_id..'-execution','orchplus.spawn-execution',65536)
   if bytes and bytes:sub(1,19)=='SPAWN_EXECUTION v2 ' then
    local projection=Codec.strict_decode(bytes:sub(20),65536)
    if projection and projection.schema==2 then
     relay_projections[projection]={pane=pane.pane,host_pane_id=metadata.host_pane_id,source_nonce=metadata.source_nonce,relay_endpoint=metadata.relay_endpoint,relay_boot=metadata.relay_boot,lane=lane,bytes=bytes}
     if retry_result(cx,pane.pane,projection) then continue end
     if not callback_available(metadata,lane,projection) then continue end
     if projection.kind=='migration' then migration(cx,pane.pane,projection) elseif projection.kind=='setup_catalog' then setup_catalog(cx,pane.pane,projection) elseif projection.kind=='control_authorize' then control_authorize(cx,pane.pane,projection) elseif projection.kind=='authorize' then authorize(cx,pane.pane,projection) elseif projection.kind=='wake' then wake(cx,pane.pane,projection) elseif projection.kind=='stop' then stop(cx,pane.pane,projection) elseif projection.kind=='adopt' or projection.kind=='enrol' then adopt(cx,pane.pane,projection) else execute(cx,pane.pane,projection) end
    end
   end
  end
  if visited>=64 then break end
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
M.setup_origin_ok=setup_origin_ok
M.read_node=read_node
-- Diagnostic: markers and stop observations this window VM still retains.
function M.retained()
 local markers,watching=0,0
 for _ in pairs(sent) do markers+=1 end
 for _ in pairs(stopping) do watching+=1 end
 return {markers=markers,stopping=watching,requests=#group_order}
end
return M
