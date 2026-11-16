-- Native setup diagnostics only. Authority owns the single durable cleanup obligation.
-- This VM retains no durable journal and never replays an interrupted launch.
local Bridge=require('./dispatch_window')
local M={}
local active={}
local pending={}
local closed_preparation={} -- Once-only handoff tombstone, never a replayable consent.
local function recipient_matches(cx,route,hooks)
 local recipient=hooks.recipient()
 return type(recipient)=='table' and type(route.native_namespace)=='string' and route.native_namespace==recipient.namespace
  and route.window==cx:window_key() and recipient.window_key==route.window
  and route.native_conn==recipient.conn and route.native_since==recipient.since
end
function M.read(cx,source)
 local bytes=Bridge.read_node(cx,source,'spawn.spawner','spawn-managed-route','spawn.managed.route',100000)
 if not bytes then return nil end
 local ok,route=pcall(tern.json.decode,bytes)
 if not ok or type(route)~='table' or route.schema~=1 or type(route.nonce)~='string' or type(route.command)~='string' or type(route.cwd)~='string' or route.window~=cx:window_key() then return nil end
 return route
end
local function send(cx,source,route,act,pane,err,cleaned)
 cx.session:event(source,{ev='action',id='main',act=act,value=tern.json.encode({nonce=route.nonce,window=route.window,pane=pane or 0,error=err,cleaned=cleaned,native_namespace=route.native_namespace,native_conn=route.native_conn,native_since=route.native_since})})
end
local function native_match(cx,route,origin,hooks)
 local found
 for _,agent in ipairs(cx.agents:list()) do
  if agent.command==route.command then
   if not hooks.member(cx,origin,agent.pane) or found then return nil,'Diagnostic native identity is ambiguous or outside its captured scope' end
   found=agent.pane
  end
 end
 return found,nil
end
local function owned(cx,route,origin,hooks,known,stopped)
 if route.backend=='native-agent' then return native_match(cx,route,origin,hooks) end
 -- HOST verifies exact command/cwd in the execution host's native inventory.
 -- Desktop cwd is presentation data (Windows renders remote POSIX separators).
 local pane=if route.owned_pane and route.owned_pane==route.bound_pane then (route.bound_window_pane or known) else nil
 if pane then
  local info=cx.session:pane(pane)
  if not info and stopped then return nil,nil end
  if not info or not hooks.member(cx,origin,pane) then return nil,'Diagnostic terminal ownership is no longer observable' end
  return pane,nil
 end
 if known and cx.session:pane(known)~=nil then return nil,'Waiting for exact host-observed terminal command ownership' end
 return nil,nil
