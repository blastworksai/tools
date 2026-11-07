-- Native setup diagnostics only. Authority owns the single durable cleanup obligation.
-- This VM retains no durable journal and never replays an interrupted launch.
local Bridge=require('./dispatch_window')
local M={}
local active={}
function M.read(cx,source)
 local bytes=Bridge.read_node(cx,source,'spawn.spawner','spawn-managed-route','spawn.managed.route',100000)
 if not bytes then return nil end
 local ok,route=pcall(tern.json.decode,bytes)
 if not ok or type(route)~='table' or route.schema~=1 or type(route.nonce)~='string' or type(route.command)~='string' or type(route.cwd)~='string' or route.window~=cx:window_key() then return nil end
 return route
end
local function send(cx,source,route,act,pane,err,cleaned)
 cx.session:event(source,{ev='action',id='main',act=act,value=tern.json.encode({nonce=route.nonce,window=route.window,pane=pane or 0,error=err,cleaned=cleaned})})
end
local function native_match(cx,route,origin,hooks)
 local found
 for _,agent in ipairs(cx.agents:list()) do
  if agent.command==route.command then
   if agent.cwd~=route.cwd or not hooks.member(cx,origin,agent.pane) or found then return nil,'Diagnostic native identity is ambiguous or outside its captured scope' end
   found=agent.pane
  end
 end
 return found,nil
end
local function owned(cx,route,origin,hooks,known,stopped)
 if route.backend=='native-agent' then return native_match(cx,route,origin,hooks) end
 -- Terminal ownership is positively read back by the host's native inventory,
 -- not guessed from its title/program or an unrelated terminal's argv.
 local pane=route.owned_pane
 if pane then
  local info=cx.session:pane(pane)
  if not info and stopped then return nil,nil end
  if not info or info.cwd~=route.cwd or not hooks.member(cx,origin,pane) then return nil,'Diagnostic terminal ownership is no longer observable' end
  return pane,nil
 end
 if known and cx.session:pane(known)~=nil then return nil,'Waiting for exact host-observed terminal command ownership' end
 return nil,nil
end
local function drive(cx,source,route,hooks,start)
 if active[route.nonce] then return end
 local origin=hooks.capture(cx)
 if not origin or origin.session~=route.native_session or route.window~=cx:window_key() or not hooks.member(cx,origin,source) then return end
 if route.source_pane~=source then
  -- A second Config cannot cancel the live owner's diagnostic.
  for _,item in ipairs(cx.session:panes()) do if item.pane==route.source_pane then return end end
 end
 local track={origin=origin,route=route,source=source,pane=route.bound_pane,revision=route.config_revision,conn=route.native_conn,since=route.native_since,deadline=tern.now()+45000,cleanup=not start,error=if start then nil else 'Interrupted diagnostic: cleanup only; no provider turn was replayed'}
 active[route.nonce]=track
 if start then
  track.awaiting_launch=true
  local ok,why=pcall(send,cx,source,route,'managed-route-preflight',nil)
  if not ok then track.awaiting_launch=false;track.cleanup=true;track.error='Native diagnostic preflight could not be requested: '..tostring(why) end
 end
 local function poll(fresh)
  if fresh==nil then active[route.nonce]=nil;return end
  local ok,problem=pcall(function()
   local current=M.read(fresh,source)
   if current and current.nonce==route.nonce then
    route=current;track.route=route
    if route.cleanup_pending==false then active[route.nonce]=nil;return end
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
     if route.config_revision~=track.revision or route.native_conn~=track.conn or route.native_since~=track.since or ready.nonce~=route.nonce or ready.config_revision~=track.revision or ready.native_conn~=track.conn or ready.native_since~=track.since or not current_origin or current_origin.host~=origin.host or current_origin.session~=origin.session or not source_visible then
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
   if track.cleanup then
    if pane then
     if source_visible and (route.bound_pane~=pane or route.owned_pane~=pane) then
      -- Persist positive native identity before destroying uncertain-start evidence.
      send(fresh,source,route,'managed-route-started',pane)
      return
     end
     if route.backend=='native-agent' then fresh.agents:stop(pane) else fresh.layout:close(pane) end
     track.stopped=true
     return
    end
    if track.pane and fresh.session:pane(track.pane)~=nil then return end
    if not source_visible then active[route.nonce]=nil;return end
    if route.bound_pane==nil then
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
   elseif route.owned_pane~=pane then return end
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
function M.start(cx,source,revision,hooks)
 local route=M.read(cx,source)
 if not route or route.config_revision~=revision or route.status~='running' or route.cleanup_only or route.cleanup_blocked or route.bound_pane~=nil or route.cleanup_pending~=true or type(route.native_conn)~='number' or type(route.native_since)~='number' then return end
 drive(cx,source,route,hooks,true)
end
function M.reconcile(cx,source,pending,hooks)
 local route=M.read(cx,source)
 if not route or route.cleanup_pending~=true or route.cleanup_blocked or active[route.nonce] or pending then return end
 drive(cx,source,route,hooks,false)
end
return M
