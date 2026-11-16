-- Native navigation/context boundary fixtures; no settings or provider effects.
local root=...
assert(type(root)=='string','pass the package directory')
local runtime,environment=tern,getfenv()
local chunk=assert(loadstring(runtime.fs.read(root..'/page_navigation.luau'),'page_navigation'))
setfenv(chunk,setmetatable({tern={json=runtime.json}},{__index=environment}))
local N=chunk()
local checks=0
local function check(ok,message)assert(ok,message);checks+=1 end
local function fixture()
 local f={scope={host=0,session=4},panes={[1]={pane=1,block='spawn.spawner'},[2]={pane=2,block='orchplus.orchestrator'}},events={},created={},focused={},reads=0}
 f.cx={session={},layout={},window_key=function()return '' end}
 f.cx.session.pane=function(_,id)return f.panes[id]end
 f.cx.session.view=function(_,id)local p=f.panes[id];return if p and not p.hidden then {} else nil end
 f.cx.session.panes=function()
  local list={};for _,p in pairs(f.panes) do table.insert(list,p) end
  if f.after_list then f.after_list() end
  return list
 end
 f.cx.session.event=function(_,pane,event)table.insert(f.events,{pane=pane,event=event})end
 f.cx.layout.focus=function(_,pane)table.insert(f.focused,pane);if f.after_focus then f.after_focus() end end
 f.cx.new_block=function(_,kind,args,placement,options)
  if f.unavailable then error('ORCH+ is not installed') end
  table.insert(f.created,{kind=kind,args=args,placement=placement,options=options});return 99
 end
 f.hooks={capture=function()return {host=f.scope.host,session=f.scope.session}end,context_error=function(_,origin)
  if f.before_scope_check then f.before_scope_check() end
  return if origin.host~=f.scope.host or origin.session~=f.scope.session then 'Captured source scope changed' else nil
 end,member=function(_,origin,pane)local p=f.panes[pane];return p~=nil and not p.foreign and not p.parked and origin.host==f.scope.host and origin.session==f.scope.session end}
 f.context={kind='context',native_window='',host={id=0,name='Local',kind='local'},client_config={schema=1,agents={{id='owner-legacy'}}}}
 function f.build()
  f.reads+=1;if f.during_context then f.during_context() end
  return {runtime.json.encode(f.context)}
 end
 return f
end
for _,page in ipairs({'managed','runtime'}) do
 check(N.page({kind='page',page=page,native_window=''})~=nil,'supported owner page accepts the empty native window key: '..page)
end
for _,entry in ipairs({{kind='page',page='other',native_window=''}, {kind='page',page='managed',native_window='',client_config={}}, {kind='page',page='managed'}, {kind='page',page='managed',native_window='bad\nwindow'}}) do
 check(N.page(entry)==nil,'public page object is closed and cannot carry foreign settings')
end
local f=fixture()
check(N.readiness(f.cx,1,f.hooks),'existing appropriate visible ORCH page opens')
check(#f.focused==1 and f.focused[1]==2 and #f.created==0 and #f.events==1,'native focus and owner page event replace plugin-command dispatch')
local event=f.events[1].event;local entry=runtime.json.decode(event.value)
check(event.ev=='action' and event.id=='main' and event.act=='page-entry' and entry.kind=='page' and entry.page=='readiness' and entry.native_window=='','readiness event has the exact public owner entry')
for _,kind in ipairs({'hidden','parked','foreign','closed','ambiguous'}) do
 local item=fixture()
 if kind=='closed' then item.panes[2]=nil
 elseif kind=='ambiguous' then item.panes[3]={pane=3,block='orchplus.orchestrator'}
 else item.panes[2][kind]=true end
 check(N.readiness(item.cx,1,item.hooks),'missing or unsuitable target opens a new inert owner page: '..kind)
 check(#item.focused==0 and #item.events==0 and #item.created==1,'no unsuitable or ambiguous target is guessed: '..kind)
 local created=item.created[1];local page=runtime.json.decode(created.args[2])
 check(created.kind=='orchplus.orchestrator' and created.args[1]=='config' and page.page=='readiness' and page.native_window=='' and created.options.focus==true,'new owner pane gets only config/page arguments')
end
local closed=fixture();closed.panes[1]=nil
check(not N.readiness(closed.cx,1,closed.hooks) and #closed.created==0 and #closed.focused==0,'closed source cannot navigate')
local stale=fixture();stale.after_list=function()stale.scope.session=5 end
check(not N.readiness(stale.cx,1,stale.hooks) and #stale.created==0 and #stale.focused==0,'changed source scope is revalidated before native effects')
local targetClosed=fixture();local scopeChecks=0
targetClosed.before_scope_check=function()scopeChecks+=1;if scopeChecks==2 then targetClosed.panes[2]=nil end end
check(not N.readiness(targetClosed.cx,1,targetClosed.hooks) and #targetClosed.created==0 and #targetClosed.focused==0,'target closed after selection is refused without guessed replacement')
local closeAfterFocus=fixture();closeAfterFocus.after_focus=function()closeAfterFocus.panes[1]=nil end
check(not N.readiness(closeAfterFocus.cx,1,closeAfterFocus.hooks) and #closeAfterFocus.events==0,'source closure across focus prevents owner page event')
local unavailable=fixture();unavailable.panes[2]=nil;unavailable.unavailable=true
check(not N.readiness(unavailable.cx,1,unavailable.hooks) and #unavailable.events==0,'missing plugin is a visible navigation refusal, not command fallback')
local request={entry={kind='page',page='managed',native_window=''},nonce='view-local-fixture'}
local owner=fixture()
check(N.handoff(owner.cx,1,request,owner.build,owner.hooks),'SPAWN owner supplies its own context')
local response=runtime.json.decode(owner.events[1].event.value)
check(owner.reads==1 and response.nonce==request.nonce and runtime.json.encode(response.context)==runtime.json.encode(owner.context),'exact owner legacy config and native context survive only the owner handoff')
check(owner.events[1].event.act=='spawn.page-context' and owner.events[1].pane==1,'context stays on the same SPAWN pane, never a foreign plugin')
local moved=fixture();moved.during_context=function()moved.scope.host=2 end
check(not N.handoff(moved.cx,1,request,moved.build,moved.hooks) and #moved.events==0,'source scope change during owner context read refuses delivery')
local removed=fixture();removed.during_context=function()removed.panes[1]=nil end
check(not N.handoff(removed.cx,1,request,removed.build,removed.hooks) and #removed.events==0,'source closure during owner context read refuses delivery')
local foreign=fixture();local wrong={entry={kind='page',page='managed',native_window='other'},nonce='view-local-fixture'}
check(not N.handoff(foreign.cx,1,wrong,foreign.build,foreign.hooks) and foreign.reads==0,'foreign native window cannot request SPAWN legacy state')
return 'PASS page_navigation '..tostring(checks)