end
local function drive(cx,source,route,hooks,start,completed)
 if active[route.nonce] then return end
 local origin=hooks.capture(cx)
 if not origin or not recipient_matches(cx,route,hooks) or not hooks.member(cx,origin,source) then return end
 local track={origin=origin,route=route,source=source,pane=route.bound_window_pane,revision=route.config_revision,namespace=route.native_namespace,conn=route.native_conn,since=route.native_since,deadline=tern.now()+45000,cleanup=not start,awaiting_launch=false,stopped=false,held_sent=false,observation_sent=false,error=if start then nil else 'Interrupted diagnostic: cleanup only; no provider turn was replayed'}
 active[route.nonce]=track
 if start then
  track.awaiting_launch=true
  local ok,why=pcall(send,cx,source,route,'managed-route-preflight',nil)
  if not ok then track.awaiting_launch=false;track.cleanup=true;track.error='Native diagnostic preflight could not be requested: '..tostring(why) end
 end
 local function poll(fresh)
  if fresh==nil then active[route.nonce]=nil;return end
  if not recipient_matches(fresh,track.route,hooks) then active[route.nonce]=nil;return end
  local ok,problem=pcall(function()
   local current=M.read(fresh,source)
   if current and current.nonce==route.nonce then
    if not recipient_matches(fresh,current,hooks) then active[route.nonce]=nil;return end
    route=current;track.route=route
    if route.cleanup_pending==false then active[route.nonce]=nil;if completed then completed(fresh,route) end;return end
    if route.cleanup_only or route.status=='failed' then track.cleanup=true;track.error=route.error or track.error or 'Diagnostic cancelled or interrupted' end
    if route.status=='observed' then track.cleanup=true end
   else track.cleanup=true;track.error=track.error or 'Diagnostic source disappeared or changed' end
   if tern.now()>track.deadline then track.cleanup=true;track.error=track.error or 'Native diagnostic exceeded its bounded observation deadline' end
   local source_visible=hooks.member(fresh,origin,source)
   if not source_visible then track.cleanup=true;track.error=track.error or 'Diagnostic Config closed; owned worker cleanup only' end
   if route.cleanup_blocked then
    fresh:toast('error','SPAWN',route.error or 'Native incarnation is unavailable; cleanup obligation preserved')
    active[route.nonce]=nil;return
   end
   if track.awaiting_launch then
    if track.cleanup then track.awaiting_launch=false
    else
     local ready=route.launch_ready
     if type(ready)~='table' then return end
     local current_origin=hooks.capture(fresh)
     if route.config_revision~=track.revision or route.native_namespace~=track.namespace or route.native_conn~=track.conn or route.native_since~=track.since or ready.nonce~=route.nonce or ready.config_revision~=track.revision or ready.native_namespace~=track.namespace or ready.native_conn~=track.conn or ready.native_since~=track.since or not current_origin or current_origin.host~=origin.host or current_origin.session~=origin.session or not source_visible then
      track.awaiting_launch=false;track.cleanup=true;track.error='Native diagnostic incarnation changed before launch; no effect was attempted'
      return
     end
     -- Fresh host membership preflight precedes the single native effect. Never retry it.
     track.awaiting_launch=false
     local launched,created=pcall(function()
      if route.backend=='native-agent' then return fresh.agents:start({command=route.command,prompt=route.prompt,cwd=route.cwd,how='tab'}) end
      return fresh.layout:new_tab({command=route.command,cwd=route.cwd},{focus=false})
     end)
     if launched and type(created)=='number' and created>0 and created%1==0 then
      track.pane=created
      pcall(send,fresh,source,route,'managed-route-started',created)
     else track.cleanup=true;track.error='Native diagnostic start did not return an owned pane: '..tostring(created) end
     return
    end
   end
   local pane,identity_error=owned(fresh,route,origin,hooks,track.pane,track.stopped)
   if identity_error then
    -- A failed/parked/ambiguous observation is a durable hold, never broad cleanup.
    if tern.now()>track.deadline+15000 then fresh:toast('error','SPAWN',identity_error..'; cleanup obligation preserved');active[route.nonce]=nil;return end
    pcall(function() fresh.session:event(source,{ev='action',id='main',act='refresh'}) end)
    return
   end
   if pane then track.pane=pane end
   if pane and (route.bound_window_pane~=pane or route.bound_pane==nil or route.owned_pane~=route.bound_pane) then
    -- A start callback may beat HOST inventory. Retry only its identity report,
    -- never the launch, before observing or stopping the positively found pane.
    if not source_visible then
     fresh:toast('error','SPAWN','Diagnostic HOST ownership is unconfirmed; cleanup obligation preserved')
     active[route.nonce]=nil;return
    end
    send(fresh,source,route,'managed-route-started',pane)
    return
   end
   if track.cleanup then
    if pane then
     if route.backend=='native-agent' then fresh.agents:stop(pane) else fresh.layout:close(pane) end
     track.stopped=true
     return
    end
    if track.pane and fresh.session:pane(track.pane)~=nil then return end
    if not source_visible then active[route.nonce]=nil;return end
    if route.bound_pane==nil or route.bound_window_pane==nil then
     if not track.held_sent then
      send(fresh,source,route,'managed-route-finished',track.pane,track.error or 'Unbound uncertain native start remains held',false)
      track.held_sent=true
     end
     if tern.now()>track.deadline+20000 then active[route.nonce]=nil end
     return
    end
    if not route.discovery_complete then
     fresh.session:event(source,{ev='action',id='main',act='refresh'})
     return
    end
    -- Agents:list absence is observed after stop; the host independently rechecks
    -- its exact native inventory before clearing the authoritative obligation.
    send(fresh,source,route,'managed-route-finished',track.pane,track.error,true)
    if tern.now()>track.deadline+20000 then active[route.nonce]=nil end
    return
   end
   if not pane then return end
   if route.backend=='native-agent' then
    local delivered=hooks.startup(fresh,pane,route.prompt)
    if not delivered then return end
   elseif route.bound_window_pane~=pane or route.owned_pane~=route.bound_pane then return end
   if not track.observation_sent then
    send(fresh,source,route,'managed-route-observed',pane)
    track.observation_sent=true
   end
  end)
  if not ok then track.cleanup=true;track.error='Native diagnostic observation failed: '..tostring(problem):sub(1,512) end
  if active[route.nonce]==track then tern.timer(250,poll) end
 end
 tern.timer(250,poll)
