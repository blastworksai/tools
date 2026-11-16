-- Navigation and view-local owner context only; no settings/resource writers.
local M={}
local function fields(value,allowed)
 if type(value)~='table' then return false end
 for key in pairs(value) do if not allowed[key] then return false end end
 return true
end
local function window(value)
 return type(value)=='string' and #value<=256 and not value:find('%c')
end
function M.page(value)
 if type(value)=='string' then
  if #value>2048 then return nil,'Page entry exceeds its bound' end
  local ok,decoded=pcall(tern.json.decode,value);if not ok then return nil,'Invalid page entry JSON' end
  value=decoded
 end
 if not fields(value,{kind=true,page=true,native_window=true}) or value.kind~='page' or (value.page~='managed' and value.page~='runtime') or not window(value.native_window) then return nil,'Invalid owner page entry' end
 return {kind='page',page=value.page,native_window=value.native_window},nil
end
function M.context(value,expected_window)
 if not fields(value,{kind=true,host=true,native_window=true,client_config=true}) or value.kind~='context' or value.native_window~=expected_window or not window(value.native_window) or not fields(value.host,{id=true,name=true,kind=true,address=true}) then return nil,'Invalid SPAWN owner context' end
 local host=value.host
 if type(host.id)~='number' or host.id<0 or host.id%1~=0 or type(host.name)~='string' or type(host.kind)~='string' or (host.address~=nil and type(host.address)~='string') then return nil,'Invalid SPAWN native host context' end
 return value,nil
end
function M.request(value)
 if not fields(value,{entry=true,nonce=true}) or type(value.nonce)~='string' or #value.nonce<1 or #value.nonce>96 or value.nonce:find('%c') then return nil end
 local entry=M.page(value.entry);if not entry then return nil end
 return {entry=entry,nonce=value.nonce}
end
function M.visible(cx,pane,block,origin,hooks,require_view)
 local info=cx.session:pane(pane)
 if not info or info.block~=block or info.parked or type(info.exited)=='number' or (type(info.error)=='string' and info.error~='') or not hooks.member(cx,origin,pane) then return false end
 return require_view==false or cx.session:view(pane,{nodes=1,depth=1,max_chars=64})~=nil
end
local function source(cx,pane,origin,hooks,require_view)
 local changed=hooks.context_error(cx,origin,true)
 if changed then return changed end
 if not M.visible(cx,pane,'spawn.spawner',origin,hooks,require_view) then return 'The source SPAWN Config is closed, hidden, parked or no longer in its captured scope' end
 return nil
end
function M.readiness(cx,pane,hooks)
 local ok,opened,why=pcall(function()
  local origin,err=hooks.capture(cx);if not origin then return false,err end
  local problem=source(cx,pane,origin,hooks,true);if problem then return false,problem end
  local targets={}
  for _,item in ipairs(cx.session:panes()) do
   if item.block=='orchplus.orchestrator' and M.visible(cx,item.pane,'orchplus.orchestrator',origin,hooks,true) then table.insert(targets,item.pane) end
  end
  problem=source(cx,pane,origin,hooks,true);if problem then return false,problem end
  local entry={kind='page',page='readiness',native_window=cx:window_key()}
  if #targets==1 then
   local target=targets[1]
   if not M.visible(cx,target,'orchplus.orchestrator',origin,hooks,true) then return false,'The selected ORCH+ page closed or changed; choose readiness again' end
   cx.layout:focus(target)
   problem=source(cx,pane,origin,hooks,false);if problem then return false,problem end
   if not M.visible(cx,target,'orchplus.orchestrator',origin,hooks,true) then return false,'The selected ORCH+ page is no longer available' end
   cx.session:event(target,{ev='action',id='main',act='page-entry',value=tern.json.encode(entry)})
  else
   local created=cx:new_block('orchplus.orchestrator',{'config',tern.json.encode(entry)},'tab',{focus=true})
   if type(created)~='number' then return false,'ORCH+ could not open its optional readiness page' end
  end
  return true,nil
 end)
 if not ok then return false,'Optional ORCH+ readiness navigation is unavailable: '..tostring(opened):sub(1,512) end
 return opened,why
end
function M.handoff(cx,pane,request,build_context,hooks)
 local ok,done,why=pcall(function()
  request=M.request(request)
  if not request or request.entry.native_window~=cx:window_key() then return false,'This SPAWN page belongs to another native window' end
  local origin,err=hooks.capture(cx);if not origin then return false,err end
  local problem=source(cx,pane,origin,hooks,true);if problem then return false,problem end
  -- Only the SPAWN window supplies this builder, which reads SPAWN's own legacy KV.
  local args=build_context(cx,origin)
  local decoded,context=pcall(tern.json.decode,args[1])
  if not decoded then return false,'SPAWN could not encode its owner context' end
  context,err=M.context(context,request.entry.native_window);if not context then return false,err end
  problem=source(cx,pane,origin,hooks,true);if problem then return false,problem end
  cx.session:event(pane,{ev='action',id='main',act='spawn.page-context',value=tern.json.encode({nonce=request.nonce,context=context})})
  return true,nil
 end)
 if not ok then return false,'SPAWN owner context is unavailable: '..tostring(done):sub(1,512) end
 return done,why
end
return M