end
local function prepare_read(cx,source)
 local bytes=Bridge.read_node(cx,source,'spawn.spawner','spawn-managed-prepare','spawn.managed.prepare',32000)
 if not bytes then return nil end
 local ok,value=pcall(tern.json.decode,bytes)
 if not ok or type(value)~='table' or value.schema~=1 or type(value.nonce)~='string' or type(value.revision)~='number' or type(value.entries)~='table' or #value.entries<1 or #value.entries>32 or value.window~=cx:window_key() then return nil end
 local seen={}
 for index,entry in ipairs(value.entries) do
  if type(entry)~='table' or type(entry.nonce)~='string' or #entry.nonce>256 or seen[entry.nonce] or type(entry.record_id)~='string' or type(entry.label)~='string' or (entry.backend~='native-agent' and entry.backend~='local-terminal') or type(entry.revision)~='number' or entry.revision%1~=0 then return nil end
  if index==1 then if entry.revision~=value.revision and entry.revision~=value.revision+1 then return nil end
  elseif entry.revision~=value.entries[index-1].revision+1 then return nil end
  seen[entry.nonce]=true
 end
 return value
end
local reviewed_sources={}
function M.cancel_reviewed(captured)
 if not captured then return end
 local request,manifest=captured.request,captured.manifest
 if pending[manifest.nonce]==request then pending[manifest.nonce]=nil end
 for _,entry in ipairs(manifest.entries) do if pending[entry.nonce]==request then pending[entry.nonce]=nil end end
 if reviewed_sources[captured.source]==captured then reviewed_sources[captured.source]=nil end
 captured.used=true
end
function M.capture_reviewed(cx,source,host,records,revision,begin_required,hooks)
 if reviewed_sources[source] then return nil,'Saving and preparation for this approval are already pending' end
 local origin=hooks.capture(cx);local recipient=hooks.recipient()
 if not origin or not hooks.member(cx,origin,source) or type(recipient)~='table' or recipient.window_key~=cx:window_key() or type(recipient.namespace)~='string' then return nil,'The exact clicked native setup window is unavailable; nothing was saved or launched' end
 local nonce=string.format('prepare-%d-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647))
 local manifest={schema=1,nonce=nonce,revision=revision,window=cx:window_key(),status='awaiting_consent',entries={}}
 local request={deadline=tern.now()+30000,index=1,consents={}}
 for _,record in ipairs(records) do
  if record.enabled then
   if record.review_required or record.backend=='ssh-command' then return nil,'Save settings only, then review the execution route/settings before preparation' end
   local index=#manifest.entries+1
   local entry={nonce=nonce..'-'..tostring(index),record_id=record.id,label=record.provider..' — '..record.account_label,backend=record.backend,revision=revision+(if begin_required then 1 else 0)+index-1}
   table.insert(manifest.entries,entry)
   request.consents[index]={nonce=entry.nonce,window_consent=string.format('consent-%d-%08x-%08x-%d',os.time(),math.random(1,2147483647),math.random(1,2147483647),index)}
  end
 end
 if #manifest.entries==0 then return nil,'Enable and review at least one saved agent before preparation' end
 local captured={source=source,host=host,manifest=manifest,request=request,origin=origin,binding={window=recipient.window_key,native_namespace=recipient.namespace,native_conn=recipient.conn,native_since=recipient.since}}
 reviewed_sources[source]=captured;pending[nonce]=request
 for _,entry in ipairs(manifest.entries) do pending[entry.nonce]=request end
 tern.timer(30000,function()if not request.started and pending[nonce]==request and tern.now()>=request.deadline then M.cancel_reviewed(captured) end end)
 return captured,nil
end
local prepare_consent
function M.reviewed_payload(captured)
	local manifest,binding=captured.manifest,captured.binding
	return {nonce=manifest.nonce,revision=manifest.revision,entries=manifest.entries,consents=captured.request.consents,window=binding.window,native_namespace=binding.native_namespace,native_conn=binding.native_conn,native_since=binding.native_since}
end
function M.start_reviewed(cx,captured,reference,hooks)
 if not captured or captured.used or pending[captured.manifest.nonce]~=captured.request or tern.now()>captured.request.deadline then return false,'The reviewed preparation approval expired; settings may be saved, but no checks were started' end
 local current=hooks.capture(cx)
 if not current or current.host~=captured.origin.host or current.session~=captured.origin.session or not hooks.member(cx,captured.origin,captured.source) or not recipient_matches(cx,captured.binding,hooks) then M.cancel_reviewed(captured);return false,'Agents were saved, but the clicked native window/session changed; no preparation or model check was started' end
 captured.used=true;captured.reference=reference
 prepare_consent(cx,{pane=captured.source,url='tern-spawn://managed-prepare/'..string.format('%.0f',captured.host)..'/'..string.format('%.0f',captured.manifest.revision)..'/'..captured.manifest.nonce},hooks,captured)
 return true
end
prepare_consent=function(cx,link,hooks,captured)
 local host,revision,nonce=link.url:match('^tern%-spawn://managed%-prepare/(%d+)/(%d+)/([%w%-]+)$')
 host=tonumber(host);revision=tonumber(revision)
 local source=link.pane
 if not host or not revision or not nonce or #nonce>256 or type(source)~='number' or source<1 or source%1~=0 then cx:toast('error','SPAWN','Invalid preparation request; nothing started.');return {handled=true} end
 if pending[nonce] and (not captured or pending[nonce]~=captured.request) then return {handled=true} end
 local origin=if captured then captured.origin else hooks.capture(cx)
 local clicked_window=cx:window_key()
 local clicked_recipient=hooks.recipient()
 local clicked_binding=if captured then captured.binding elseif type(clicked_recipient)=='table' then {window=clicked_recipient.window_key,native_namespace=clicked_recipient.namespace,native_conn=clicked_recipient.conn,native_since=clicked_recipient.since} else nil
 if not origin or not hooks.member(cx,origin,source) then if captured then M.cancel_reviewed(captured) end;return {handled=true} end
 local manifest=if captured then captured.manifest else nil
 local request=if captured then captured.request else {deadline=tern.now()+30000,index=1,consents={}}
 if not captured then pending[nonce]=request end
 local function finish()
  if pending[nonce]==request then pending[nonce]=closed_preparation end
  if manifest then for _,entry in ipairs(manifest.entries) do if pending[entry.nonce]==request then pending[entry.nonce]=nil end end end
  if captured then M.cancel_reviewed(captured) end
 end
 -- A host's open-URL event can reach this VM before its new surface. Retain the
 -- original click, not a fresh click/TTL, while that exact nonce is published.
 local function accept_manifest(fresh)
  if pending[nonce]~=request or request.started then return end
  local current=if fresh then hooks.capture(fresh) else nil
  local recipient=hooks.recipient()
  if not current or current.host~=origin.host or current.session~=origin.session or not hooks.member(fresh,origin,source) or fresh:window_key()~=clicked_window or type(recipient)~='table' or recipient.window_key~=clicked_window or (clicked_binding and not recipient_matches(fresh,clicked_binding,hooks)) or tern.now()>request.deadline then finish();if fresh then fresh:toast('error','SPAWN','Preparation approval changed or expired; no diagnostic was launched.') end;return end
  if not captured then manifest=prepare_read(fresh,source) end
  if not manifest or manifest.nonce~=nonce then tern.timer(250,accept_manifest);return end
  if manifest.revision~=revision or manifest.status~='awaiting_consent' then finish();return end
  if not captured then
   for index,entry in ipairs(manifest.entries) do
    if pending[entry.nonce] or active[entry.nonce] then finish();return end
    request.consents[index]={nonce=entry.nonce,window_consent=string.format('consent-%d-%08x-%08x-%d',os.time(),math.random(1,2147483647),math.random(1,2147483647),index)}
   end
   for _,entry in ipairs(manifest.entries) do pending[entry.nonce]=request end
  end
  local binding={window=recipient.window_key,native_namespace=recipient.namespace,native_conn=recipient.conn,native_since=recipient.since}
  local input={nonce=nonce,config_revision=revision,window=binding.window,native_namespace=binding.native_namespace,native_conn=binding.native_conn,native_since=binding.native_since,consents=request.consents}
  if captured then input.reviewed=captured.reference;input.entries=manifest.entries end
  request.started=true
  local sent,why=pcall(function()fresh.session:event(source,{ev='action',id='main',act=if captured then 'managed-reviewed-prepare' else 'managed-prepare-consent',value=tern.json.encode(input)})end)
  if not sent then finish();fresh:toast('error','SPAWN','Preparation approval could not be delivered: '..tostring(why));return end
  -- Approval delivery keeps its original 30s bound. Each resource phase gets
  -- 180s; only drive starts the independent, unchanged 45s diagnostic clock.
  request.preparation_deadline=tern.now()+180000
  local function matches_manifest(actual)
   if not actual or actual.nonce~=nonce or actual.revision~=revision or #actual.entries~=#manifest.entries or actual.status=='failed' then return false end
   for index,entry in ipairs(manifest.entries) do
    local value=actual.entries[index]
    if value.nonce~=entry.nonce or value.record_id~=entry.record_id or value.backend~=entry.backend or value.revision~=entry.revision or value.label~=entry.label then return false end
   end
   return true
  end
  local function same_source(nextcx)
   local here=if nextcx then hooks.capture(nextcx) else nil
   return here and recipient_matches(nextcx,binding,hooks) and here.host==origin.host and here.session==origin.session and hooks.member(nextcx,origin,source)
  end
  local function wait_prepared(nextcx)
   if pending[nonce]~=request then return end
   if not same_source(nextcx) then finish();return end
   local current_manifest=prepare_read(nextcx,source)
   if captured and (not current_manifest or current_manifest.nonce~=nonce) then
    if tern.now()>request.preparation_deadline then finish();nextcx:toast('error','SPAWN','Agents were saved but preparation was not accepted. Check Setup status; no diagnostic was replayed.');return end
    tern.timer(250,wait_prepared);return
   end
   if not matches_manifest(current_manifest) then finish();return end
   local entry=manifest.entries[request.index]
   if not entry then finish();return end
   if tern.now()>request.preparation_deadline then finish();nextcx:toast('error','SPAWN','Resource preparation was not confirmed in time. Check Setup status; no diagnostic was repeated.');return end
   local consent=request.consents[request.index]
   local route=M.read(nextcx,source)
   if route and route.nonce==entry.nonce and route.window_consent==consent.window_consent then
    if route.source_pane~=host or route.config_revision~=entry.revision or route.record_id~=entry.record_id or route.backend~=entry.backend or route.status~='running' or route.cleanup_only or route.cleanup_blocked or route.bound_pane~=nil or route.cleanup_pending~=true or not recipient_matches(nextcx,route,hooks) then finish();return end
    -- Refresh native identity at each actual entry, without minting consent or
    -- rebinding to a replacement window/account while preparation was running.
    hooks.ensure(nextcx,function(bound,err)
     if pending[nonce]~=request then return end
     if err or not same_source(bound) or tern.now()>request.preparation_deadline or not matches_manifest(prepare_read(bound,source)) then finish();return end
     local actual=M.read(bound,source)
     if not actual or actual.nonce~=entry.nonce or actual.window_consent~=consent.window_consent or actual.source_pane~=host or actual.config_revision~=entry.revision or actual.record_id~=entry.record_id or actual.backend~=entry.backend or actual.command~=route.command or actual.cwd~=route.cwd or actual.prompt~=route.prompt or actual.status~='running' or actual.cleanup_only or actual.cleanup_blocked or actual.bound_pane~=nil or actual.cleanup_pending~=true or not recipient_matches(bound,actual,hooks) then finish();return end
     pending[entry.nonce]=nil
     drive(bound,source,actual,hooks,true,function(done,settled)
      if settled.status~='passed' or pending[nonce]~=request then finish();return end
      done.session:event(source,{ev='action',id='main',act='managed-prepare-next',value=tern.json.encode({nonce=entry.nonce,window_consent=consent.window_consent,window=binding.window,native_namespace=binding.native_namespace,native_conn=binding.native_conn,native_since=binding.native_since})})
      request.index+=1;request.preparation_deadline=tern.now()+180000
      if request.index>#manifest.entries then finish() else tern.timer(250,wait_prepared) end
     end)
    end)
    return
   end
   tern.timer(250,wait_prepared)
  end
  wait_prepared(fresh)
 end
 hooks.ensure(cx,function(fresh,err)
  if err then finish();if fresh then fresh:toast('error','SPAWN','The clicked native window could not be verified; no diagnostic was launched.') end;return end
  accept_manifest(fresh)
 end)
 return {handled=true}
end
function M.consent(cx,link,hooks)
 if type(link.url)=='string' and link.url:match('^tern%-spawn://managed%-prepare/') then return prepare_consent(cx,link,hooks) end
 if type(link.url)~='string' or not link.url:match('^tern%-spawn://managed%-route/') then return nil end
 local host,revision,nonce=link.url:match('^tern%-spawn://managed%-route/(%d+)/(%d+)/([%w%-]+)$')
 host=tonumber(host);revision=tonumber(revision)
 local source=link.pane
 if not host or host<1 or not revision or not nonce or #nonce>256 or type(source)~='number' or source<1 or source%1~=0 then
  cx:toast('error','SPAWN','The diagnostic request is invalid; no diagnostic was launched.');return {handled=true}
 end
 if pending[nonce] or active[nonce] then return {handled=true} end
 local origin=hooks.capture(cx)
 if not origin or not hooks.member(cx,origin,source) then return {handled=true} end
 local request={deadline=tern.now()+30000,token=string.format("consent-%d-%08x-%08x-%08x",os.time(),math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647))}
 pending[nonce]=request
 hooks.ensure(cx,function(fresh,err)
  if pending[nonce]~=request then return end
  local current=if fresh then hooks.capture(fresh) else nil
  local recipient=hooks.recipient()
  if err or not current or current.host~=origin.host or current.session~=origin.session or not hooks.member(fresh,origin,source) or type(recipient)~='table' or type(recipient.namespace)~='string' or recipient.window_key~=fresh:window_key() or tern.now()>request.deadline then
   pending[nonce]=nil;if fresh then fresh:toast('error','SPAWN',err or 'The clicked window changed; no diagnostic was launched.') end;return
  end
  local binding={window=recipient.window_key,native_namespace=recipient.namespace,native_conn=recipient.conn,native_since=recipient.since}
  local sent,why=pcall(function()
   fresh.session:event(source,{ev='action',id='main',act='managed-route-consent',value=tern.json.encode({nonce=nonce,config_revision=revision,window=binding.window,native_namespace=binding.native_namespace,native_conn=binding.native_conn,native_since=binding.native_since,window_consent=request.token})})
  end)
  if not sent then pending[nonce]=nil;fresh:toast('error','SPAWN','Diagnostic consent could not be delivered: '..tostring(why));return end
  local function wait_route(nextcx)
   if pending[nonce]~=request then return end
   if not nextcx or not recipient_matches(nextcx,binding,hooks) then pending[nonce]=nil;return end
   local here=hooks.capture(nextcx)
   if not here or here.host~=origin.host or here.session~=origin.session or not hooks.member(nextcx,origin,source) then pending[nonce]=nil;return end
   local route=M.read(nextcx,source)
   if route and route.nonce==nonce and route.window_consent==request.token then
    pending[nonce]=nil
    if route.source_pane==host and route.config_revision==revision and route.status=='running' and not route.cleanup_only and not route.cleanup_blocked and route.bound_pane==nil and route.cleanup_pending==true and recipient_matches(nextcx,route,hooks) then drive(nextcx,source,route,hooks,true) end
    return
   end
   if tern.now()>request.deadline then pending[nonce]=nil;nextcx:toast('error','SPAWN','Diagnostic consent was not accepted; check Setup status. Nothing was launched.');return end
   tern.timer(250,wait_route)
  end
  wait_route(fresh)
 end)
 return {handled=true}
end
function M.reconcile(cx,source,has_pending,hooks)
 local route=M.read(cx,source)
 if not route or route.cleanup_pending~=true or route.cleanup_blocked or active[route.nonce] or pending[route.nonce] or has_pending then return end
 drive(cx,source,route,hooks,false)
end
return M
