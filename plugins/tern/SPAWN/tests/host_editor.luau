-- Native host UI callbacks with real configuration/authority modules; only KV,
-- membership IO and rendering boundaries are injected. No native effects.
local root=...
assert(type(root)=='string','pass the package directory')
local runtime,environment=tern,getfenv()
local modules,definitions,saved={},{},{}
local checks,writes=0,0
local deferred,holdInspection=nil,false
local hooks,timers={},{}
local paneList={{pane=7,program='spawn.spawner',cwd='/fixture current folder Ω'}}
local function check(value,message) assert(value,message);checks+=1 end
local function clone(value)
 if type(value)~='table' then return value end
 local out={};for key,item in pairs(value) do out[key]=clone(item) end;return out
end
local inventory={clients={{kind='window',window='fixture-window',conn=1,since=1700000000000}},sessions={{id=1,tabs={{blocks={{id=7}}}}}}}
local journalFiles={}
local function journalExists(path)
 if journalFiles[path]~=nil then return true end
 for name in pairs(journalFiles) do if name:sub(1,#path+1)==path..'/' then return true end end
 return false
end
local function journalList(path)
 assert(journalExists(path),'missing fixture directory '..path)
 local seen,entries={},{}
 for name in pairs(journalFiles) do
  if name:sub(1,#path+1)==path..'/' then
   local child=name:sub(#path+2):match('^[^/]+')
   if not seen[child] then seen[child]=true;table.insert(entries,child) end
  end
 end
 table.sort(entries);return entries
end
local fake=setmetatable({
 context='host',
 fs={exists=journalExists,list=journalList,mkdir=function()end,
  read=function(path)return assert(journalFiles[path],'missing fixture file '..path)end,
  remove=function(path)
   for name in pairs(journalFiles) do if name==path or name:sub(1,#path+1)==path..'/' then journalFiles[name]=nil end end
  end,
  write=function(path,bytes)journalFiles[path]=bytes end},
 now=function()return 1700000000 end,
 kv={get=function(key)return clone(saved[key]) end,set=function(key,value)writes+=1;saved[key]=clone(value) end},
 json=runtime.json,
 on=function(name,callback)
  hooks[name]=hooks[name] or {};table.insert(hooks[name],callback)
 end,
 timer=function(ms,callback)table.insert(timers,{ms=ms,callback=callback});return {} end,
 pane={write=function()error('Editor attempted provider input') end,list=function()return clone(paneList) end},
 block={define=function(name,definition)definitions[name]=definition end},
 ui={node=function(kind,props,children)return {k=kind,p=props,c=children} end,col=function(children)return {children=children} end,text=function(value)return {text=value} end,span=function(value)return value end,
  table=function(cols,rows,opts)return {k='table',cols=cols,rows=rows,opts=opts} end,button=function(text,props)return {k='button',text=text,p=props} end,rule=function(label)return {k='rule',text=label} end,
  card=function(head,children,props)return {k='card',head=head,c=children,p=props} end,md=function(text)return {k='md',text=text} end},
 process={run=function()error('Editor attempted a real subprocess') end},
},{__index=runtime})
modules.native_cli={inspect=function(_window,_options,callback)
 if holdInspection then deferred=callback;return end
 callback({status=0,timed_out=false,stdout=runtime.json.encode(inventory)},nil)
end,epoch=function()return 'fixture-epoch' end}
local function load(name,directory)
 if name:sub(1,2)=='./' then name=(directory or '')..name:sub(3) end
 if modules[name]~=nil then return modules[name] end
 local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
 local moduleDirectory=name:match('^(.*[/])') or ''
 setfenv(chunk,setmetatable({require=function(dependency)return load(dependency,moduleDirectory)end,tern=fake},{__index=environment}))
 modules[name]=chunk() or true;return modules[name]
end
-- Carrier IO is injected; these are host-boundary regressions, not native
-- runtime evidence. The production adapter and closed request codec stay real.
local carrierInbox,carrierSent,carrierAcks={},{},{}
local carrierBlocked,carrierAckBlocked,carrierOrdinaryBlocked=false,false,false
local carrierSendError
local carrierOpens=0
local carrierObligations,carrierQuiescentError={},false
local carrierQueries=0
local carrierTrace={events={},data={},proofs={},probe_error=nil,receives=0}
local function carrierEvent(operation,message)
 table.insert(carrierTrace.events,{operation=operation,message=clone(message)})
end
modules['channel/channel']={open=function(options)
 carrierOpens+=1
 check(options.plugin_id=='spawn','carrier opens only the fixed SPAWN endpoint')
 return {
  send=function(frame)
   carrierEvent('send',frame)
   if carrierSendError and frame.route==carrierSendError.route then return nil,{code=carrierSendError.code,operation='send'} end
   if carrierBlocked or (carrierOrdinaryBlocked and frame.priority~='settlement') then return nil,{code='backpressure',operation='send'} end
   if frame.body~='' and (frame.route=='spawn.execution' or frame.route=='spawn.current') then
    local bytes=frame.body
    if frame.route=='spawn.execution' then
     check(bytes:sub(1,19)=='SPAWN_EXECUTION v2 ','execution consumer receives its exact native frame prefix')
     bytes=bytes:sub(20)
    end
    local value=load('wire/codec').strict_decode(bytes,65536)
    check(type(value)=='table' and (frame.route~='spawn.execution' or value.schema==2),
     'actual relay projection is strict consumer JSON, never internal source fingerprint bytes')
   end
   table.insert(carrierSent,clone(frame));return {id=frame.id}
  end,
  receive=function(limit)
   check(limit==4,'host carrier bounds each receive turn')
   carrierTrace.receives+=1;carrierEvent('receive')
   for slot,proof in pairs(carrierTrace.proofs)do
    local data=carrierTrace.data[slot]
    if data==nil or load('bridge_protocol').equal(data,proof) then
     carrierTrace.proofs[slot]=nil;carrierTrace.data[slot]=nil
     carrierEvent('cleanup',proof)
    end
   end
   local messages={}
   for _,message in ipairs(carrierInbox)do
    message.recipient=message.recipient or 'spawn'
    if not message.slot then
     for slot=1,24 do
      if not carrierTrace.data[slot] then message.slot=slot;break end
     end
    end
    check(type(message.slot)=='number' and message.slot>=1 and message.slot<=24,'received frames carry an exact bounded slot')
    carrierTrace.data[message.slot]=clone(message)
    if #messages<limit then table.insert(messages,clone(message))end
   end
   return messages
  end,
  acknowledged=function(message)
   carrierEvent('probe',message)
   if carrierTrace.probe_error==true or carrierTrace.probe_error==message.slot then
    return false,{code='read_failed',operation='acknowledged'}
   end
   local proof=carrierTrace.proofs[message.slot]
   if proof==nil then return false,nil end
   local data=carrierTrace.data[message.slot]
   if not load('bridge_protocol').equal(proof,message)
    or (data~=nil and not load('bridge_protocol').equal(data,message)) then
    return false,{code='content_conflict',operation='acknowledged'}
   end
   return true
  end,
  ack=function(message)
   carrierEvent('ack',message)
   if carrierAckBlocked then return false,{code='write_failed',operation='ack'} end
   table.insert(carrierAcks,message.id)
   carrierTrace.proofs[message.slot]=clone(message)
   for i=#carrierInbox,1,-1 do if carrierInbox[i].id==message.id then table.remove(carrierInbox,i)end end
   return true
  end,
  settle=function(limit)check(limit==4,'host carrier bounds settlement');return 0 end,
  quiescent=function(peer,roots)
   check(peer=='orchplus' and #roots>0 and #roots<=64,'collection uses one bounded exact-peer carrier batch')
   carrierQueries+=1
   if carrierQuiescentError then return nil,{code='read_failed',operation='quiescent'} end
   local quiet={}
   for _,key in ipairs(roots)do
    quiet[key]=not carrierObligations[key]
    for _,message in ipairs(carrierInbox)do
     if message.binding==key or message.binding:sub(1,#key+1)==key..':' then quiet[key]=false end
    end
   end
   return quiet
  end,
 }
end}
load('host')
-- Ordinary settlement and pane-free dispatch each install once at host load.
local sweepTimer
for _,timer in ipairs(timers)do if timer.ms==1 then sweepTimer=timer end end
check(sweepTimer~=nil and sweepTimer.ms==1,'host load arms the first settlement sweep at once')
local A,P,C=load('authority'),load('bridge_protocol'),load('config')
local definition=assert(definitions.spawner)
local opened={}
local cx={pane=7,save=function()end,render=function()end,action=function()error('Editor launched a window action') end,
 open=function(_,url,...)
  check(select('#',...)==0,'directed native consent never overrides the clicking client window')
  table.insert(opened,url)
 end}
local function record(id)
 return {id=id,provider='custom',account_label=id,backend='local-terminal',command='ordinary-cli',arguments={},enabled=true,placement='tab'}
end
-- Keep the sequential editor/setup prerequisites together, but release their
-- temporary locals before the independent HOST/window and relay regressions.
do
local beforeNavigation=clone(saved)
local publicPage={kind='page',page='managed',native_window='fixture-window'}
local inertPage=definition.init(cx,{runtime.json.encode(publicPage)},nil)
check(inertPage.binding==nil and inertPage.client_config==nil and inertPage.page=='managed' and P.equal(saved,beforeNavigation),'public page-only arguments remain inert until SPAWN supplies its own context')
local pageNode
for _,node in ipairs(definition.view(inertPage,cx).main.children) do
 if node.p and node.p.key=='spawn-page-context' then pageNode=node;break end
end
check(pageNode.p.key=='spawn-page-context' and pageNode.p.role=='spawn.page.context' and pageNode.p.hidden==true and P.equal(runtime.json.decode(pageNode.text).entry,publicPage),'inert page requests only a hidden exact view-local owner context')
local invalidPublic=clone(publicPage);invalidPublic.client_config={schema=1,agents={}}
local invalidPage=definition.init(cx,{runtime.json.encode(invalidPublic)},nil)
check(invalidPage.binding==nil and invalidPage.page_context_request==nil and P.equal(saved,beforeNavigation),'foreign page arguments cannot carry or import legacy client configuration')
local inertSaved=definition.save(inertPage)
check(inertSaved.page_context_request==nil and inertSaved.client_config==nil and inertSaved.page_entry==nil,'owner context handoff is never a durable protocol or second settings store')
local state=definition.init(cx,{runtime.json.encode({host={name='fixture'},native_window='fixture-window'})},nil)
check(state.binding~=nil and state.snapshot~=nil,'host opens through original native membership boundary')
state.page='managed';definition.view(state,cx)
check(state.managed_draft.cwd=='/fixture current folder Ω' and state.managed_draft.user=='' and state.managed_draft.root==runtime.plugin.data..'/managed','same-user setup defaults to the verified host pane folder and native plugin data without host/user configuration')
state.page='runtime'
local function snapshot()return assert(A.snapshot(state.binding)) end
local function refresh()definition.event(state,{ev='action',act='refresh'},cx) end
local function row(revision)return 'agent:editable:json:'..tostring(revision or state.snapshot.config_revision) end
local function activate()
 definition.event(state,{ev='activate',item=row()},cx)
 check(state.editing and state.editing.row==row(),'full-record editor activates the revision-bound row')
 return runtime.json.decode(state.editing.draft)
end
local function send(value,revision)
 definition.event(state,{ev='change',item=row(revision),value=runtime.json.encode(value)},cx)
end
local original=record('editable')
original.fresh_executable='/tools/worker';original.fresh_arguments={'--fresh','--task'};original.task_argument_index=3
original.cwd='/work';original.model='model-old';original.profile='profile-old';original.capacity_binding='account';original.capacity_limit=2
original.mailbox={permitted_root='/mailboxes',helper_path='/tools/mailbox_target.sh',producer_helper_path='/tools/mailbox_worker.sh',worker_identity='worker',producer={read=true,write=true,hash=true,journal=true,poll=true},capabilities={'report-files-v1','worker-poll-v1','argv-v1'},wake='worker-poll-v1',verified=false,evidence_ref='fixture-unverified'}
local other=record('other')
check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records={original,other}}),'seed two canonical records')
refresh()
local baseline=snapshot()
check(baseline.version==2 and type(baseline.jobs)=='table','host editor consumes released snapshot v2 with explicit execution jobs')
state.page='agents'
local normal=definition.view(state,cx)
local normalEditor=false
for _,section in ipairs(normal.main.children[1].p.sections) do
 for _,item in ipairs(section.rows) do if item.id==row() then normalEditor=true end end
end
check(not normalEditor and normal.main.children[2].p.hidden==true,'Normal Config hides machine state and exposes no complete-record JSON editor')
definition.event(state,{ev='activate',item=row()},cx)
check(state.editing==nil,'Normal Config refuses a crafted JSON editor activation until Advanced is explicit')
definition.event(state,{ev='action',act='advanced-open'},cx)
local rendered=definition.view(state,cx)
local foundEditor=false
for _,section in ipairs(rendered.main.children[1].p.sections) do
 for _,item in ipairs(section.rows) do
  if item.id==row() then foundEditor=item.control.k=='text' and item.control.value=='' end
 end
end
check(foundEditor,'explicit Advanced exposes a full-record JSON row without embedding the entire record in every field')
check(rendered.main.children[2].text:sub(1,15)=='SPAWN_STATE_V2 ' and rendered.main.children[2].p.hidden==true,'native snapshot surface keeps released v2 transport hidden even in Advanced')
local edited=activate()
local before=clone(saved);local priorWrites=writes
check(definition.key(state,{name='enter'},cx),'unchanged JSON closes through existing keyboard editor')
check(writes==priorWrites and P.equal(before,saved),'unchanged canonical JSON does not write or create a review block')
for _,invalid in ipairs({'{','false','[]',string.rep('x',120001)}) do
 before=clone(saved)
 definition.event(state,{ev='change',item=row(),value=invalid},cx)
 check(P.equal(before,saved) and type(state.notice)=='string','malformed or oversized record JSON preserves durable state')
end
for _,invalid in ipairs({{id='different'}, {unknown_field=true}, {capacity_limit=0}, {mailbox={verified='true'}}, {fresh_executable=false}}) do
 local candidate=clone(baseline.records[1]);for key,value in pairs(invalid) do candidate[key]=value end
 before=clone(saved);send(candidate)
 check(P.equal(before,saved) and type(state.notice)=='string','invalid schema or changed stable ID cannot replace a saved record')
end
local forged=clone(baseline.records[1]);forged.mailbox.verified=true;forged.mailbox.evidence_ref='operator-supplied-readiness'
before=clone(saved);send(forged)
check(P.equal(before,saved) and state.notice:find('Managed readiness cannot be supplied by JSON',1,true)~=nil,'full-record JSON cannot fabricate managed readiness or its evidence')
edited=activate()
edited.fresh_arguments={'--fresh','--task','--literal-profile'};edited.task_argument_index=3
edited.model='model-new';edited.profile='profile-new';edited.selector_evidence='fixture-only-selector-evidence'
state.editing.draft=runtime.json.encode(edited)
check(definition.key(state,{name='enter'},cx),'full-record JSON saves through existing keyboard commit')
local changed=snapshot()
check(changed.config_revision==baseline.config_revision+1,'full-record save uses one canonical revision increment')
check(changed.records[1].review_required==true and type(changed.records[1].review_reason)=='string','changed JSON always enters the existing settings review gate')
check(P.equal(changed.records[1].mailbox,baseline.records[1].mailbox),'full-record editing preserves existing mailbox readiness and evidence without inventing attestation')
check(P.equal(changed.records[1].fresh_arguments,edited.fresh_arguments) and changed.records[1].profile==edited.profile and changed.records[1].selector_evidence==edited.selector_evidence,'fresh argv and selector metadata survive normal schema validation')
check(P.equal(changed.records[2],baseline.records[2]) and #changed.records==2,'single-record replacement preserves every other saved record')
check(#changed.attempts==0,'JSON editing never reserves a launch')
local reserve={version=2,request_id='editor-proof/1',authority_id=state.binding.authority_id,observer_id='editor-proof',request_sequence=1,acknowledged_requests={},expected_config_revision=changed.config_revision,op='launch_record',data={record_id='editable'}}
check(A.request(state.binding,reserve),'review refusal is a real authority response')
local blocked=snapshot()
check(not blocked.replies[reserve.request_id].ok and blocked.replies[reserve.request_id].error=='review' and #blocked.attempts==0 and #blocked.jobs==0,'existing authority refuses ordinary ticket admission before explicit settings approval')
refresh()
local bypass=clone(changed.records[1]);bypass.review_required=false;bypass.review_reason=nil;bypass.profile='profile-edited-again'
send(bypass)
check(snapshot().records[1].review_required==true,'JSON cannot self-approve by clearing review fields')
definition.event(state,{ev='action',act='approve:editable@'..baseline.config_revision},cx)
check(snapshot().records[1].review_required==true,'stale approval cannot clear the new review gate')
definition.event(state,{ev='action',act='approve:editable@'..state.snapshot.config_revision},cx)
local approved=snapshot()
check(not approved.records[1].review_required and approved.records[1].review_reason==nil,'existing explicit Approve action clears the review gate')
check(approved.records[1].mailbox.evidence_ref==edited.mailbox.evidence_ref and P.equal(approved.records[2],baseline.records[2]),'approval preserves existing evidence and other records')
-- A concurrent writer arrives after the UI prepared its complete replacement but
-- before native membership verification finishes. The real revision fence wins.
local stale=activate();local staleRow=row();stale.profile='must-not-overwrite'
holdInspection=true
send(stale)
check(deferred~=nil,'mutation remains pending at native membership boundary')
local concurrent=clone(approved.records);concurrent[2].account_label='concurrent-other-label'
check(A.edit(state.binding,approved.config_revision,'replace-records',{records=concurrent}),'independent writer advances canonical revision')
before=clone(saved);holdInspection=false;local resume=deferred;deferred=nil
resume({status=0,timed_out=false,stdout=runtime.json.encode(inventory)},nil)
check(P.equal(before,saved),'stale full-record edit cannot overwrite concurrent records after async verification')
check(P.equal(snapshot().records,concurrent),'concurrent unrelated record changes remain exact')
local active=state.editing
definition.event(state,{ev='activate',item=staleRow},cx)
check(state.editing==active,'stale row activation refuses a mismatched draft revision')
-- Import remains an add-only collision refusal, not an alternate update route.
local collision=clone(snapshot().records[1]);collision.profile='conflicting-import'
definition.event(state,{ev='change',item='manual-json',value=runtime.json.encode({schema=2,agents={collision}})},cx)
definition.event(state,{ev='action',act='manual-review@'..state.snapshot.config_revision},cx)
check(state.import_review~=nil,'ordinary import preview still validates the requested schema')
local recordsBefore=clone(snapshot().records)
definition.event(state,{ev='action',act='manual-confirm@'..state.snapshot.config_revision},cx)
check(P.equal(snapshot().records,recordsBefore) and #snapshot().attempts==0,'import refusal and editor flow preserve roster and start no workers')
local launch=clone(reserve)
launch.request_id='editor-proof/2';launch.request_sequence=2;launch.acknowledged_requests={reserve.request_id}
launch.expected_config_revision=snapshot().config_revision
check(A.request(state.binding,launch),'approved record uses the released version-2 launch_record API')
local admitted=snapshot()
local reply=admitted.replies[launch.request_id]
check(reply.ok and #admitted.attempts==1 and #admitted.jobs==1,'approved launch admission creates exactly one ordinary attempt and host job')
check(admitted.jobs[1].attempt_id==admitted.attempts[1].id and type(admitted.jobs[1].ticket)=='string','admission binds the released harmless ticket to its exact attempt')
check(admitted.attempts[1].purpose~='managed','ordinary editor admission never converts managed metadata into a managed reservation')
definition.event(state,{ev='action',act='advanced-close'},cx)
check(state.editing==nil and state.import_review==nil and not state.advanced,'closing Advanced clears editable/review state without altering the authority')
local prefs_pages
local function prefs()return definition.view(state,cx).main.children[1].p end
-- Start an agent is SPAWN's own page (a table with icon cells), not a prefs page.
local function page_nodes(kind)
 local found={}
 local function walk(node)
  if type(node)~='table' then return end
  if node.k==kind then table.insert(found,node) end
  for _,child in ipairs(node.c or {}) do walk(child) end
  for _,child in ipairs(node.children or {}) do walk(child) end
 end
 walk(definition.view(state,cx).main.children[1])
 return found
end
local function spawn_rows()
 local found,ordered={},{}
 for _,card in ipairs(page_nodes('card')) do
  if type(card.p.key)=='string' and card.p.key:find('^spawn%-launch:') then
   local line=card.c[1]
   local go=line.c[2]
   local head=card.head
   local item={id=card.p.key,label=head[1],icon=card.p.icon,hint=line.c[1].c[1].text,reason=head[2],
    disabled=if go.p.disabled then go.p.disabled else nil,control={k='action',act=go.p.actions.click,label=go.text}}
   found[item.id]=item;table.insert(ordered,item)
  end
 end
 return found,ordered
end
local function rows_of(page)
 state.page=page
 local found,ordered={},{}
 for _,section in ipairs(prefs().sections) do
  for _,item in ipairs(section.rows) do found[item.id]=item;table.insert(ordered,item) end
 end
 return found,ordered
end
local function rendered_pages()
 local text={}
 for _,page in ipairs(prefs().pages) do state.page=page.id;table.insert(text,runtime.json.encode(definition.view(state,cx))) end
 return table.concat(text,'\n')
end
-- Managed setup is prominent without removing ordinary Setup/Spawn/Running pages.
local pageIds,pageLabels={},{}
for _,page in ipairs(prefs().pages) do table.insert(pageIds,page.id);pageLabels[page.id]=page.label end
prefs_pages=prefs().pages
check(P.equal(pageIds,{'runtime','spawn','agents','managed','setup'}) and pageLabels.spawn=='Start an agent','current agents and launch choices precede setup without removing ordinary pages')
local restoreCx={pane=8,save=function()end,render=function()end}
check(definition.init(restoreCx,{runtime.json.encode({host={name='fixture'},native_window='fixture-window'})},{page='spawn'}).page=='spawn','saved page restore accepts spawn')
local discoverCx={pane=9,save=function()end,render=function()end}
check(definition.init(discoverCx,{runtime.json.encode({host={name='fixture'},native_window='fixture-window',page='spawn'})},nil).page=='spawn','discovered page restore accepts spawn')
-- Settlement: the host's own sweep timer diffs tern.pane.list(), with no Config event.
local liveId=admitted.attempts[1].id
local native={pane=42,window_key='',program='/bin/bash',executable='/opt/tern',socket='/tmp/tern.sock'}
check(A.claim_execution(state.binding,liveId,native)~=nil,'fixture claims the admitted job')
check(A.update_execution(state.binding,liveId,'claimed',{epoch='fixture-epoch'})~=nil,'fixture records the current daemon epoch')
check(A.update_execution(state.binding,liveId,'claimed',{stage='submission_intent',command='ordinary-cli'})~=nil,'fixture records submission intent')
check(A.update_execution(state.binding,liveId,'submission_intent',{stage='running'},{phase='Running',pane=42})~=nil,'fixture observes the provider running')
paneList={{pane=42,title='ordinary-cli'}}
local priorTimers=#timers
sweepTimer.callback()
check(#timers==priorTimers+1 and timers[#timers].ms==15000,'each sweep re-arms the 15 s settlement timer')
check(snapshot().attempts[1].phase=='Running','a present pane keeps its ordinary attempt live')
refresh()
-- Invariant: no manual release control on any page, even with a live attempt and a restart notice.
state.snapshot.host_restart_notice={restart_id='fixture',count=2}
local everyPage=rendered_pages()
check(not everyPage:find('Mark no longer running',1,true) and not everyPage:find('Mark all',1,true),'no page renders a Mark no longer running or Mark all control')
check(not everyPage:find('Duplicate policy',1,true) and not everyPage:find('duplicate_policy',1,true),'no page renders a duplicate policy')
local runtimeRows=rows_of('runtime')
check(runtimeRows['host-restart']~=nil and runtimeRows['host-restart'].label=='Host restarted: 2 SPAWN agents ended (cleared automatically)' and runtimeRows['host-restart'].control.act=='noop','host restart is one informational line with no action')
check(runtimeRows['resolve-lost']==nil and runtimeRows['resolve-'..liveId]==nil,'Running agents has no resolve rows')
paneList={}
sweepTimer.callback()
local settled=snapshot().attempts[1]
check(settled.phase=='Exited' and settled.diagnostic=='Pane closed' and not settled.unresolved,'the host sweep settles a closed pane to Exited without any human action')
check(state.snapshot.attempts[1].phase=='Exited','the sweep refreshes the open Config view')
local runtimeRows=rows_of('runtime')
check(runtimeRows['attempt-'..liveId]==nil and runtimeRows['clear-history']==nil and runtimeRows['reset-transport']==nil,'normal runtime omits settled history and transport actions')
local hiddenRuntime=definition.view(state,cx).main.children[2]
check(hiddenRuntime.p.hidden and runtime.json.decode(hiddenRuntime.text:sub(16)).attempts[1].phase=='Exited','hidden machine snapshot retains settled outcomes exactly')
definition.event(state,{ev='action',act='advanced-open'},cx)
runtimeRows=rows_of('runtime')
check(runtimeRows['attempt-'..liveId]~=nil and runtimeRows['clear-history']~=nil and runtimeRows['reset-transport']~=nil,'deliberate Advanced retains history and recovery controls')
definition.event(state,{ev='action',act='advanced-close'},cx)
local observedAttempt=clone(state.snapshot.attempts[1])
state.snapshot.attempts[1].phase='Unknown';state.snapshot.attempts[1].unresolved=true
check(rows_of('runtime')['attempt-'..liveId]~=nil,'unresolved unknown outcomes remain visible on the normal current-agents page')
state.snapshot.attempts[1]=observedAttempt
-- Single-agent rows follow saved Config order.
local roster=clone(snapshot().records)
local argsy=record('argsy');argsy.provider='kimi';argsy.account_label='Work';argsy.arguments={'--model','x y'};argsy.cwd='/srv'
local off=record('off');off.enabled=false
local needs=record('needs');needs.review_required=true;needs.review_reason='Review the new command'
table.insert(roster,argsy);table.insert(roster,off);table.insert(roster,needs)
check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=roster}),'seed launchable, disabled and needs-review records')
refresh()
definition.event(state,{ev='action',id='main',act='page',value='start'},cx)
check(state.page=='spawn','the main SPAWN entry selects single-agent start from the authoritative reviewed roster')
local rev=state.snapshot.config_revision
state.page='spawn'
local spawnRows,spawnOrder=spawn_rows()
local launchRows={}
for _,item in ipairs(spawnOrder) do if item.id:find('^spawn%-launch:') then table.insert(launchRows,item) end end
check(#launchRows==#roster,'one Spawn row per saved record')
for index,item in ipairs(launchRows) do
 local saved_record=roster[index]
 check(item.label==saved_record.provider..' — '..saved_record.account_label and item.control.act=='launch:'..saved_record.id..'@'..rev,'record rows follow Config order with Provider — Suffix labels')
end
local argsRow=spawnRows['spawn-launch:kimi:argsy']
check(argsRow~=nil and argsRow.hint=='ordinary-cli '..C.render_arguments({'--model','x y'})..' · /srv' and argsRow.disabled==nil,'record row shows command, arguments and launch folder')
check(spawnRows['spawn-launch:custom:other'].hint=='ordinary-cli · default folder','record without a folder names the default folder')
check(spawnRows['spawn-launch:custom:off'].disabled=='Disabled in Config','disabled record is shown greyed with its reason')
check(spawnRows['spawn-launch:custom:needs'].disabled=='Needs settings review: Review the new command','needs-review record is shown greyed with its reason')
check(spawnRows['spawn-launch:custom:off'].reason=='  · Disabled in Config' and spawnRows['spawn-launch:kimi:argsy'].reason==nil,'a blocked agent shows its reason in the row, a ready one shows none')
-- Model and effort rows on Agent settings: only for CLIs that have the flags, only real values.
do
 local sel=record('selclaude');sel.provider='claude';sel.command='claude';sel.account_label='Sel'
 local plain=record('selcodex');plain.provider='codex';plain.command='codex';plain.account_label='Sel2'
 local unknown=record('selunknown')
 local prior=clone(snapshot().records);local list=clone(prior);table.insert(list,sel);table.insert(list,plain);table.insert(list,unknown)
 local legacy=record('sellegacy');legacy.provider='claude';legacy.command='claude';legacy.account_label='Old';legacy.model='Claude Opus 4.7'
 local conflict=record('selconf');conflict.provider='claude';conflict.command='claude';conflict.account_label='Conf';conflict.arguments={'--model','opus'};conflict.model='sonnet';conflict.model_selector=true
 table.insert(list,legacy);table.insert(list,conflict)
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=list}),'seed claude, codex and unknown-CLI records')
 refresh()
 local function rid(id,field)return 'agent:'..id..':'..field..':'..tostring(state.snapshot.config_revision) end
 local function saved_record(id)for _,item in ipairs(snapshot().records)do if item.id==id then return item end end end
 local rows=rows_of('agents')
 check(rows[rid('selclaude','model')]~=nil and rows[rid('selclaude','effort')]~=nil and rows[rid('selclaude','effort')].control.k=='choice','a CLI with model and effort flags shows both controls')
 local values={}
 for _,option in ipairs(rows[rid('selclaude','effort')].control.options) do table.insert(values,option.value) end
 check(table.concat(values,',')==',low,medium,high,xhigh,max','effort dropdown lists the CLI default and only the real values')
 check(rows[rid('selcodex','model')]~=nil and rows[rid('selcodex','effort')]==nil,'a CLI without a verified effort flag shows a model control and no effort control')
 check(rows[rid('selunknown','model')]==nil and rows[rid('selunknown','effort')]==nil,'an unknown CLI shows neither control')
 definition.event(state,{ev='change',item=rid('selclaude','model'),value='claude-opus-5-5'},cx)
 check(saved_record('selclaude').model=='claude-opus-5-5','the model is saved exactly as typed')
 definition.event(state,{ev='change',item=rid('selclaude','effort'),value='high'},cx)
 check(saved_record('selclaude').effort=='high','a listed effort is saved')
 definition.event(state,{ev='change',item=rid('selclaude','effort'),value='ultra'},cx)
 check(saved_record('selclaude').effort=='high' and type(state.notice)=='string','an effort outside the list is refused and nothing changes')
 definition.event(state,{ev='change',item=rid('selclaude','model'),value='-bad'},cx)
 check(saved_record('selclaude').model=='claude-opus-5-5' and state.notice:find('must not start with -',1,true)~=nil,'a model id starting with - is refused')
 definition.event(state,{ev='change',item=rid('selclaude','arguments'),value='--effort low'},cx)
 check(saved_record('selclaude').arguments[1]==nil or saved_record('selclaude').arguments[1]~='--effort','arguments are not edited into a clash')
 local with_arg=clone(saved_record('selclaude'))
 definition.event(state,{ev='change',item=rid('selclaude','arguments'),value='--model other'},cx)
 definition.event(state,{ev='change',item=rid('selclaude','effort'),value=''},cx)
 check(saved_record('selclaude').effort==nil,'an empty effort clears back to the CLI default')
 definition.event(state,{ev='change',item=rid('selclaude','model'),value=''},cx)
 check(saved_record('selclaude').model==nil,'an empty model clears back to the CLI default')
 -- a saved display label is shown as display-only and typing an id turns it into a selector
 rows=rows_of('agents')
 check(rows[rid('sellegacy','model')].control.value=='' and rows[rid('sellegacy','model')].hint:find('display only',1,true)~=nil and rows[rid('sellegacy','model')].hint:find('Claude Opus 4.7',1,true)~=nil,'a pre-0.7 model label is shown as display text with the way to turn it into a selector')
 definition.event(state,{ev='change',item=rid('sellegacy','effort'),value='low'},cx)
 check(saved_record('sellegacy').model=='Claude Opus 4.7' and saved_record('sellegacy').model_selector==nil and saved_record('sellegacy').effort=='low','setting effort leaves the display label a label')
 definition.event(state,{ev='change',item=rid('sellegacy','model'),value=''},cx)
 check(saved_record('sellegacy').model=='Claude Opus 4.7','an empty Model box keeps a saved display label')
 definition.event(state,{ev='change',item=rid('sellegacy','model'),value='claude-opus-4-7'},cx)
 check(saved_record('sellegacy').model=='claude-opus-4-7' and saved_record('sellegacy').model_selector==true,'typing an id makes it an explicit selector')
 -- an existing conflict survives only while its launch contract is unchanged
 definition.event(state,{ev='change',item=rid('selconf','cwd'),value='/else'},cx)
 check(saved_record('selconf').cwd=='/else','a change outside the launch contract keeps an existing conflict')
 definition.event(state,{ev='change',item=rid('selconf','arguments'),value='--model other'},cx)
 check(saved_record('selconf').arguments[2]=='opus' and state.notice:find('Remove one',1,true)~=nil,'editing the typed flag cannot carry a conflict through')
 local json_candidate=clone(saved_record('selconf'));json_candidate.arguments={'--model','other'}
 definition.event(state,{ev='action',act='advanced-open'},cx)
 definition.event(state,{ev='change',item=rid('selconf','json'),value=runtime.json.encode(json_candidate)},cx)
 definition.event(state,{ev='action',act='advanced-close'},cx)
 check(saved_record('selconf').arguments[2]=='opus' and state.notice:find('Remove one',1,true)~=nil,'full-record JSON validates a changed conflict too: '..tostring(state.notice)..tostring(saved_record('selconf').arguments[2]))
 -- approval of a review-required record refuses a conflict
 local approve=clone(saved_record('selconf'));approve.review_required=true;approve.review_reason='r'
 local with_review=clone(snapshot().records);for index,item in ipairs(with_review) do if item.id=='selconf' then with_review[index]=approve end end
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=with_review}),'review-required conflict fixture saved');refresh()
 definition.event(state,{ev='action',act='approve:selconf@'..state.snapshot.config_revision},cx)
 check(saved_record('selconf').review_required==true and state.notice:find('Remove one',1,true)~=nil,'Approve refuses a record that carries a duplicate flag: '..tostring(state.notice))
 -- a backslash path whose two readings name different programs is refused on the host-editor save and approval road
 local mismatch=clone(approve);mismatch.arguments={};mismatch.command='/tmp/codex\\claude.exe'
 local with_mismatch=clone(snapshot().records);for index,item in ipairs(with_mismatch) do if item.id=='selconf' then with_mismatch[index]=mismatch end end
 check(not A.edit(state.binding,snapshot().config_revision,'replace-records',{records=with_mismatch}),'host save/approval refuses /tmp/codex\\claude.exe under selectors')
 check(saved_record('selconf').command=='claude','refused mismatch leaves the saved record exact')
 -- manual Setup JSON import refuses a new conflicting record at review
 local bad=record('selbad');bad.provider='claude';bad.command='claude';bad.account_label='Bad';bad.arguments={'--model','opus'};bad.model='sonnet';bad.model_selector=true
 definition.event(state,{ev='action',act='advanced-open'},cx)
 definition.event(state,{ev='change',item='manual-json',value=runtime.json.encode({schema=2,agents={bad}})},cx)
 definition.event(state,{ev='action',act='manual-review@'..state.snapshot.config_revision},cx)
 check(state.import_review==nil and state.notice:find('Remove one',1,true)~=nil,'manual import refuses a new selector conflict: '..tostring(state.notice))
 definition.event(state,{ev='action',act='advanced-close'},cx)
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=prior}),'selector fixtures removed');refresh();state.page='spawn'
end
-- Model choices come from the CLI's own headless listing when it has one; otherwise free text with the CLI's flags.
do
 local Sel=load('selectors')
 local json=runtime.json
 check(Sel.lister('grok')[2]=='models' and Sel.lister('claude')==nil and Sel.lister('codex')==nil and Sel.lister('kimi')==nil and Sel.lister('muse')==nil,'only grok, agy and omp have a documented headless listing')
 for _,cli in ipairs({'claude','codex','kimi','grok','agy','muse','omp'}) do check(type(Sel.helper(cli))=='string' and Sel.helper(cli):find('Empty keeps',1,true)~=nil,'helper text for '..cli) end
 check(Sel.helper('claude'):find('--model',1,true)~=nil and Sel.helper('claude'):find('--effort',1,true)~=nil and Sel.helper('muse'):find('--reasoning-effort',1,true)~=nil and Sel.helper('omp'):find('--thinking=',1,true)~=nil and Sel.helper('codex'):find('-m',1,true)~=nil,'helper text names the real flags')
 local grok_out='You are not authenticated.\n\nDefault model: grok-4.6\n\nAvailable models:\n  * grok-4.6 (default)\n  - grok-4.5\n'
 local ids=Sel.parse_models('grok',grok_out)
 check(#ids==2 and ids[1]=='grok-4.6' and ids[2]=='grok-4.5','grok listing parsed to its ids, notes dropped')
 check(#Sel.parse_models('agy','Fetching available models...\nError: Please sign in to view available models.\n')==0,'a not-signed-in agy answer yields no ids')
 check(#Sel.parse_models('grok','  * bad id with spaces\n  - -dash\n  * ok.model\n')==1,'ids the editor would refuse are never offered')
 check(#Sel.parse_models('omp','{"models":[]}',json.decode)==0,'an empty omp catalog yields no ids')
 local omp=Sel.parse_models('omp','{"models":["openai/gpt-5.2",{"id":"x-1"},{"nope":1}]}',json.decode)
 check(#omp==2 and omp[1]=='openai/gpt-5.2' and omp[2]=='x-1','omp listing accepts id strings and id tables')
 check(#Sel.parse_models('omp','not json',json.decode)==0 and #Sel.parse_models('grok',nil)==0,'garbage yields no ids')
 local g=record('listgrok');g.provider='grok';g.command='grok';g.account_label='G'
 local c=record('listclaude');c.provider='claude';c.command='claude';c.account_label='C'
 local prior=clone(snapshot().records);local list=clone(prior);table.insert(list,g);table.insert(list,c)
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=list}),'seed grok and claude records');refresh()
 local function rid(id,field)return 'agent:'..id..':'..field..':'..tostring(state.snapshot.config_revision) end
 local function saved_record(id)for _,item in ipairs(snapshot().records)do if item.id==id then return item end end end
 local rows=rows_of('agents')
 check(rows[rid('listgrok','model')].control.k=='text' and rows['model-list-listgrok']~=nil,'before listing, grok model is free text with a List models action')
 check(rows[rid('listgrok','model')].hint:find('-m / --model',1,true)~=nil,'free-text hint names the CLI flags')
 check(rows[rid('listclaude','model')].control.k=='text' and rows['model-list-listclaude']==nil,'a CLI with no listing has free text and no list action')
 local ran
 fake.process.run=function(argv,options,callback) ran=argv;callback({status=0,timed_out=false,stdout=grok_out,stderr=''}) end
 definition.event(state,{ev='action',act='model-list:listgrok@'..state.snapshot.config_revision},cx)
 check(ran~=nil and ran[1]=='grok' and ran[2]=='models' and #ran==2,'List models runs the CLI listing argv and nothing else: '..tostring(ran and table.concat(ran,' ')))
 rows=rows_of('agents')
 local choice=rows[rid('listgrok','model')]
 check(choice.control.k=='choice' and #choice.control.options==3 and choice.control.options[1].value=='' and choice.control.options[2].value=='grok-4.6','listed models become choices after a CLI default entry')
 definition.event(state,{ev='change',item=rid('listgrok','model'),value='grok-4.5'},cx)
 check(saved_record('listgrok').model=='grok-4.5' and saved_record('listgrok').model_selector==true,'a chosen listed model is saved as a selector')
 definition.event(state,{ev='change',item=rid('listgrok','model'),value=''},cx)
 check(saved_record('listgrok').model==nil,'choosing CLI default clears the model')
 -- a failed or empty listing keeps free text and says why
 state.model_lists={}
 fake.process.run=function(_,_,callback) callback({status=1,timed_out=false,stdout='',stderr='Please sign in'}) end
 definition.event(state,{ev='action',act='model-list:listgrok@'..state.snapshot.config_revision},cx)
 rows=rows_of('agents')
 check(rows[rid('listgrok','model')].control.k=='text' and rows['model-list-listgrok'].hint:find('Please sign in',1,true)~=nil,'a failed listing keeps the free-text field and shows the reason')
 -- listing never writes configuration and never starts a pane
 local writes_before=writes
 fake.process.run=function(_,_,callback) callback({status=0,timed_out=false,stdout=grok_out,stderr=''}) end
 definition.event(state,{ev='action',act='model-list:listgrok@'..state.snapshot.config_revision},cx)
 check(writes==writes_before,'listing models writes no configuration')
 -- another account lists through its own login route; an SSH agent has no list action
 local other=clone(saved_record('listgrok'));other.id='listother';other.user='otheracct';other.account_label='O'
 local ssh=clone(saved_record('listgrok'));ssh.id='listssh';ssh.backend='ssh-command';ssh.host='box';ssh.account_label='S'
 local more=clone(snapshot().records);table.insert(more,other);table.insert(more,ssh)
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=more}),'seed other-account and ssh records');refresh()
 rows=rows_of('agents')
 check(rows['model-list-listother']~=nil and rows['model-list-listssh']==nil,'an ssh agent offers no listing')
 ran=nil
 fake.process.run=function(argv,_,callback) ran=argv;callback({status=0,timed_out=false,stdout=grok_out,stderr=''}) end
 definition.event(state,{ev='action',act='model-list:listother@'..state.snapshot.config_revision},cx)
 check(ran~=nil and ran[1]=='sudo' and table.concat(ran,' '):find('otheracct',1,true)~=nil,'another account lists through the sudo login route: '..tostring(ran and table.concat(ran,' ')))
 fake.process.run=function()error('Editor attempted a real subprocess') end
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=prior}),'listing fixtures removed');refresh();state.page='spawn'
end
-- Every agent row carries Tern's own provider icon cell: the right name per provider, a fallback for an unknown one.
do
 local Icons=load('provider_icons')
 local expected={claude='provider-anthropic',codex='provider-openai-codex',kimi='provider-kimi-code',muse='provider-meta',agy='provider-google-antigravity',grok='provider:xai',omp='pi-mark'}
 local saved_roster=clone(snapshot().records)
 local seeded=clone(saved_roster)
 local keys={}
 for key in pairs(expected) do table.insert(keys,key) end
 table.sort(keys)
 for _,key in ipairs(keys) do local r=record('icon-'..key);r.provider=key;r.account_label='Icon';table.insert(seeded,r) end
 local unknown=record('icon-unknown');unknown.provider='Zorblax';unknown.account_label='Icon';table.insert(seeded,unknown)
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=seeded}),'seed one record per provider plus an unknown provider')
 refresh();state.page='spawn'
 local iconRows,iconOrder=spawn_rows()
 check(#iconOrder==#seeded,'one icon row per saved record')
 for _,key in ipairs(keys) do
  check(iconRows['spawn-launch:'..key..':icon-'..key].icon==expected[key],'the '..key..' row shows '..expected[key])
  check(Icons.ICONS[key]==expected[key],'the shared map names '..key..' as '..expected[key])
 end
 check(iconRows['spawn-launch:zorblax:icon-unknown'].icon==Icons.FALLBACK and Icons.FALLBACK=='sparkle','an unknown provider shows the generic fallback icon')
 for _,item in ipairs(iconOrder) do check(type(item.icon)=='string' and item.icon~='','every agent row has an icon: '..item.id) end
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=saved_roster}),'restore the roster after the icon fixture')
 refresh();state.page='spawn'
 rev=state.snapshot.config_revision
end
-- Page navigation on the own page reaches the existing page handler; every other page stays on prefs.
do
 state.page='spawn'
 local navActs={}
 for _,button in ipairs(page_nodes('button')) do if button.p and type(button.p.actions)=='table' then navActs[button.p.actions.click]=true end end
 for _,page in ipairs(prefs_pages) do check(navActs['page-go:'..page.id],'the Start an agent page navigates to '..page.id) end
 local titles={};for _,n in ipairs(page_nodes('row')) do if n.p and n.p.role=='spawn-title' then table.insert(titles,n) end end
 check(#titles==1 and titles[1].c[1].text=='Start an agent','the page shows its title once, as bold text')
 check(#page_nodes('md')==0,'the page draws no Markdown, so no build can show a raw # title')
 check(navActs.refresh and navActs['advanced-open'] and navActs.close,'the Start an agent page keeps Refresh, Advanced and Close')
 definition.event(state,{ev='action',act='page-go:setup'},cx)
 check(state.page=='setup' and definition.view(state,cx).main.children[1].k=='prefs','a page-go click opens Setup on the prefs layout')
 definition.event(state,{ev='action',act='page-go:spawn'},cx)
 check(state.page=='spawn' and definition.view(state,cx).main.children[1].k~='prefs','a page-go click returns to the own Start an agent page')
 for _,other in ipairs({'runtime','agents','managed','setup'}) do state.page=other;check(definition.view(state,cx).main.children[1].k=='prefs','page '..other..' stays on the prefs layout') end
 state.page='spawn'
end
-- Launch intents: every click queues a fresh intent (oldest first); an ack removes only its own.
local function intents()
 local node=nil
 for _,child in ipairs(definition.view(state,cx).main.children) do if child.p and child.p.key=='spawn-launch-intent' then node=child end end
 check(node~=nil,'a fresh Config publishes an explicit readable empty queue, not an unknown missing channel')
 check(node.p.key=='spawn-launch-intent' and node.p.role=='spawn.launch.intent' and node.p.hidden==true,'intents ride the hidden keyed spawn.launch.intent node')
 local value=runtime.json.decode(node.text)
 check(value.schema==1 and type(value.intents)=='table','the node carries a complete schema-1 intents list')
 return value.intents
end
local function intent_envelope(id)
 local observed={status=0,timed_out=false,stdout=runtime.json.encode(inventory)}
 local recipient=assert(load('window_journal').open('fixture-window',observed)).recipient
 recipient.intent_id=id
 recipient.queue_id=state.intent_queue_id
 return runtime.json.encode(recipient)
end
local function ack(id)
 local value=intent_envelope(id)
 definition.event(state,{ev='action',id='main',act='spawn.launch-intent-claim',value=value},cx)
 definition.event(state,{ev='action',id='main',act='spawn.launch-intent-ack',value=value},cx)
end
check(#intents()==0,'no pending intent before the first click')
before=clone(saved)
definition.event(state,{ev='action',act='launch:other@'..rev},cx)
definition.event(state,{ev='action',act='launch:argsy@'..rev},cx)
definition.event(state,{ev='action',act='launch:argsy@'..rev},cx)
local queued=intents()
check(#queued==3,'three rapid clicks queue three intents')
check(queued[1].kind=='record' and queued[1].record_id=='other' and queued[1].config_revision==rev,'the oldest intent selects exactly one saved record at the current revision')
check(queued[2].kind=='record' and queued[2].record_id=='argsy' and queued[3].kind=='record' and queued[3].record_id=='argsy','repeat clicks of one record each queue their own intent')
check(queued[1].intent_id~=queued[2].intent_id and queued[2].intent_id~=queued[3].intent_id and queued[1].intent_id~=queued[3].intent_id,'every click gets a fresh intent id')
check(P.equal(before,saved),'launch clicks admit no host execution and do not write launch-authority KV')
check(P.equal(definition.save(state).intents,state.intents),'pending ordinary intents persist through the existing Config pane save')
definition.event(state,{ev='action',id='main',act='spawn.launch-intent-ack',value=queued[2].intent_id},cx)
check(P.equal(intents(),queued),'legacy bare-ID ACK cannot bypass native recipient authority')
definition.event(state,{ev='action',id='main',act='spawn.launch-intent-ack',value=intent_envelope(queued[2].intent_id)},cx)
check(P.equal(intents(),queued),'even an exact native tuple cannot ACK an intent before HOST assigns its recipient')
ack('not-a-pending-intent')
check(P.equal(intents(),queued),'a mismatched ack removes nothing')
ack(queued[2].intent_id)
local left=intents()
check(#left==2 and left[1].intent_id==queued[1].intent_id and left[2].intent_id==queued[3].intent_id,'an ack removes only its own intent and keeps the order')
ack(queued[2].intent_id)
check(#intents()==2,'a repeated ack removes nothing more')
ack(queued[1].intent_id);ack(queued[3].intent_id)
check(#intents()==0,'acking every intent empties the pending queue')
local blankIntent=nil
for _,node in ipairs(definition.view(state,cx).main.children) do if node.p and node.p.key=='spawn-launch-intent' then blankIntent=node end end
check(blankIntent~=nil and blankIntent.p.hidden==true and #runtime.json.decode(blankIntent.text).intents==0,'durable ACK preserves the meaningful present-empty hidden intent node')
for _=1,16 do definition.event(state,{ev='action',act='launch:argsy@'..rev},cx) end
local full=intents()
check(#full==16,'the queue holds 16 intents')
definition.event(state,{ev='action',act='launch:argsy@'..rev},cx)
check(#intents()==16 and state.notice=='Too many launches queued; wait a moment','a 17th click is refused')
state.page='spawn'
check(runtime.json.encode(definition.view(state,cx).main.children[1]):find('This click was not queued',1,true)~=nil,'the refusal is shown as a notice line on Start an agent')
for _,pending in ipairs(full) do ack(pending.intent_id) end
check(#intents()==0 and runtime.json.encode(definition.view(state,cx).main.children[1]):find('This click was not queued',1,true)==nil,'draining the queue clears pending work and the notice row')
definition.event(state,{ev='action',act='launch:argsy@'..(rev-1)},cx)
check(#intents()==0 and state.notice:find('stale%-config'),'a stale click queues no intent')
-- Setup page: Guided setup goes through the intent; Review setup result only while a setup run is active.
local setupRows=rows_of('setup')
check(setupRows['setup-flow']==nil and setupRows['setup-start-helper'].control.act=='setup-start-helper@'..rev and setupRows['setup-result']==nil,'Guided setup is a heading; its one Start row uses the intent; no recovery row without an active run')
check(setupRows['manual-json']==nil and setupRows['manual-review']==nil and setupRows['bridge-import']==nil,'Normal Setup contains no manual schema2 or migration JSON controls')
check(setupRows['setup-host']==nil and setupRows['setup-add-ssh']==nil and setupRows['setup-reset']==nil,'normal local setup needs no host, SSH or destructive roster controls')
definition.event(state,{ev='action',act='advanced-open'},cx)
local advancedRows=rows_of('setup')
check(advancedRows['manual-json']~=nil and advancedRows['manual-review']~=nil and advancedRows['manual-json'].hint:find('do not prove original automatic%-source provenance')~=nil,'Advanced explicitly exposes usable recovery with its provenance limitation')
definition.event(state,{ev='action',act='advanced-close'},cx)
definition.event(state,{ev='action',act='launch-setup@'..rev},cx)
check(#intents()==0 and state.setup_topology.mode=='single' and state.setup_topology.observation==nil,'topology question precedes device discovery and helper admission')
definition.event(state,{ev='change',item='setup-device-mode',value='multi'},cx)
definition.event(state,{ev='action',act='setup-start-helper@'..rev},cx)
check(#intents()==0,'missing native device observation cannot admit a Multi device helper')
definition.event(state,{ev='change',item='setup-device-mode',value='multi'},cx)
definition.event(state,{ev='action',act='setup-find-devices@'..rev},cx)
local deviceRequest=assert(state.setup_topology.request)
local deviceRows={{id=8,name='Actual VM',kind='remote',address='existing@fixture.test',state='connected',sessions={1}},{id=0,name='Actual desktop',kind='local',state='connected',sessions={2}}}
definition.event(state,{ev='action',id='main',act='spawn.setup-devices',value=runtime.json.encode({nonce='old-devices',window='fixture-window',devices=deviceRows,current=deviceRows[1]})},cx)
check(state.setup_topology.request==deviceRequest and #intents()==0,'stale discovery cannot select an execution machine')
definition.event(state,{ev='action',id='main',act='spawn.setup-devices',value=runtime.json.encode({nonce=deviceRequest.nonce,window='fixture-window',devices=deviceRows,current=deviceRows[1]})},cx)
check(state.setup_topology.selected==8 and #intents()==0,'actual current remote host is selected without starting discovery or a helper')
definition.event(state,{ev='change',item='setup-primary',value='999'},cx)
check(state.setup_topology.selected==8,'a guessed primary device does not replace the real selected host')
definition.event(state,{ev='action',act='setup-start-helper@'..rev},cx)
check(intents()[1].kind=='setup','only approved discovered-device setup queues the exact existing launch intent')
definition.event(state,{ev='action',act='launch-setup@'..rev},cx)
check(#intents()==1 and rows_of('setup')['setup-start-helper'].disabled~=nil,'a rapid repeated Guided setup click queues no second helper and exposes its pending state')
table.insert(state.snapshot.attempts,{id='attempt-setup',record_id='editable',purpose='setup',phase='Running',mode='Native OMP',observer_id='fixture',scope='fixture',unresolved=true})
setupRows=rows_of('setup')
check(setupRows['setup-result']~=nil and setupRows['setup-result'].control.act=='launch-result@'..rev,'Review setup result appears while a setup run is active')
definition.event(state,{ev='action',act='launch-setup@'..rev},cx)
check(#intents()==1 and rows_of('setup')['setup-start-helper'].disabled~=nil,'an active unfinished setup cannot request another helper')
definition.event(state,{ev='action',act='launch-result@'..rev},cx)
local setupQueue=intents()
check(#setupQueue==2 and setupQueue[2].kind=='result','Review setup result click queues a result intent after the setup intent')
refresh()
-- Native setup drafts/probes are not a second settings store. These injected
-- observations exercise UI fencing only; real platform probes belong to smoke.
for _,pending in ipairs(intents() or {}) do ack(pending.intent_id) end
definition.event(state,{ev='change',item='managed-existing',value=''},cx)
local managedRows=rows_of('managed')
check(managedRows['managed-begin']==nil and managedRows['managed-attest']==nil and managedRows['managed-cli-attest']==nil,'cold setup cannot attest readiness or manufacture setup completion')
check(managedRows['managed:root']==nil and managedRows['managed:user']~=nil and managedRows['managed:id']==nil,'normal managed setup exposes existing POSIX account selection without transport-path or stable-ID internals')
do -- model and effort on the managed setup form
 check(managedRows['managed:model']~=nil and managedRows['managed:effort']~=nil and managedRows['managed:effort'].control.k=='choice','setup form offers model and effort for a CLI that has both flags (omp)')
 local before=state.managed_draft.model
 definition.event(state,{ev='change',item='managed:model',value='anthropic/claude-sonnet-5-5'},cx)
 definition.event(state,{ev='change',item='managed:effort',value='medium'},cx)
 check(state.managed_draft.model=='anthropic/claude-sonnet-5-5' and state.managed_draft.effort=='medium','typed model and chosen effort land on the setup draft')
 definition.event(state,{ev='change',item='managed:model',value=before or ''},cx)
 definition.event(state,{ev='change',item='managed:effort',value=''},cx)
end
do
 local baseline=clone(saved);local request=assert(state.managed_native_request)
 state.managed_draft_touched=nil
 definition.event(state,{ev='action',id='main',act='spawn.native-accounts',value=runtime.json.encode({nonce=request.nonce,window=state.native_window,choices={{label='Tern default agent',command='sudo -n -u selected -H -- /tools/native --profile work'}}})},cx)
 check(state.managed_native_choices and #state.managed_native_choices==1 and P.equal(saved,baseline),'native route discovery has no setup or roster effects')
 check(state.managed_draft.user=='selected' and state.managed_native_selected=='1','an untouched new draft follows the actual configured default account instead of inventing a current-user OMP record')
 definition.event(state,{ev='change',item='managed-native',value='1'},cx)
 check(state.managed_draft.user=='selected' and state.managed_draft.executable=='/tools/native' and state.managed_draft.arguments==C.render_arguments({'--profile','work'}),'explicit native route selection reads configured POSIX identity and exact fresh argv')
 check(P.equal(saved,baseline) and state.managed_record==nil,'native account selection neither recreates saved agents nor claims readiness')
 definition.event(state,{ev='change',item='managed:user',value='explicit-account'},cx)
 state.managed_native_request={nonce='second-native-discovery',window=state.native_window}
 definition.event(state,{ev='action',id='main',act='spawn.native-accounts',value=runtime.json.encode({nonce='second-native-discovery',window=state.native_window,choices={{label='Tern default agent',command='sudo -n -u other -H -- /tools/other'}}})},cx)
 check(state.managed_draft.user=='explicit-account' and P.equal(saved,baseline),'late native default discovery never overwrites an explicit user choice or saved roster')
 local unchangedDraft=clone(state.managed_draft)
 state.managed_native_choices={{label='Native agent pane 42',command='sudo -n -u selected -H -- omp --restore existing-session'}}
 definition.event(state,{ev='change',item='managed-native',value='1'},cx)
 check(state.notice:find('Fresh native route required',1,true) and P.equal(state.managed_draft,unchangedDraft) and P.equal(saved,baseline) and state.managed_record==nil and state.managed_route==nil,'selecting an active restore route leaves both draft and saved roster unchanged, creates no setup resources or diagnostic, and asks for an explicit fresh route')
 definition.event(state,{ev='change',item='managed-existing',value=''},cx)
end
before=clone(saved)
definition.event(state,{ev='change',item='managed:cwd',value='/fixture/repository'},cx)
definition.event(state,{ev='change',item='managed:executable',value='/fixture/worker'},cx)
check(P.equal(before,saved) and state.managed_draft.cwd=='/fixture/repository','native typed fields are disposable drafts, not authority writes')
definition.event(state,{ev='action',act='managed-route-probe@'..state.snapshot.config_revision},cx)
check(P.equal(before,saved) and rows_of('managed')['managed-notice'] and state.managed_route==nil,'native diagnostic cannot bypass missing machine prerequisites')
local managedModule=modules.managed_setup
local originalPrepare=managedModule.prepare
local pendingProbe=nil
managedModule.prepare=function(draft,context,callback)
 check(draft.cwd=='/fixture/repository' and context.host_os~=nil,'native probe receives selected draft and actual host context')
 pendingProbe=callback
end
local probeRevision=state.snapshot.config_revision
definition.event(state,{ev='action',act='managed-probe@'..probeRevision},cx)
check(P.equal(before,saved),'Prepare agent does not change setup lifecycle or roster before selected-account prerequisites succeed')
probeRevision=state.snapshot.config_revision
check(state.managed_busy and pendingProbe~=nil,'probe waits for actual asynchronous observations')
definition.event(state,{ev='action',act='managed-probe@'..probeRevision},cx)
check(state.managed_busy,'a second click cannot duplicate an in-flight probe')
local concurrentRoster=clone(snapshot().records);concurrentRoster[1].account_label='manual-edit-during-probe'
check(A.edit(state.binding,probeRevision,'replace-records',{records=concurrentRoster}),'manual authority writer advances the same config revision')
before=clone(saved)
pendingProbe(nil,{passed=true,observations={}},nil)
check(not state.managed_busy and state.managed_probe==nil and P.equal(before,saved),'concurrent manual edit invalidates probe results without overwriting records')
do
 local staleDraft,staleRevision=clone(state.managed_draft),state.managed_draft_revision
 pendingProbe=nil
 definition.event(state,{ev='action',act='managed-probe@'..state.snapshot.config_revision},cx)
 check(not state.managed_busy and state.notice:find('stale%-config') and pendingProbe==nil and P.equal(state.managed_draft,staleDraft) and state.managed_draft_revision==staleRevision and staleRevision~=state.snapshot.config_revision and P.equal(before,saved),'refreshing the form cannot rebase an old draft onto manual changes or start another resource probe')
end
definition.event(state,{ev='change',item='managed-existing',value='editable'},cx)
check(state.managed_draft.account_label=='manual-edit-during-probe' and state.managed_draft_revision==state.snapshot.config_revision,'explicit selection adopts current saved values and revision')
managedModule.prepare=function(_,_,callback)callback(nil,nil,'Fixture resource permission denied')end
before=clone(saved)
definition.event(state,{ev='action',act='managed-probe@'..state.snapshot.config_revision},cx)
check(P.equal(before,saved) and state.managed_probe==nil and not state.managed_busy and rows_of('managed')['managed-notice'],'actual resource failure reaches native Managed setup preferences without creating an attested record')
managedModule.prepare=function(_,_,callback)callback(clone(snapshot().records[1]),{passed=true,observations={}},nil)end
definition.event(state,{ev='action',act='managed-probe@'..state.snapshot.config_revision},cx)
check(snapshot().setup.state=='in_progress' and state.managed_probe.passed,'successful offline resource preparation begins setup without launching a paid diagnostic')
managedModule.prepare=originalPrepare
-- Actual native boundary proof is asynchronous; only Authority retains its cleanup obligation.
local originalClients=clone(inventory.clients)
inventory.clients={{kind='window',window='',conn=101,since=1700000000001},{kind='window',window='',conn=202,since=1700000000002}}
state.native_window=''
state.managed_record=clone(snapshot().records[1])
state.managed_probe={schema=1,passed=true,record_sha256=string.rep('a',64),observations={},provision_handle='setup-fixture-native'}
state.managed_probe_revision=state.snapshot.config_revision
local nativeRevision=state.snapshot.config_revision
local consentRecipient={window='',native_namespace='desktop-alpha',native_conn=11,native_since=1700000000011}
local function consentEvent(challenge,extra)
 local value=clone(consentRecipient);value.nonce=challenge.nonce;value.config_revision=challenge.revision;value.window_consent='window-consent-'..challenge.nonce
 for key,item in pairs(extra or {}) do value[key]=item end
 definition.event(state,{ev='action',act='managed-route-consent',value=runtime.json.encode(value)},cx)
end
local intentCount=#intents()
definition.event(state,{ev='action',act='managed-route-probe@'..nativeRevision},cx)
local challenge=assert(state.managed_route_consent)
check(opened[#opened]=='tern-spawn://managed-route/7/'..nativeRevision..'/'..challenge.nonce and saved.authority.setup_probe==nil and state.managed_route==nil,'button synchronously directs consent to the clicking native client before durable launch authority')
check(definition.save(state).managed_route_consent==nil,'reload cannot persist a pending launch consent')
local consentBaseline=clone(saved)
for _,extra in ipairs({{nonce='wrong-consent'},{config_revision=nativeRevision+1},{window_consent=''},{window_consent=false}}) do
 consentEvent(challenge,extra)
 check(P.equal(saved,consentBaseline) and state.managed_route==nil,'invalid challenge or missing desktop consent cannot claim a diagnostic')
end
local consentNow=fake.now
fake.now=function()return challenge.deadline+1 end
consentEvent(challenge)
check(P.equal(saved,consentBaseline) and state.managed_route==nil,'expired consent grants no launch authority')
fake.now=consentNow
definition.event(state,{ev='action',act='managed-route-probe@'..nativeRevision},cx)
challenge=assert(state.managed_route_consent)
consentEvent(challenge)
local nativeRoute=assert(state.managed_route)
check(saved.authority.setup_probe and saved.authority.setup_probe.nonce==challenge.nonce and state.managed_route_consent==nil,'exact directed consent is consumed into one durable cleanup obligation')
check(nativeRoute.window_consent=='window-consent-'..challenge.nonce and saved.authority.setup_probe.window_consent==nativeRoute.window_consent,'consumed consent echoes and persists the requesting WINDOW handler token')
check(nativeRoute.native_namespace==consentRecipient.native_namespace and nativeRoute.native_conn==11 and nativeRoute.native_since==1700000000011 and nativeRoute.native_session==1 and nativeRoute.source_pane==7,'desktop recipient incarnation is independent of both remote native clients and host pane identity')
check(snapshot().config_revision==nativeRevision and #intents()==intentCount,'two remote clients sharing the empty window key require no global window selection or broadcast intent')
local replayBaseline=clone(saved);local replayWrites=writes
consentEvent(challenge)
check(P.equal(saved,replayBaseline) and writes==replayWrites and state.managed_route==nativeRoute,'replayed consent cannot claim or replace the diagnostic')
consentEvent(challenge,{window_consent='reloaded-window-consent'})
check(P.equal(saved,replayBaseline) and writes==replayWrites and nativeRoute.window_consent=='window-consent-'..challenge.nonce,'replayed directed URL cannot echo a reloaded WINDOW handler token')
local function routeEvent(act,extra)
 local value=clone(consentRecipient);value.nonce=nativeRoute.nonce;value.pane=909
 for key,item in pairs(extra or {}) do value[key]=item end
 definition.event(state,{ev='action',act=act,value=runtime.json.encode(value)},cx)
end
routeEvent('managed-route-preflight',{pane=0})
check(nativeRoute.launch_ready and nativeRoute.launch_ready.native_conn==11 and nativeRoute.launch_ready.native_since==1700000000011,'fresh preflight authorizes the exact consenting desktop incarnation despite duplicate remote window keys')
table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd})
for _,extra in ipairs({{native_namespace='desktop-beta'},{native_conn=12},{native_since=1700000000012}}) do
 before=clone(saved)
 routeEvent('managed-route-started',extra)
 check(P.equal(before,saved) and saved.authority.setup_probe.window_pane==nil and not nativeRoute.observing,'foreign desktop incarnation cannot bind or observe a diagnostic')
end
local originalObserve=managedModule.observe_route
local pendingNative
managedModule.observe_route=function(route,session,pane,callback)
 check(route.nonce==nativeRoute.nonce and session==1 and pane==9,'actual observer is fenced to original native scope')
 pendingNative=callback
end
routeEvent('managed-route-started')
check(saved.authority.setup_probe.pane==9 and saved.authority.setup_probe.window_pane==909 and nativeRoute.owned_pane==9,'host command discovery binds native pane 9 independently of desktop SDK pane 909')
routeEvent('managed-route-observed')
check(pendingNative~=nil and saved.authority.setup_probe~=nil,'provider boundary readback does not discard unfinished cleanup')
pendingNative(nil,'Fixture observation is only partially published',true)
local nextNativeRead=timers[#timers]
check(nativeRoute.status=='running' and nativeRoute.observing and nextNativeRead.ms==250,'partial terminal output remains pending and schedules only bounded readback')
pendingNative=nil;nextNativeRead.callback()
check(pendingNative~=nil and nativeRoute.status=='running' and snapshot().config_revision==nativeRevision,'slow terminal producer is reread without another launch or settings revision')
local changedDuringNative=clone(snapshot().records);changedDuringNative[1].account_label='manual-edit-during-native'
check(A.edit(state.binding,nativeRevision,'replace-records',{records=changedDuringNative}),'concurrent manual edit advances settings while native cleanup remains owed')
pendingNative('Explicit deterministic native-boundary test observation',nil)
check(nativeRoute.status=='failed' and saved.authority.setup_probe~=nil,'late native observation cannot bless a changed config or clear its worker obligation')
table.remove(inventory.sessions[1].tabs[1].blocks)
before=clone(saved)
routeEvent('managed-route-finished',{pane=9,cleaned=true,error='Wrong identity domain'})
check(P.equal(saved,before) and saved.authority.setup_probe.window_pane==909,'native pane ID cannot substitute for the bound SDK cleanup echo')
routeEvent('managed-route-finished',{cleaned=true,error='Configuration changed'})
check(saved.authority.setup_probe==nil and nativeRoute.status=='failed' and snapshot().setup.state=='in_progress','independent native absence clears only the obligation, never fabricates setup completion')
managedModule.observe_route=originalObserve
definition.event(state,{ev='change',item='managed-existing',value='editable'},cx)
local function nextNativeFixture(handle)
 definition.event(state,{ev='change',item='managed-existing',value='editable'},cx)
 state.managed_record=clone(snapshot().records[1])
 state.managed_record.mailbox.verified=false
 local observations={}
 for _,id in ipairs({'launch-construction','account-cli-folder-dependencies','serializer-argv','helper-provision','provision-readback'}) do table.insert(observations,{id=id,state='passed',summary='Explicit deterministic boundary fixture'}) end
 state.managed_probe={schema=1,passed=true,record_sha256=load('wire/codec').sha256(runtime.json.encode(state.managed_record)),observations=observations,provision_handle=handle,bundle_digest=string.rep('b',64),worker_identity=state.managed_record.mailbox.worker_identity}
 state.managed_probe_revision=state.snapshot.config_revision
 definition.event(state,{ev='action',act='managed-route-probe@'..state.snapshot.config_revision},cx)
 consentEvent(assert(state.managed_route_consent))
 nativeRoute=assert(state.managed_route)
end
nextNativeFixture('setup-fixture-unbound')
routeEvent('managed-route-preflight',{pane=0,native_conn=12})
check(nativeRoute.launch_ready==nil and saved.authority.setup_probe~=nil,'changed callback incarnation refuses preflight before authorizing an effect')
before=clone(saved)
inventory.sessions[1].tabs[1].blocks[1].id=700
routeEvent('managed-route-preflight',{pane=0})
check(P.equal(before,saved) and nativeRoute.launch_ready==nil,'loss of the captured HOST source pane refuses launch even with the exact desktop recipient')
inventory.sessions[1].tabs[1].blocks[1].id=7
routeEvent('managed-route-finished',{pane=0,cleaned=true,error='No pane currently visible'})
check(saved.authority.setup_probe~=nil and saved.authority.setup_probe.pane==nil and not nativeRoute.discovery_complete,'zero inventory cannot settle an unbound uncertain native start')
table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd})
routeEvent('managed-route-started')
check(saved.authority.setup_probe.pane==9,'late positively discovered native command is bound even for cleanup-only recovery')
table.remove(inventory.sessions[1].tabs[1].blocks)
routeEvent('managed-route-finished',{cleaned=true,error='Uncertain owned actor settled'})
check(saved.authority.setup_probe==nil,'positive binding followed by native absence can settle the formerly uncertain obligation')
for _,identity in ipairs({'wrong-command','wrong-cwd','absent','foreign-session','ambiguous'}) do
 nextNativeFixture('setup-fixture-'..identity)
 routeEvent('managed-route-preflight',{pane=0})
 if identity=='foreign-session' then
  inventory.sessions[2]={id=2,tabs={{blocks={{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd}}}}}
 elseif identity~='absent' then
  table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=if identity=='wrong-command' then 'unrelated-live-command' else nativeRoute.command,cwd=if identity=='wrong-cwd' then '/foreign-cwd' else nativeRoute.cwd})
  if identity=='ambiguous' then table.insert(inventory.sessions[1].tabs[1].blocks,{id=10,command=nativeRoute.command,cwd=nativeRoute.cwd}) end
 end
 before=clone(saved)
 managedModule.observe_route=function()error('Unverified diagnostic must not read output')end
 routeEvent('managed-route-started')
 check(P.equal(before,saved) and saved.authority.setup_probe.pane==nil and nativeRoute.pane==nil and nativeRoute.owned_pane==nil and not nativeRoute.observing,'unverified started event cannot persist or cache native ownership or read output: '..identity)
 if identity=='foreign-session' then inventory.sessions[2]=nil
 elseif identity~='absent' then
  table.remove(inventory.sessions[1].tabs[1].blocks)
  if identity=='ambiguous' then table.remove(inventory.sessions[1].tabs[1].blocks) end
 end
 routeEvent('managed-route-finished',{cleaned=true})
 check(P.equal(before,saved) and saved.authority.setup_probe.pane==nil and not nativeRoute.discovery_complete,'later empty inventory cannot settle a rejected native identity: '..identity)
 table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd})
 refresh()
 check(saved.authority.setup_probe.pane==9 and nativeRoute.owned_pane==9,'owner reload can still positively bind the exact late diagnostic for cleanup: '..identity)
 routeEvent('managed-route-started')
 check(saved.authority.setup_probe.window_pane==909,'recovered native identity still requires a separate exact SDK pane binding')
 table.remove(inventory.sessions[1].tabs[1].blocks)
 routeEvent('managed-route-finished',{cleaned=true,error='Rejected start later positively recovered'})
 check(saved.authority.setup_probe==nil and nativeRoute.status=='failed','positive recovery and native absence clear cleanup without blessing rejected output: '..identity)
 managedModule.observe_route=originalObserve
end
nextNativeFixture('setup-fixture-deadline')
routeEvent('managed-route-preflight',{pane=0})
table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd})
local observationReads=0
managedModule.observe_route=function(_,_,_,callback)observationReads+=1;callback(nil,'Incomplete fixture bytes',true)end
routeEvent('managed-route-started')
routeEvent('managed-route-observed')
local deadlineRead=timers[#timers];local originalNow=fake.now;local deadlineNow=originalNow()+45001
fake.now=function()return deadlineNow end
deadlineRead.callback()
check(observationReads==2 and nativeRoute.status=='failed' and saved.authority.setup_probe~=nil,'terminal read-only pending state ends at the existing diagnostic deadline without clearing cleanup')
fake.now=originalNow;managedModule.observe_route=originalObserve
table.remove(inventory.sessions[1].tabs[1].blocks)
routeEvent('managed-route-finished',{cleaned=true,error='Diagnostic observation deadline elapsed'})
check(saved.authority.setup_probe==nil,'deadline failure still requires positively owned native settlement')
nextNativeFixture('setup-fixture-exited')
routeEvent('managed-route-preflight',{pane=0})
local exitedRead
managedModule.observe_route=function(_,_,_,callback)exitedRead=callback end
table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd})
routeEvent('managed-route-started')
check(exitedRead~=nil and nativeRoute.observing,'positively bound terminal starts output observation without a second window event')
table.remove(inventory.sessions[1].tabs[1].blocks)
exitedRead('Exact terminal output observed after native exit',nil)
routeEvent('managed-route-finished',{cleaned=true})
check(nativeRoute.status=='passed' and saved.authority.setup_probe==nil,'fast terminal exit after positive binding settles only after exact output and independent native absence')
check(snapshot().setup.state=='adopted_existing' and snapshot().records[1].mailbox.verified and state.notice:find('Saved agent setup',1,true),'positive native cleanup automatically saves the exact verified record without another human confirmation')
local committedRevision=snapshot().config_revision
routeEvent('managed-route-finished',{cleaned=true})
check(snapshot().config_revision==committedRevision,'duplicate cleanup callback cannot save setup twice')
check(snapshot().setup.readiness.state=='not_run','machine route verification never certifies provider readiness')
do
 definition.event(state,{ev='change',item='managed-existing',value='editable'},cx)
 local prepares=0;local completePreparation
 managedModule.prepare=function(_,_,callback)prepares+=1;completePreparation=callback end
 local batchRevision=state.snapshot.config_revision
 definition.event(state,{ev='action',act='managed-prepare@'..batchRevision},cx)
 local batch=assert(state.managed_batch)
 check(batch.status=='awaiting_consent' and prepares==0 and saved.authority.setup_probe==nil,'one-action setup captures clicked-window approval before resource effects or native launch')
 local batchConsent=clone(consentRecipient)
 batchConsent.nonce=batch.nonce;batchConsent.config_revision=batchRevision;batchConsent.consents={{nonce=batch.entries[1].nonce,window_consent='exact-selected-account-consent'}}
 definition.event(state,{ev='action',act='managed-prepare-consent',value=runtime.json.encode(batchConsent)},cx)
 definition.event(state,{ev='action',act='managed-prepare@'..batchRevision},cx)
 check(prepares==1 and batch.status=='preparing' and state.managed_route==nil,'approved combined action prepares exactly once and does not launch before actual observations')
 local proposed=clone(snapshot().records[1]);proposed.mailbox.verified=false
 local observations={}
 for _,id in ipairs({'launch-construction','account-cli-folder-dependencies','serializer-argv','helper-provision','provision-readback'}) do table.insert(observations,{id=id,state='passed',summary='Observed deterministic resource boundary'}) end
 local proof={schema=1,passed=true,record_sha256=load('wire/codec').sha256(runtime.json.encode(proposed)),observations=observations,provision_handle='setup-one-action',bundle_digest=string.rep('b',64),worker_identity=proposed.mailbox.worker_identity}
 completePreparation(proposed,proof,nil)
 nativeRoute=assert(state.managed_route)
 check(batch.status=='verifying' and nativeRoute.nonce==batch.entries[1].nonce and nativeRoute.window_consent=='exact-selected-account-consent' and nativeRoute.config_revision==batchRevision,'preparation hands the same approved per-record nonce/revision to real diagnostic authority')
 managedModule.observe_route=function(_,_,_,callback)callback('Exact deterministic offline output',nil)end
 routeEvent('managed-route-preflight',{pane=0})
 table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd})
 routeEvent('managed-route-started')
 table.remove(inventory.sessions[1].tabs[1].blocks)
 routeEvent('managed-route-finished',{cleaned=true})
 check(batch.status=='waiting_next' and #batch.saved==1 and snapshot().config_revision==batchRevision+1 and snapshot().records[1].mailbox.verified,'observed cleanup commits and reads back the exact prepared record automatically')
 local nextReceipt=clone(consentRecipient);nextReceipt.nonce=nativeRoute.nonce;nextReceipt.window_consent='exact-selected-account-consent'
 definition.event(state,{ev='action',act='managed-prepare-next',value=runtime.json.encode(nextReceipt)},cx)
 check(batch.status=='completed' and #batch.saved==1 and state.managed_probe==nil and prepares==1,'exact native completion receipt finishes required setup without another user action')
 local savedRevision=snapshot().config_revision
 definition.event(state,{ev='action',act='managed-prepare-consent',value=runtime.json.encode(batchConsent)},cx)
 definition.event(state,{ev='action',act='managed-prepare-next',value=runtime.json.encode(nextReceipt)},cx)
 check(snapshot().config_revision==savedRevision and prepares==1,'duplicate approvals/completion receipts neither prepare nor save again')
 local beforeFailure=snapshot().config_revision
 definition.event(state,{ev='action',act='managed-prepare@'..beforeFailure},cx)
 local interruptedBatch=assert(state.managed_batch)
 batchConsent.nonce=interruptedBatch.nonce;batchConsent.config_revision=beforeFailure;batchConsent.consents={{nonce=interruptedBatch.entries[1].nonce,window_consent='second-exact-account-consent'}}
 definition.event(state,{ev='action',act='managed-prepare-consent',value=runtime.json.encode(batchConsent)},cx)
 check(prepares==2 and interruptedBatch.status=='preparing','a new explicit action gets its own resource preparation and distinct consent')
 check(A.setup_edit(state.host_key,beforeFailure,'readiness',{state='not_run',summary='Concurrent revision fixture'}),'concurrent setup revision changes through the normal writer')
 completePreparation(proposed,proof,nil)
 check(interruptedBatch.status=='failed' and state.managed_route==nil and saved.authority.setup_probe==nil and snapshot().config_revision==beforeFailure+1,'configuration drift cancels the whole remaining approval without a native diagnostic or fabricated save')
 managedModule.prepare=originalPrepare
end
managedModule.observe_route=originalObserve
inventory.clients=originalClients;state.native_window='fixture-window'
do
 local baselineRecords=clone(snapshot().records)
 local preparationCalls=0
 managedModule.prepare=function()preparationCalls+=1;error('Blocked prerequisite reached resource preparation')end
 for _,id in ipairs({'off','needs'}) do
  definition.event(state,{ev='change',item='managed-existing',value=id},cx)
  local baseline=clone(saved);local opens=#opened
  definition.event(state,{ev='action',act='managed-prepare@'..state.snapshot.config_revision},cx)
  check(preparationCalls==0 and #opened==opens and P.equal(saved,baseline),'disabled/review-gated record refuses before resource effects or native consent: '..id)
 end
 definition.event(state,{ev='change',item='managed-existing',value='off'},cx)
 local disabled=clone(state.managed_draft.source_record)
 definition.event(state,{ev='action',act='managed-enable:off@'..state.snapshot.config_revision},cx)
 disabled.enabled=true
 check(P.equal(state.managed_draft.source_record,disabled) and preparationCalls==0,'explicit Enable agent changes only the enabled choice and launches no checks')
 local withSSH=clone(baselineRecords)
 for _,record in ipairs(withSSH) do if record.id=='other' then record.backend='ssh-command';record.host='localhost';record.user='existing-target-account' end end
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=withSSH}),'fixture retains an SSH alias without claiming endpoint identity')
 refresh();definition.event(state,{ev='change',item='managed-existing',value='other'},cx)
 local baseline=clone(saved);local opens=#opened
 definition.event(state,{ev='action',act='managed-prepare@'..state.snapshot.config_revision},cx)
 check(state.managed_draft.backend=='ssh-command' and P.equal(saved,baseline) and preparationCalls==0 and #opened==opens,'localhost spelling never converts a retained SSH destination or authorizes account/model preparation')
 local withSudo=clone(baselineRecords)
 local sudoRoute=record('sudo-route')
 sudoRoute.command='sudo';sudoRoute.arguments={'-n','-u','selected','-H','/tools/worker','--auto-approve'}
 sudoRoute.task_argument_index=7;sudoRoute.cwd='/fixture/repository'
 table.insert(withSudo,sudoRoute)
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=withSudo}),'fixture saves a literal same-host sudo terminal route')
 refresh();definition.event(state,{ev='change',item='managed-existing',value='sudo-route'},cx)
 check(state.managed_draft.backend=='local-terminal' and state.managed_draft.user=='selected' and state.managed_draft.executable=='/tools/worker' and state.managed_draft.task_argument_index=='2' and state.managed_draft.arguments==C.render_arguments({'--auto-approve'}),'saved-agent selection reviews the actual embedded account and worker argv rather than preparing host-owned transport or changing backend')
 check(state.managed_draft.source_record.user==nil and P.equal(state.managed_draft.source_record.arguments,sudoRoute.arguments) and preparationCalls==0,'account canonicalization is a disposable review draft, not an in-place saved or active transport rewrite')
 sudoRoute.fresh_executable='sudo';sudoRoute.fresh_arguments={'-n','-u','other','-H','/tools/worker','--auto-approve'}
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=withSudo}),'fixture retains inconsistent fresh and ordinary OS selectors for explicit review')
 refresh();definition.event(state,{ev='change',item='managed-existing',value='sudo-route'},cx)
 baseline=clone(saved);opens=#opened
 definition.event(state,{ev='action',act='managed-prepare@'..state.snapshot.config_revision},cx)
 check(state.managed_draft.source_record.id=='sudo-route' and state.managed_draft.preparation_error and state.notice:find('different OS accounts',1,true) and preparationCalls==0 and #opened==opens and P.equal(saved,baseline),'inconsistent saved accounts remain visible in their selected draft and refuse before consent, resources or current-user fallback')
 check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=baselineRecords}),'restore fixture records through normal writer')
 refresh();managedModule.prepare=originalPrepare
end
definition.event(state,{ev='change',item='managed-existing',value='editable'},cx)
-- Removed human attestations cannot manufacture observations or save settings.
state.managed_probe={passed=true,record_sha256=string.rep('a',64),observations={}}
state.managed_probe_revision=state.snapshot.config_revision
before=clone(saved)
for _,op in ipairs({'managed-attest','managed-cli-attest','managed-adopt'}) do
 definition.event(state,{ev='action',act=op..'@'..state.snapshot.config_revision},cx)
 check(P.equal(before,saved),'obsolete human attestation cannot commit machine setup: '..op)
end
definition.event(state,{ev='change',item='managed:arguments',value='--changed-flags'},cx)
check(state.managed_probe==nil and P.equal(before,saved),'editing CLI flags invalidates the exact machine probe without changing the saved record')
definition.event(state,{ev='action',act='managed-exercise@'..state.snapshot.config_revision},cx)
check(intents()[1].kind=='readiness' and intents()[1].native_window=='fixture-window' and snapshot().setup.readiness.state=='not_run','optional readiness is an owner-window-addressed native intent, never a fabricated success')
-- Owner-only page receiver: native handoff follows ordinary Config bootstrap gates.
local pageBefore=clone(saved);local pageSnapshotBefore=snapshot();local setupBefore=clone(pageSnapshotBefore.setup)
local pageState=definition.init(cx,{runtime.json.encode(publicPage)},definition.save(state))
check(pageState.binding==nil and P.equal(saved,pageBefore),'opening the public page cannot initialize or import an authority')
local oldContextNonce=pageState.page_context_request.nonce
definition.event(pageState,{ev='action',act='refresh'},cx)
check(pageState.page_context_request.nonce~=oldContextNonce and P.equal(saved,pageBefore),'explicit refresh requests a new view-local owner context without writes')
local ownerLegacy={schema=1,agents={record('owner-window-legacy')}}
local ownerContext={kind='context',native_window='fixture-window',host={id=0,name='fixture',kind='local'},client_config=ownerLegacy}
definition.event(pageState,{ev='action',id='main',act='spawn.page-context',value=runtime.json.encode({nonce=oldContextNonce,context=ownerContext})},cx)
check(pageState.binding==nil and P.equal(saved,pageBefore),'stale context responses cannot open or import settings')
local wrongContext=clone(ownerContext);wrongContext.native_window='foreign-window'
definition.event(pageState,{ev='action',id='main',act='spawn.page-context',value=runtime.json.encode({nonce=pageState.page_context_request.nonce,context=wrongContext})},cx)
check(pageState.binding==nil and P.equal(saved,pageBefore),'foreign native context is refused before owner bootstrap')
holdInspection=true
definition.event(pageState,{ev='action',id='main',act='spawn.page-context',value=runtime.json.encode({nonce=pageState.page_context_request.nonce,context=ownerContext})},cx)
check(deferred~=nil and pageState.binding==nil,'owner bootstrap waits for actual native membership verification')
definition.event(pageState,{ev='action',id='main',act='page-entry',value=runtime.json.encode(publicPage)},cx)
holdInspection=false;local obsoleteContext=deferred;deferred=nil
obsoleteContext({status=0,timed_out=false,stdout=runtime.json.encode(inventory)},nil)
check(pageState.binding==nil and P.equal(saved,pageBefore),'new page entry invalidates a context callback still awaiting native membership')
local ownerOpen=A.open;local receivedLegacy
A.open=function(host,session,client,scope)receivedLegacy=clone(client);return ownerOpen(host,session,client,scope)end
definition.event(pageState,{ev='action',id='main',act='spawn.page-context',value=runtime.json.encode({nonce=pageState.page_context_request.nonce,context=ownerContext})},cx)
A.open=ownerOpen
check(pageState.binding~=nil and P.equal(receivedLegacy,ownerLegacy),'only SPAWN owner context reaches its existing authoritative bootstrap writer')
local pageSnapshot=assert(A.snapshot(pageState.binding))
check(pageSnapshot.setup.schema==setupBefore.schema and pageSnapshot.setup.state==setupBefore.state and P.equal(pageSnapshot.setup.readiness,setupBefore.readiness) and pageSnapshot.adoption_required==pageSnapshotBefore.adoption_required,'owner page bootstrap preserves lifecycle, adoption and observed readiness')
check(#pageSnapshot.attempts==#pageSnapshotBefore.attempts and P.equal(pageSnapshot.jobs,pageSnapshotBefore.jobs),'owner page bootstrap creates no attempts or execution jobs')
check(pageSnapshot.setup.config_revision==pageSnapshot.config_revision and pageSnapshot.config_revision>pageSnapshotBefore.config_revision,'legacy source review advances the authoritative setup revision fence')
check(not pageSnapshot.ready and pageSnapshot.migration~=nil and P.equal(pageSnapshot.records,pageSnapshotBefore.records),'owner legacy copy enters normal migration review without replacing host records')
local migrationChoices,migrationFields,migrationConfirm=0,0,false
for _,section in ipairs(definition.view(pageState,cx).main.children[1].p.sections)do
 for _,item in ipairs(section.rows)do
  if item.control.k=='choice' and item.id:match('^review:') then migrationChoices+=1 end
  if item.id:match('^source%-') then migrationFields+=1 end
  if item.id=='review-confirm' then migrationConfirm=item.control.act=='review-confirm@'..pageSnapshot.config_revision end
 end
end
check(migrationChoices>0 and migrationFields>migrationChoices and migrationConfirm,'source conflict review preserves deliberate per-ID choices, complete readable fields and revision-bound confirmation')
local afterOwner=clone(saved)
definition.event(pageState,{ev='action',id='main',act='page-entry',value=runtime.json.encode({kind='page',page='managed',native_window='foreign-window'})},cx)
check(P.equal(saved,afterOwner) and pageState.native_window=='fixture-window','existing Config refuses a foreign native-window page entry instead of rebinding')
end
do
-- Ordinary clicks use the existing saved HOST pending queue, not per-window IDs.
local J=load('window_journal')
local claimInventory={clients={{kind='window',window='fixture-window',conn=1,since=10},{kind='window',window='second-window',conn=2,since=20}},sessions={{id=1,tabs={{blocks={{id=7}}}}}}}
local claimResult={status=0,timed_out=false,stdout=runtime.json.encode(claimInventory)}
local firstRecipient=assert(J.open('fixture-window',claimResult)).recipient
local secondRecipient=assert(J.open('second-window',claimResult)).recipient
local intentState={page='spawn',host_key='host:fixture',origin_session=1,intents={{intent_id='ordinary-once',kind='record',record_id='editable',config_revision=1}}}
local durable,saveCount=nil,0
local claimCx={pane=7,render=function()end,save=function()
 saveCount+=1;durable=clone(definition.save(intentState))
end}
local function recipientEvent(kind,recipient)
 local body=clone(recipient);body.intent_id='ordinary-once'
 body.queue_id=intentState.intent_queue_id
 return {ev='action',id='main',act='spawn.launch-intent-'..kind,value=runtime.json.encode(body)}
end
local nativeInspect=modules.native_cli.inspect
local claimCallbacks={}
modules.native_cli.inspect=function(_,_,callback)table.insert(claimCallbacks,callback)end
definition.event(intentState,recipientEvent('claim',firstRecipient),claimCx)
definition.event(intentState,recipientEvent('claim',secondRecipient),claimCx)
check(#claimCallbacks==2 and intentState.intents[1].recipient==nil and durable==nil,'two windows cannot execute before HOST completes native claim inspection')
claimCallbacks[2](claimResult,nil);claimCallbacks[1](claimResult,nil)
check(saveCount==1 and J.same_recipient(intentState.intents[1].recipient,secondRecipient) and J.same_recipient(durable.intents[1].recipient,secondRecipient),'first completed HOST claim persists one recipient before publication; competing callback cannot overwrite it')
definition.event(intentState,recipientEvent('ack',firstRecipient),claimCx)
check(#intentState.intents==1 and saveCount==1,'another window cannot acknowledge or discard the assigned click')
modules.native_cli.inspect=nativeInspect
local restoredIntent=definition.init(cx,{runtime.json.encode({host={name='fixture'},native_window='fixture-window'})},durable)
check(J.same_recipient(restoredIntent.intents[1].recipient,secondRecipient),'HOST pane reload retains the original assigned incarnation without rebinding')
definition.event(intentState,recipientEvent('ack',secondRecipient),claimCx)
check(#intentState.intents==0 and #durable.intents==0 and saveCount==2,'exact recipient ACK reclaims the live pending click durably')
definition.event(intentState,recipientEvent('claim',firstRecipient),claimCx)
check(#intentState.intents==0 and saveCount==2,'a delayed claim cannot recreate an acknowledged click')
intentState.intents={{intent_id='ordinary-once',kind='record',record_id='editable',config_revision=1}}
modules.native_cli.inspect=function(_,_,callback)callback(claimResult,nil)end
claimCx.save=function()error('durable pane save failed')end
definition.event(intentState,recipientEvent('claim',firstRecipient),claimCx)
check(intentState.intents[1].recipient==nil and intentState.notice:find('could not be persisted')~=nil,'failed HOST save publishes no executable recipient')
claimCx.save=function()saveCount+=1 end
local incomplete=clone(claimResult);incomplete.stdout_truncated=true
modules.native_cli.inspect=function(_,_,callback)callback(incomplete,nil)end
definition.event(intentState,recipientEvent('claim',firstRecipient),claimCx)
check(intentState.intents[1].recipient==nil,'incomplete native inspection never assigns an ordinary intent')
-- A remote execution host sees SSH client lifetimes, never the desktop's
-- window lifetime or journal namespace. Two desktops may share a window key.
intentState.native_window='fixture-window'
claimCx.save=function()saveCount+=1;durable=clone(definition.save(intentState))end
local remoteInventory={clients={{kind='remote',window='fixture-window',conn=71,since=700},{kind='remote',window='fixture-window',conn=72,since=800}},sessions=clone(claimInventory.sessions)}
local remoteResult={status=0,timed_out=false,stdout=runtime.json.encode(remoteInventory)}
modules.native_cli.inspect=function(_,_,callback)callback(remoteResult,nil)end
definition.event(intentState,recipientEvent('claim',firstRecipient),claimCx)
check(J.same_recipient(intentState.intents[1].recipient,firstRecipient) and J.same_recipient(durable.intents[1].recipient,firstRecipient),
 'remote Guided setup retains the desktop recipient independently of remote connection numbers')
definition.event(intentState,recipientEvent('claim',secondRecipient),claimCx)
definition.event(intentState,recipientEvent('ack',secondRecipient),claimCx)
check(#intentState.intents==1 and J.same_recipient(intentState.intents[1].recipient,firstRecipient),
 'another desktop cannot replace or acknowledge an assigned remote click')
definition.event(intentState,recipientEvent('ack',firstRecipient),claimCx)
check(#intentState.intents==0,'the assigned remote desktop can acknowledge its completed click')
for _,fault in ipairs({'truncated','wrong-window','missing-source'}) do
 intentState.intents={{intent_id='ordinary-once',kind='setup',config_revision=1}}
 local bad=clone(remoteResult)
 if fault=='truncated' then bad.stdout_truncated=true
 else
  local inv=clone(remoteInventory)
  if fault=='wrong-window' then for _,client in ipairs(inv.clients) do client.window='other' end
  else inv.sessions={} end
  bad.stdout=runtime.json.encode(inv)
 end
 modules.native_cli.inspect=function(_,_,callback)callback(bad,nil)end
 definition.event(intentState,recipientEvent('claim',firstRecipient),claimCx)
 check(intentState.intents[1].recipient==nil,'remote claim refuses '..fault..' without consuming the setup click')
end
modules.native_cli.inspect=nativeInspect
do
 -- Drive the actual window timer against actual HOST view/event/save callbacks.
 -- Only native surfaces, storage and registration are injected; ACK is not echoed.
 local previousInspect=modules.native_cli.inspect
 local currentResult=claimResult
 local currentProducer,durableProducer,windowCx,windowTick
 local dropAck,failAckSave,unreadable,clipped,interruptJournal=false,false,false,false,false
 local effects,errors=0,{}
 local holdNative=false
 local nativeCallbacks={}
 local hostInfo={id=0,name='fixture',kind='local',state='connected',sessions={1},panes={7}}
 local sessionInfo={id=1,host=0}
 local producerCx={pane=7,render=function()end,save=function()
  if failAckSave then error('interrupted durable ACK') end
  if currentProducer~=nil then durableProducer=clone(definition.save(currentProducer)) end
 end}
 modules.native_cli.inspect=function(_,_,callback)
  if holdNative then table.insert(nativeCallbacks,{callback=callback,result=clone(currentResult),cx=windowCx});return end
  callback(currentResult,nil,windowCx)
 end
 currentProducer=definition.init(producerCx,{runtime.json.encode({host={name='fixture'},native_window='fixture-window'})},nil)
 local function click()
  definition.event(currentProducer,{ev='action',act='launch-result@'..currentProducer.snapshot.config_revision},producerCx)
  check(#currentProducer.intents==1,'real Config click durably publishes one pending review intent')
 end
 windowCx={
  window_key=function()return 'fixture-window'end,
  hosts={current=function()return hostInfo end,list=function()return {hostInfo}end},
  sessions={current=function()return sessionInfo end,list=function()return {sessionInfo}end},
  toast=function(_,kind,_,message)
   if kind=='error' then table.insert(errors,message)
   elseif kind=='info' then effects+=1 end
  end,
 }
 windowCx.session={
  tab_of=function()return 1 end,tabs=function()return {{id=1,session=1}}end,
  pane=function(_,pane)return {pane=pane,block='spawn.spawner',tab=1}end,
  panes=function()return {{pane=7,block='spawn.spawner',tab=1}}end,
  view=function(_,pane)
   if pane~=7 then return nil end
   local rendered=definition.view(currentProducer,producerCx)
   return {surface={role='plugin.spawn.spawner'},main=rendered.main}
  end,
  surface=function(_,_,options)
   if options.root=='main.spawn-launch-intent' and unreadable then return nil end
   for _,node in ipairs(definition.view(currentProducer,producerCx).main.children) do
    if node.p and options.root=='main.'..tostring(node.p.key) then
     return {surface={role='plugin.spawn.spawner'},more=if clipped and options.root=='main.spawn-launch-intent' then 1 else nil,
      main={id=options.root,k='text',p={role=node.p.role,spans={{t=node.text}}}}}
    end
   end
   return nil
  end,
  event=function(_,pane,event)
   assert(pane==7,'intent escaped issuing Config')
   if dropAck and event.act=='spawn.launch-intent-ack' then return end
   definition.event(currentProducer,event,producerCx)
  end,
 }
 local function reloadWindow()
  local windowModules={native_cli=modules.native_cli,['updater/window']={register=function()end}}
  local windowFs=table.clone(fake.fs)
  windowFs.write=function(path,bytes)
   fake.fs.write(path,bytes)
   if interruptJournal and path:sub(-22)=='/spawn.intents.v1.json' then error('interrupted window callback after durable journal write') end
  end
  local windowTern=setmetatable({
   context='window',fs=windowFs,
   chrome={program_icon=function()end,status=function()end},
   route={link=function()end},
   files={button=function()end},css=function()end,command=function()end,on=function()end,
   timer=function(ms,callback)if ms==1000 then windowTick=callback end;return {}end,
  },{__index=fake})
  local function windowLoad(name)
   name=name:gsub('^%./','')
   if windowModules[name] then return windowModules[name] end
   local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
   setfenv(chunk,setmetatable({tern=windowTern,require=windowLoad},{__index=environment}))
   windowModules[name]=chunk() or true;return windowModules[name]
  end
  windowLoad('window')
  assert(windowTick)(windowCx) -- Native observer initialization, before any click execution.
 end
 local handle=assert(J.open('fixture-window',claimResult))
 local function retained()return #J.cache(handle,'spawn.intents.v1')end
 local function tick()assert(windowTick)(windowCx)end
 reloadWindow()
 click();dropAck=true;tick();tick()
 check(effects==1 and retained()==1 and #durableProducer.intents==1,'real window journals once before its effect and retains a lost durable ACK; '..runtime.json.encode({
  effects=effects,retained=retained(),durable_intents=#durableProducer.intents,errors=errors,
  notice=currentProducer.notice,scope_error=currentProducer.scope_error,transport_error=currentProducer.transport_error,
  recipient=if currentProducer.intents[1] then currentProducer.intents[1].recipient else nil,
  queue_id=currentProducer.intent_queue_id,durable_queue_id=durableProducer.intent_queue_id,
 }))
 tick();check(effects==1 and retained()==1,'repeated pending HOST publication cannot repeat the effect')
 unreadable=true;tick();unreadable=false
 clipped=true;tick();clipped=false
 check(effects==1 and retained()==1,'unreadable and truncated HOST queue nodes never prove ACK removal')
 failAckSave=true;dropAck=false;tick();failAckSave=false
 check(retained()==1 and #currentProducer.intents==1 and #durableProducer.intents==1,'failed HOST ACK persistence restores the pending click and retains window evidence')
 -- Another Config at the same native pane has a distinct durable queue identity.
 local originalProducer,originalDurable=currentProducer,durableProducer
 currentProducer=definition.init(producerCx,{runtime.json.encode({host={name='fixture'},native_window='fixture-window'})},nil)
 click()
 local replacementId=currentProducer.intents[1].intent_id
 local replacementEnvelope=clone(handle.recipient);replacementEnvelope.intent_id=replacementId
 replacementEnvelope.queue_id=currentProducer.intent_queue_id
 for _,kind in ipairs({'claim','ack'}) do
  definition.event(currentProducer,{ev='action',id='main',act='spawn.launch-intent-'..kind,value=runtime.json.encode(replacementEnvelope)},producerCx)
 end
 tick()
 check(retained()==1 and effects==1,'an empty different issuing HOST Config queue cannot reclaim the original marker')
 currentProducer,durableProducer=originalProducer,originalDurable
 dropAck=true;reloadWindow();tick()
 check(retained()==1 and effects==1,'window VM reload preserves pending exclusion without rerunning the click')
 local exactAck=clone(handle.recipient);exactAck.intent_id=currentProducer.intents[1].intent_id;exactAck.queue_id=currentProducer.intent_queue_id
 unreadable=true;dropAck=false
 definition.event(currentProducer,{ev='action',id='main',act='spawn.launch-intent-ack',value=runtime.json.encode(exactAck)},producerCx)
 tick()
 check(retained()==1 and #durableProducer.intents==0,'durable removal without readable positive queue observation still retains the window exclusion')
 unreadable=false;tick();tick()
 check(retained()==0 and #durableProducer.intents==0 and effects==1,'actual exact-recipient durable HOST ACK empties the window journal through ordinary polling')
 for i=1,8 do click();tick();tick() end
 check(retained()==0 and effects==9 and #durableProducer.intents==0,'acknowledged Config clicks do not accumulate across repeated real HOST/window lifecycles')
 -- A callback interrupted after its journal write has no permission to replay.
 click();tick();dropAck=true;interruptJournal=true;tick();interruptJournal=false
 check(retained()==1 and effects==9,'interrupted journal write callback preserves exclusion before any possible re-entry')
 reloadWindow();tick()
 check(retained()==1 and effects==9,'interrupted callback reload never replays the queued effect')
 dropAck=false;tick();tick()
 check(retained()==0 and effects==9,'interrupted callback evidence retires only after exact durable HOST removal')
 -- A replacement native incarnation cannot consume the old recipient's queue.
 click();dropAck=true;tick();tick()
 local beforeReplacement=effects
 local replacementInventory=clone(claimInventory);replacementInventory.clients[1].conn=99;replacementInventory.clients[1].since=999
 currentResult={status=0,stdout=runtime.json.encode(replacementInventory)}
 reloadWindow();dropAck=false;tick();tick()
 check(retained()==1 and #currentProducer.intents==1 and effects==beforeReplacement,'a different native incarnation preserves the original recipient and journal obligation')
 -- Exercise candidate capture through both real Native.inspect callsites, not
 -- just Journal.open: a callback's old complete inventory cannot delete a leaf
 -- created after the caller began that inspection.
 local aInventory=clone(replacementInventory)
 aInventory.clients[1].conn=100;aInventory.clients[1].since=1000
 currentResult={status=0,stdout=runtime.json.encode(aInventory)}
 local aHandle=assert(J.open('fixture-window',currentResult))
 holdNative=true;reloadWindow()
 check(#nativeCallbacks==1,'window observer initialization waits for the native inspection callback')
 local withB=clone(aInventory)
 table.insert(withB.clients,{kind='window',window='late-window',conn=200,since=2000})
 local bResult={status=0,stdout=runtime.json.encode(withB)}
 local bHandle=assert(J.open('late-window',bResult))
 J.save(bHandle,bHandle.observer);J.save_cache(bHandle,'spawn.intents.v1',{});J.save_cache(bHandle,'spawn.records-seen.v1',{})
 local pendingWindow=table.remove(nativeCallbacks,1);holdNative=false
 pendingWindow.callback(pendingWindow.result,nil,pendingWindow.cx)
 check(journalFiles[bHandle.path..'/observer.json']~=nil and journalFiles[bHandle.path..'/spawn.intents.v1.json']~=nil,
  'actual delayed window inspection preserves a later-created live incarnation')
 currentResult=bResult
 currentProducer=definition.init(producerCx,{runtime.json.encode({host={name='fixture'},native_window='fixture-window'})},nil)
 click()
 local claim=clone(aHandle.recipient);claim.intent_id=currentProducer.intents[1].intent_id;claim.queue_id=currentProducer.intent_queue_id
 holdNative=true
 definition.event(currentProducer,{ev='action',id='main',act='spawn.launch-intent-claim',value=runtime.json.encode(claim)},producerCx)
 check(#nativeCallbacks==1,'HOST intent claim waits for its native inspection callback')
 local withC=clone(withB)
 table.insert(withC.clients,{kind='window',window='later-window',conn=300,since=3000})
 local cHandle=assert(J.open('later-window',{status=0,stdout=runtime.json.encode(withC)}))
 J.save(cHandle,cHandle.observer);J.save_cache(cHandle,'spawn.intents.v1',{});J.save_cache(cHandle,'spawn.records-seen.v1',{})
 local pendingHost=table.remove(nativeCallbacks,1);holdNative=false
 pendingHost.callback(pendingHost.result,nil,pendingHost.cx)
 check(journalFiles[cHandle.path..'/observer.json']~=nil and journalFiles[cHandle.path..'/spawn.intents.v1.json']~=nil
  and J.same_recipient(currentProducer.intents[1].recipient,aHandle.recipient),
  'actual delayed HOST claim inspection preserves a later-created leaf while assigning its exact recipient')
 modules.native_cli.inspect=previousInspect
end
end
do
 -- Runtime controls exercise real HOST envelope/UI paths; source persistence is
 -- the dispatch owner's independently tested transaction, injected here.
 local D=load('dispatch')
 local originalSource,originalApply=D.admin_source,D.admin_apply
 local originalInventory,originalPanes=inventory,paneList
 -- The preceding owner-context case deliberately leaves a roster source review
 -- open, which takes over every Config page. Bootstrap an independent authority
 -- through the real owner path rather than hiding that review in its snapshot.
 local originalSaved=saved
 saved={}
 inventory={clients={{kind='window',window='fixture-window',conn=1,since=1700000000000}},
  sessions={{id=1,tabs={{blocks={{id=7},{id=9}}}}}}}
 paneList={{pane=7,program='spawn.spawner'},{pane=9,program='orchplus.orchestrator'}}
 local admin=definition.init(cx,{runtime.json.encode({kind='page',page='runtime',native_window='fixture-window'})},nil)
 check(admin.binding==nil and admin.page_context_request~=nil and next(saved)==nil,'runtime navigation requests its own native context without initializing authority')
 local runtimeContext={kind='context',native_window='fixture-window',host={id=0,name='fixture',kind='local'}}
 definition.event(admin,{ev='action',id='main',act='spawn.page-context',value=runtime.json.encode({nonce=admin.page_context_request.nonce,context=runtimeContext})},cx)
 check(admin.binding~=nil and admin.snapshot~=nil and admin.snapshot.migration==nil and admin.page=='runtime','runtime administration opens through the real owner context boundary and preserves the requested page')
 definition.event(admin,{ev='action',act='advanced-open'},cx)
 local own={source_schema=1,source_revision=10,source_sha256=string.rep('a',64),source_namespace='spawn-admin',candidate_namespace='spawn-admin',
  protocol=1,state='ready',phase='stable',managed_sha256=string.rep('b',64),pending_immutable=0,blockers=0}
 local peerProof={source_schema=3,source_revision=20,source_sha256=string.rep('c',64),candidate_namespace='orch-admin',
  protocol=1,state='ready',phase='stable',managed_sha256=string.rep('b',64),pending_immutable=0,blockers=0}
 local selection={logical_session_ids=runtime.json.array(),mailbox_handles=runtime.json.array()}
 local peer={protocol=2,phase='legacy',source_nonce='peer-source-nonce',host_pane_id='9',authority_namespace='orch-admin',
  authority_revision=20,source_sha256=peerProof.source_sha256,qualification={proof=peerProof,selection=selection}}
 local sourceCalls,applyCalls,mutations=0,0,0
 local uncertainApply=false
 local predictedTransition=nil
 D.admin_source=function(binding)
  check(binding==admin.binding,'explicit migration inspect uses original Config binding')
  sourceCalls+=1;return {proof=clone(own),selection=selection}
 end
 D.admin_apply=function(operation,expected,qualification,onTransition)
  applyCalls+=1
  check(P.equal(qualification,peer.qualification),'HOST passes only actual peer qualification to the sole writer')
  if not P.equal(expected,own) then return nil,'source changed','refused' end
  if operation~='inspect' and uncertainApply then
   predictedTransition=clone(own);predictedTransition.source_revision+=1
   predictedTransition.source_sha256=string.rep('d',64);predictedTransition.protocol=2;predictedTransition.phase='prepared'
   onTransition(predictedTransition)
   return nil,'durable transition acknowledgment unavailable','uncertain'
  end
  if operation~='inspect' then mutations+=1 end
  return {proof=clone(own),selection=selection}
 end
 local recipient={window='fixture-window',native_namespace='desktop-migration',native_conn=11,native_since=1700000000011}
 local function consentEvent(consent,changed)
  local value={nonce=consent.nonce,operation=consent.operation,window=recipient.window,
   native_namespace=recipient.native_namespace,native_conn=recipient.native_conn,native_since=recipient.native_since,
   window_consent='window-consent-'..consent.nonce}
  if changed then changed(value)end
  definition.event(admin,{ev='action',id='main',act='managed-migration-consent',value=runtime.json.encode(value)},cx)
 end
 local function click(act)
  definition.event(admin,{ev='action',act=act},cx)
  local consent=admin.managed_migration_consent
  if consent then consentEvent(consent)end
 end
 local function result(challenge,changed)
  local value={intent_id=challenge.nonce,operation=challenge.operation,
   native_window={window_key=challenge.native_window,conn=challenge.native_conn,since=challenge.native_since},
   native_namespace=challenge.native_namespace,window_consent=challenge.window_consent,
   local_source=clone(challenge.expected),peer_qualification=P.clone(peer)}
  if changed then changed(value)end
  definition.event(admin,{ev='action',id='main',act='spawn.migration-result',value=runtime.json.encode(value)},cx)
 end
 local function button(id)
  for _,section in ipairs(definition.view(admin,cx).main.children[1].p.sections)do
   for _,entry in ipairs(section.rows)do if entry.id==id then return entry.control.act end end
  end
  return nil
 end
 do
 holdInspection=true
 definition.event(admin,{ev='action',act='managed-migration-inspect'},cx)
 local directed=assert(admin.managed_migration_consent)
 check(opened[#opened]=='tern-spawn://managed-migration/7/inspect/'..directed.nonce and admin.admin_pending.challenge==nil,
  'migration button synchronously targets the clicked desktop before membership awaits')
 check(definition.save(admin).managed_migration_consent==nil,'migration consent is ephemeral across HOST reload')
 consentEvent(directed,function(value)value.nonce='stale-consent'end)
 check(admin.managed_migration_consent==directed and deferred==nil,'stale consent cannot start verification or consume the current directed request')
 consentEvent(directed)
 check(admin.managed_migration_consent==nil,'matching migration consent is consumed before native membership awaits')
 local pendingVerification=deferred
 consentEvent(directed)
 check(deferred==pendingVerification,'replayed consent cannot enqueue a second membership verification')
 check(sourceCalls==1 and P.equal(admin.admin_qualification.proof,own) and admin.admin_pending.challenge==nil,'own source is captured/published before peer or native membership awaits')
 holdInspection=false
 local captured=deferred;deferred=nil
 captured({status=0,timed_out=false,stdout=runtime.json.encode(inventory)},nil)
 local challenge=admin.admin_pending.challenge
 check(challenge and challenge.host_pane_id=='7' and challenge.expected.source_revision==10,'runtime challenge captures Config HOST pane and original proof')
 check(challenge.nonce==directed.nonce and challenge.native_namespace==recipient.native_namespace
  and challenge.native_conn==11 and challenge.window_consent=='window-consent-'..directed.nonce,
  'challenge retains the directed nonce and exact desktop recipient rather than the HOST client incarnation')
 local projected=false
 for _,node in ipairs(definition.view(admin,cx).main.children)do
  if node.p and node.p.key=='spawn-managed-migration' then projected=node.p.role=='spawn.managed.migration' and node.p.hidden==true and P.equal(runtime.json.decode(node.text),challenge)end
 end
 check(projected,'Config exposes only the exact pending native migration challenge')
 result(challenge,function(value)value.peer_qualification.qualification=nil end)
 check(admin.admin_pending.challenge==challenge and admin.admin_qualification.proof.source_revision==10 and applyCalls==0 and admin.admin_error~=nil,'missing peer qualification visibly holds without hiding local source or consuming intent')
 result(challenge,function(value)value.extra=true end)
 check(admin.admin_pending.challenge==challenge and applyCalls==0,'unknown callback fields are refused by the closed envelope')
 result(challenge,function(value)value.peer_qualification.qualification.projection={schema=1,sessions={},workers={}}end)
 check(admin.admin_pending.challenge==challenge and applyCalls==0,'full peer identity projections are refused after the selection-only cutover')
 result(challenge,function(value)value.peer_qualification.qualification.selection.logical_session_ids={}end)
 check(admin.admin_pending.challenge==challenge and applyCalls==0,'selection object cannot masquerade as an empty array at the HOST parser boundary')
 result(challenge,function(value)value.native_window.conn=2 end)
 check(admin.admin_pending.challenge==challenge and applyCalls==0,'a reused positional window with changed conn cannot apply migration')
 for _,change in ipairs({
  function(value)value.native_namespace='another-desktop'end,
  function(value)value.window_consent='another-consent'end,
  function(value)value.native_window.window_key='another-window'end,
  function(value)value.native_window.since+=1 end,
  function(value)value.native_window.native_session=1 end,
 })do
  result(challenge,change)
  check(admin.admin_pending.challenge==challenge and applyCalls==0,'mismatched desktop identity or injected HOST session cannot apply migration')
 end
 paneList={{pane=9,program='shell'}}
 result(challenge)
 check(applyCalls==0 and admin.admin_pending.challenge==challenge,'HOST independently refuses a non-ORCH source program synchronously')
 paneList={{pane=7,program='spawn.spawner'},{pane=9,program='orchplus.orchestrator'}}
 result(challenge)
 check(applyCalls==1 and mutations==0 and admin.admin_pending==nil and admin.admin_observation.nonce==challenge.nonce,'successful source inspection consumes only the live challenge and exposes deliberate next controls')
 local oldPrepare=button('managed-migration-prepare')
 check(oldPrepare=='managed-migration-prepare:'..challenge.nonce and button('managed-migration-finish')=='managed-migration-finish:'..challenge.nonce,'rendered transition buttons carry the exact prior inspection nonce')
 result(challenge)
 check(applyCalls==1,'delayed duplicate callback cannot repeat a completed administrative operation')
 own.source_revision=11
 click('managed-migration-inspect')
 local newer=admin.admin_pending.challenge
 result(newer)
 local beforeApply=applyCalls
 click(oldPrepare)
 check(applyCalls==beforeApply and admin.admin_pending==nil,'an old UI control cannot borrow a newer inspected proof')
 click(button('managed-migration-prepare'))
 local prepare=admin.admin_pending.challenge
 check(prepare.expected.source_revision==11 and sourceCalls==2,'prepare captures the inspected source without calling admin_source again')
 own.source_revision=12
 result(prepare,function(value)value.local_source=clone(own)end)
 check(applyCalls==beforeApply and admin.admin_pending.challenge==prepare,'callback cannot replace the original StoreProof with a newer revision')
 result(prepare)
 check(applyCalls==beforeApply+1 and mutations==0 and admin.admin_pending==nil and prepare.expected.source_revision==11,'definite pre-effect source refusal consumes only its pending intent without refreshing the original fence')
 click('managed-migration-inspect')
 local refreshed=admin.admin_pending.challenge
 result(refreshed)
 click(button('managed-migration-finish'))
 local finish=admin.admin_pending.challenge
 beforeApply=applyCalls
 result(finish,function(value)value.peer_qualification.source_nonce='replacement-source'end)
 check(applyCalls==beforeApply and admin.admin_pending.challenge==finish,'prepare/finish remain bound to the original inspected ORCH source incarnation')
 result(finish)
 check(mutations==1 and admin.admin_pending==nil and admin.admin_status=='Paired migration finished','exact fresh native proof reaches one deliberate HOST migration transition')
 click('managed-migration-inspect')
 local cancelable=admin.admin_pending.challenge
 result(cancelable)
 click(button('managed-migration-prepare'))
 local canceled=admin.admin_pending.challenge
 click('managed-migration-inspect')
 local replacing=admin.admin_pending.challenge
 beforeApply=applyCalls
 result(canceled)
 check(applyCalls==beforeApply and admin.admin_pending.challenge==replacing,'new explicit inspect fences an unsubmitted older mutation callback before effects')
 result(replacing)
 click(button('managed-migration-prepare'))
 local uncertain=admin.admin_pending.challenge
 uncertainApply=true
 result(uncertain)
 beforeApply=applyCalls
 check(admin.admin_pending.started==true and admin.admin_pending.challenge==uncertain,'ambiguous submitted transition retains its exact live obligation')
 check(P.equal(admin.admin_pending.transition_source,predictedTransition),'exact predicted post-commit source is captured before uncertain persistence')
 result(uncertain)
 check(applyCalls==beforeApply,'an ambiguous submitted migration is never automatically applied again')
 local beforeSource=sourceCalls
 click('managed-migration-inspect')
 check(sourceCalls==beforeSource+1 and applyCalls==beforeApply and admin.admin_pending.challenge==uncertain,'read-only inspect preserves a potentially applied mutation instead of superseding it')
 own.source_revision=predictedTransition.source_revision
 click('managed-migration-inspect')
 check(admin.admin_pending.challenge==uncertain and applyCalls==beforeApply,'unrelated source revision catch-up never settles a potentially applied transition')
 own=clone(predictedTransition)
 click('managed-migration-inspect')
 local reconciled=admin.admin_pending.challenge
 check(reconciled.operation=='inspect' and reconciled.nonce~=uncertain.nonce and P.equal(reconciled.expected,predictedTransition) and applyCalls==beforeApply,'exact fresh post-commit proof settles the old transition and permits only a new read-only inspection')
 result(uncertain)
 check(admin.admin_pending.challenge==reconciled and applyCalls==beforeApply,'late callback for the reconciled mutation cannot execute under the new inspection')
 local persisted=definition.save(admin)
 check(persisted.admin_pending==nil and persisted.admin_observation==nil and persisted.admin_qualification==nil,'reload never persists a stale administrative challenge or completed source-proof history')
 end
 do
 -- A remote HOST inventory has no desktop key: Both hosts use "".
 local priorWindow=admin.native_window
 admin.native_window=''
 inventory={clients={{kind='remote',window='',conn=21,since=1700000000021},
  {kind='remote',window='',conn=22,since=1700000000022}},sessions={{id=1,tabs={{blocks={{id=7},{id=9}}}}}}}
 click('managed-migration-inspect')
 local remote=assert(admin.admin_pending.challenge)
 check(remote.native_window=='fixture-window' and remote.native_conn==11 and remote.native_session==1,
  'remote twins with empty HOST keys use only the explicitly consenting desktop and retain the original HOST session')
 result(remote)
 check(admin.admin_pending==nil and admin.admin_observation.nonce==remote.nonce,'remote directed inspection completes without selecting either remote client')
 definition.event(admin,{ev='action',act='managed-migration-inspect'},cx)
 local expired=assert(admin.managed_migration_consent)
 expired.deadline=-1
 consentEvent(expired)
 check(admin.managed_migration_consent==nil and admin.admin_pending.challenge==nil and admin.admin_status=='Held',
  'expired directed consent is consumed without publishing a migration challenge')
 consentEvent(expired)
 check(admin.admin_pending.challenge==nil,'expired consent cannot replay after refusal')
 definition.event(admin,{ev='action',act='managed-migration-inspect'},cx)
 local replaced=assert(admin.managed_migration_consent)
 definition.event(admin,{ev='action',act='managed-migration-inspect'},cx)
 local current=assert(admin.managed_migration_consent)
 consentEvent(replaced)
 check(admin.managed_migration_consent==current and admin.admin_pending.challenge==nil,'superseded consent cannot attach to a newer source intent')
 consentEvent(current,function(value)value.window_consent=''end)
 check(admin.managed_migration_consent==nil and admin.admin_pending.challenge==nil,'invalid desktop consent identity consumes its one-shot request without applying')
 definition.event(admin,{ev='action',act='managed-migration-inspect'},cx)
 local moved=assert(admin.managed_migration_consent)
 inventory.sessions[1].id=2
 consentEvent(moved)
 check(admin.managed_migration_consent==nil and admin.admin_pending.challenge==nil and admin.admin_status=='Held',
  'valid desktop consent cannot rebind the original HOST session after native membership moves')
 admin.native_window=priorWindow
 end
 D.admin_source,D.admin_apply=originalSource,originalApply
 inventory,paneList=originalInventory,originalPanes
 saved=originalSaved
end
do
 local priorSaved,priorInventory=saved,inventory
 saved={}
 inventory={clients={{kind='window',window='fixture-window',conn=1,since=1700000000000}},sessions={{id=1,tabs={{blocks={{id=7,program='plugin',plugin='spawn',block='spawner'}}}}}}}
 local panel=definition.init(cx,{runtime.json.encode({host={name='visibility'},native_window='fixture-window'})},nil)
 local function act(value)definition.event(panel,{ev='action',act=value},cx)end
 local function machine(key)
  for _,node in ipairs(definition.view(panel,cx).main.children)do if node.p and node.p.key==key then return node end end
  return nil
 end
 local function visible()
  local parts={}
  for _,node in ipairs(definition.view(panel,cx).main.children)do
   if not node.p or not node.p.hidden then table.insert(parts,runtime.json.encode(node))end
  end
  return table.concat(parts,'\n')
 end
 local function field(id)
  for _,section in ipairs(definition.view(panel,cx).main.children[1].p.sections or {})do
   for _,item in ipairs(section.rows)do if item.id==id then return item end end
  end
  return nil
 end
 panel.managed_route={nonce='visibility-route',status='failed',error='Visible route failure'}
 panel.page_context_request={nonce='visibility-page',entry={page='managed'}}
 panel.admin_pending={challenge={nonce='visibility-migration',operation='inspect'}}
 local channels={['spawn-managed-route']='spawn.managed.route',['spawn-page-context']='spawn.page.context',['spawn-managed-migration']='spawn.managed.migration'}
 for key,role in pairs(channels)do
  local node=machine(key)
  check(node and node.p.hidden==true and node.p.role==role,'normal machine payload keeps its exact hidden root and role: '..key)
 end
 panel.notice='Visible user failure'
 for _,page in ipairs({'managed','setup','agents','spawn','runtime'})do
  panel.page=page
  local rendered=visible()
  check(rendered:find('Visible user failure',1,true)~=nil and not rendered:find('SPAWN_STATE_V2',1,true)
   and not rendered:find('visibility-page',1,true) and not rendered:find('visibility-migration',1,true)
   and field('manual-json')==nil,'all Normal pages preserve errors while hiding live machine JSON: '..page)
 end
 panel.managed_route=nil;panel.page_context_request=nil;panel.admin_pending=nil
 -- Maximum-length valid persisted intent fields exercise the host projection and
 -- actual bounded window node reader near its existing 16 KiB transport bound.
 panel.intent_queue_id=string.rep('q',256);panel.intents={}
 for i=1,16 do
  table.insert(panel.intents,{intent_id=tostring(i)..string.rep('i',250),kind='readiness',config_revision=panel.snapshot.config_revision,
   native_window=string.rep('w',256),recipient={observer_id=string.rep('o',200),window_key=string.rep('w',120),conn=1,since=1700000000000}})
 end
 local intentBytes=machine('spawn-launch-intent').text
 check(#intentBytes>15000 and #intentBytes<=16384,'near-bound intent fixture fills the supported live-read envelope without truncation')
 local surfaceCx={session={
  pane=function()return {block='spawn.spawner'}end,
  surface=function(_,_,options)
   local node=machine(options.root:sub(6));if not node then return nil end
   return {surface={role='plugin.spawn.spawner'},main={id=options.root,k='text',p={hidden=node.p.hidden,role=node.p.role,spans={{t=node.text}}}}}
  end,
 }}
 local liveBytes=load('dispatch_window').read_node(surfaceCx,7,'spawn.spawner','spawn-launch-intent','spawn.launch.intent',16384)
 check(liveBytes==intentBytes,'actual window machine reader preserves complete near-bound hidden intent bytes')
 panel.intents[16].config_revision+=1
 check(load('dispatch_window').read_node(surfaceCx,7,'spawn.spawner','spawn-launch-intent','spawn.launch.intent',16384)==machine('spawn-launch-intent').text
  and machine('spawn-launch-intent').text~=intentBytes,'near-bound hidden intent reads reflect the next live update')
 -- Exercise the reader's byte fence independently of native surface framing.
 -- Padding is legal JSON whitespace, not an oversized decoded queue.
 local boundedBytes=machine('spawn-launch-intent').text
 boundedBytes..=string.rep(' ',16384-#boundedBytes)
 local boundaryTree={surface={role='plugin.spawn.spawner'},main={id='main.spawn-launch-intent',k='text',
  p={hidden=true,role='spawn.launch.intent',spans={{t=boundedBytes:sub(1,8191)},{t=boundedBytes:sub(8192)}}}}}
 local boundaryCx={session={pane=function()return {block='spawn.spawner'}end,surface=function()return boundaryTree end}}
 local function readBoundary()
  return load('dispatch_window').read_node(boundaryCx,7,'spawn.spawner','spawn-launch-intent','spawn.launch.intent',16384)
 end
 check(readBoundary()==boundedBytes,'split ordered spans preserve every byte at the exact intent reader cap')
 table.insert(boundaryTree.main.p.spans,{t=' '})
 check(readBoundary()==nil,'one extra byte across spans refuses the whole intent payload rather than accepting its prefix')
 table.remove(boundaryTree.main.p.spans)
 boundaryTree.more=1
 check(readBoundary()==nil,'surface clipping refuses an otherwise complete-looking exact-cap intent')
 boundaryTree.more=nil;boundaryTree.main.more=1
 check(readBoundary()==nil,'node clipping refuses an otherwise complete-looking exact-cap intent')
 boundaryTree.main.more=nil;boundaryTree.main.id='main.foreign-intent'
 check(readBoundary()==nil,'exact-cap payload cannot borrow a different machine root')
 boundaryTree.main.id='main.spawn-launch-intent';boundaryTree.main.p.role='spawn.setup.result'
 check(readBoundary()==nil,'exact-cap payload cannot borrow a different machine role')
 boundaryTree.main.p.role='spawn.launch.intent'
 check(readBoundary()==boundedBytes,'fresh complete exact-cap observation remains readable after refused observations')
 panel.intents={}
 check(#runtime.json.decode(assert(load('dispatch_window').read_node(surfaceCx,7,'spawn.spawner','spawn-launch-intent','spawn.launch.intent',16384))).intents==0,
  'bounded window reader distinguishes a present blank queue from absence')
 panel.page='setup';act('advanced-open')
 definition.event(panel,{ev='change',item='manual-json',value='{"schema":2,"agents":[],"unknown":null}'},cx)
 act('manual-review@'..panel.snapshot.config_revision)
 check(panel.import_review==nil and #panel.snapshot.records==0,'Advanced manual review refuses unknown null fields before native JSON can erase them')
 local large={}
 for i=1,4 do local item=record('large-'..i);item.prompt=string.rep('Complete Unicode λ — ',900);item.arguments={'','literal "quoted" argument','last-'..i};table.insert(large,item)end
 local largeBytes=runtime.json.encode({schema=2,setup_run_id='manual-large-result',confirmed=true,agents=large})
 check(#largeBytes>75000 and #largeBytes<120000,'large result fixture fits the preserved 120000-byte import contract')
 definition.event(panel,{ev='change',item='manual-json',value=largeBytes},cx)
 act('manual-review@'..panel.snapshot.config_revision)
 check(panel.import_review and panel.import_review.bytes==largeBytes and #panel.import_review.records==4,'Advanced retains complete immutable large review bytes')
 local reviewText=visible()
 check(reviewText:find('last%-4')~=nil and reviewText:find('literal',1,true)~=nil and field('manual-confirm')~=nil,
  'large review exposes the final record and complete argv plus deliberate import')
 local revisionBefore=panel.snapshot.config_revision
 local sequencesBefore=clone(panel.snapshot.request_sequences)
 act('manual-confirm@'..panel.snapshot.config_revision)
 check(#panel.snapshot.records==0 and #panel.snapshot.attempts==0 and panel.snapshot.config_revision==revisionBefore
  and P.equal(panel.snapshot.request_sequences,sequencesBefore) and panel.import_review.bytes==largeBytes,
  'oversized roster plus retained request refuses atomically within the unchanged authority metadata budget')
 -- Raw input size and durable roster size have separate bounds. Keep the final
 -- full prompt beyond 75 KiB of input while leaving room for its retained request.
 for i=1,3 do large[i].prompt=string.rep('Complete Unicode λ — ',300) end
 largeBytes=string.rep(' ',45000)..runtime.json.encode({schema=2,setup_run_id='manual-large-result',confirmed=true,agents=large})
 check(#largeBytes>75000 and #largeBytes<120000,'near-bound input retains a roster that fits durable capacity')
 definition.event(panel,{ev='change',item='manual-json',value=largeBytes},cx)
 act('manual-review@'..panel.snapshot.config_revision)
 check(panel.import_review and panel.import_review.bytes==largeBytes and #panel.import_review.records==4,
  'manual review preserves complete near-bound bytes independently of durable roster size')
 act('manual-confirm@'..panel.snapshot.config_revision)
 check(#panel.snapshot.records==4 and panel.snapshot.records[4].prompt==large[4].prompt and #panel.snapshot.attempts==0,
  'explicit large manual import preserves complete final prompt without launching: '..tostring(panel.notice))
 local retained=0;for _ in pairs(panel.snapshot.replies)do retained+=1 end
 check(retained==0,'manual import preserves durable reply acknowledgement rather than leaking an unconsumed result')
 act('advanced-close')
 check(not visible():find('SPAWN_STATE_V2',1,true) and field('manual-json')==nil and definition.save(panel).advanced==nil,
  'closing Advanced removes raw diagnostics and recovery; reload cannot silently reopen Advanced')
 saved,inventory=priorSaved,priorInventory
end
do
 local priorSaved,priorInventory,priorPanes,readFile=saved,inventory,paneList,fake.fs.read
 local priorGetenv=fake.getenv
 fake.getenv=function(name)
  if name=='TERN_EXE' then return '/fixture/tern'
  elseif name=='TERN_PANE_SOCKET' then return '/fixture/tern.sock'
  elseif name=='TERN_CONFIG_DIR' then return '/fixture/config' end
  return priorGetenv(name)
 end
 saved={}
 inventory={clients={{kind='window',window='fixture-window',conn=1,since=1700000000000}},sessions={{id=1,tabs={{blocks={{id=7,cwd='/work'}}}}}}}
 paneList={{pane=7,program='spawn.spawner',cwd='/work'}}
 journalFiles[fake.plugin.dir..'/skills/setup/SKILL.md']=runtime.fs.read(root..'/skills/setup/SKILL.md')
 local panel=definition.init(cx,{runtime.json.encode({host={name='submission'},native_window='fixture-window'})},nil)
 local sequence,lastRequest=0,nil
 local function request(op,data)
  sequence+=1
  local id='host-submission/'..sequence
  local input={version=2,request_id=id,authority_id=panel.binding.authority_id,observer_id='host-submission',request_sequence=sequence,
   acknowledged_requests=if lastRequest then {lastRequest} else {},expected_config_revision=panel.snapshot.config_revision,op=op,data=data}
  definition.event(panel,{ev='action',id='main',act='spawn.request',value=runtime.json.encode(input)},cx)
  lastRequest=id
  return panel.snapshot.replies[id]
 end
 local started=request('start_setup',{setup_run_id='host-large-setup',command='truthful-default --opaque',cwd='/work',window='fixture-window',config_pane=700})
 check(started and started.ok and #panel.snapshot.records==0,'real host request admits setup from the effective default without creating a saved record')
 local job=started.result.job
 panel.page='runtime'
 local promptSummary=false
 for _,section in ipairs(definition.view(panel,cx).main.children[1].p.sections)do
  for _,item in ipairs(section.rows)do
   if item.id=='reply-host-submission/1-result-job-initial_prompt' then promptSummary=item.hint:find('Open Advanced',1,true)~=nil end
  end
 end
 check(not promptSummary,'normal runtime omits retained transport replies and raw startup prompts')
 panel.page='setup'
 local ref={attempt_id=job.attempt_id,setup_run_id=job.setup_run_id}
 check(request('setup_claim',ref).ok and request('setup_begin',ref).ok,'host persists setup claim and pre-effect intent in the existing lifecycle')
 table.insert(inventory.sessions[1].tabs[1].blocks,{id=42,command=job.setup.command,cwd=job.setup.cwd})
 local bound=request('setup_bind',{attempt_id=job.attempt_id,setup_run_id=job.setup_run_id,pane=900})
 check(bound.ok and bound.result.job.native_pane==42 and bound.result.job.setup.agent_pane==900,
  'native host pane and SDK agent pane remain distinct through actual authority binding')
 job=bound.result.job
 local proposed={}
 for i=1,4 do local item=record('submitted-'..i);item.prompt=string.rep('Exact submitted λ — ',1000);item.arguments={'','literal "quoted"','final-'..i};table.insert(proposed,item)end
 local bytes=runtime.json.encode({schema=2,setup_run_id=job.setup_run_id,confirmed=true,agents=proposed})
 check(#bytes>80000 and #bytes<120000,'automatic large result retains all configured Unicode record fields')
 bytes..=string.rep(' ',120000-#bytes)
 check(#bytes==120000,'automatic submission exercises the exact preserved raw-result byte boundary')
 local resultPath=job.setup.result_path;local reads=0
 journalFiles[resultPath]=bytes
 fake.fs.read=function(path,limit)if path==resultPath then reads+=1 end;return readFile(path,limit)end
 local envelope={schema=1,kind='spawn-setup-result',setup_run_id=job.setup_run_id,binding=job.setup.binding,path=resultPath}
 local function submit(value)
  return definition.key(panel,{name='paste',text=runtime.json.encode(value or envelope)},cx)
 end
 local nullEnvelope=runtime.json.encode(envelope):sub(1,-2)..',"unknown":null}'
 check(definition.key(panel,{name='paste',text=nullEnvelope},cx) and reads==0 and #panel.snapshot.records==0,
  'Config BLOCK consumes and refuses unknown null envelope fields before native JSON erasure or filesystem access')
 local wrong=clone(envelope);wrong.binding='not-the-original-binding'
 check(submit(wrong) and reads==0 and #panel.snapshot.records==0,'Config BLOCK consumes wrong-bound submission without reading a path or importing')
 wrong=clone(envelope);wrong.path=resultPath..'.other'
 check(submit(wrong) and reads==0,'an alternate filesystem path is refused before reading')
 inventory.sessions[1].tabs[1].blocks[2].command='replacement-source'
 check(submit() and reads==0,'reused native source is refused before any result-file read')
 -- SKILLS-194b: the refusal is carried in the state snapshot the window reads, not only in a notice nobody sees.
 local function stateNode()
  for _,node in ipairs(definition.view(panel,cx).main.children)do if node.text and node.text:sub(1,15)=='SPAWN_STATE_V2 ' then return runtime.json.decode(node.text:sub(16)) end end
 end
 local refusedState=stateNode()
 local mineRefusal
 for _,entry in ipairs(refusedState and refusedState.setup_refusals or {})do if entry.binding==job.setup.binding and entry.setup_run_id==job.setup_run_id then mineRefusal=entry end end
 check(mineRefusal and mineRefusal.setup_run_id==job.setup_run_id and mineRefusal.binding==job.setup.binding and mineRefusal.authority_id==panel.snapshot.authority_id
  and mineRefusal.text:find('closed, moved or changed',1,true)~=nil,
  'a refused setup submission is published in the snapshot bound to its authority, run and binding: '..tostring(mineRefusal and mineRefusal.text))
 -- A late submission naming another run is its own entry; it never replaces or relabels this run's refusal.
 local otherRun=clone(envelope);otherRun.setup_run_id='another-run'
 check(submit(otherRun),'a submission naming another run is consumed')
 local bothState=stateNode()
 local seenMine,seenOther=false,false
 for _,entry in ipairs(bothState.setup_refusals or {})do
  if entry.setup_run_id==job.setup_run_id then seenMine=true elseif entry.setup_run_id=='another-run' then seenOther=true end
 end
 check(seenMine and seenOther,'refusals of two runs stay separate entries')
 -- Malformed identifiers stay a notice: publishing them would make the window reject the whole snapshot.
 for _,bad in ipairs({{run='',bind=''},{run='run\nx',bind=job.setup.binding},{run=job.setup_run_id,bind='b\1d'},{run=string.rep('r',300),bind=job.setup.binding}})do
  local malformed=clone(envelope);malformed.setup_run_id=bad.run;malformed.binding=bad.bind
  check(submit(malformed),'a malformed identifier envelope is consumed')
  local view=stateNode()
  for _,entry in ipairs(view.setup_refusals or {})do
   check(#entry.setup_run_id>0 and #entry.setup_run_id<=256 and not entry.setup_run_id:find('%c') and #entry.binding>0 and #entry.binding<=256 and not entry.binding:find('%c'),'only well-formed identifiers are published')
  end
 end
 inventory.sessions[1].tabs[1].blocks[2].command=job.setup.command
 -- The helper (OMP) may leave its launch folder after binding; that is not a different pane.
 inventory.sessions[1].tabs[1].blocks[2].cwd='/tmp/omp-auto-switched'
 check(submit() and reads==1 and panel.setup_result_attempt==job.attempt_id and #panel.snapshot.records==0,
  'explicit Config BLOCK paste accepts immutable run-bound bytes once but does not import')
 local afterAccept=stateNode()
 local leftover=false
 for _,entry in ipairs(afterAccept.setup_refusals or {})do if entry.setup_run_id==job.setup_run_id then leftover=true end end
 check(not leftover,'an accepted submission clears only its own published refusal')
 journalFiles[resultPath]='changed after submission'
 check(submit() and reads==1,'duplicate submission is consumed and refused without rereading the changed file')
 local pending=assert(A.setup_pending(panel.binding,job.attempt_id))
 check(pending.bytes==bytes and not pending.consumed,'authority retains original complete accepted bytes independently of the mutable file')
 local raw=nil
 for _,node in ipairs(definition.view(panel,cx).main.children)do
  if node.p and node.p.key=='spawn-setup-result' then raw=node end
 end
 check(raw and raw.p.hidden==true and raw.p.role=='spawn.setup.result' and raw.text==bytes,
  'selected result channel carries complete exact raw bytes, not an escaped or clipped wrapper')
 local resultCx={session={
  pane=function()return {block='spawn.spawner'}end,
  surface=function(_,_,options)
   return {surface={role='plugin.spawn.spawner'},main={id=options.root,k='text',p={role=raw.p.role,hidden=raw.p.hidden,spans={{t=raw.text}}}}}
  end,
 }}
 check(load('dispatch_window').read_node(resultCx,7,'spawn.spawner','spawn-setup-result','spawn.setup.result',120000)==bytes,
  'actual bounded window reader preserves all 120000 submitted bytes, including meaningful trailing whitespace')
 definition.event(panel,{ev='action',id='main',act='spawn.setup-result-select',value=runtime.json.encode({attempt_id=job.attempt_id})},cx)
 check(panel.setup_result_attempt==job.attempt_id and reads==1,'explicit review selection retrieves retained bytes without rereading the original file')
 local restored=definition.init(cx,{runtime.json.encode({host={name='submission'},native_window='fixture-window'})},definition.save(panel))
 definition.event(restored,{ev='action',id='main',act='spawn.setup-result-select',value=runtime.json.encode({attempt_id=job.attempt_id})},cx)
 local restoredRaw=nil
 for _,node in ipairs(definition.view(restored,cx).main.children)do if node.p and node.p.key=='spawn-setup-result' then restoredRaw=node.text end end
 check(restoredRaw==bytes and reads==1,'cold Config reload retrieves immutable authority bytes through explicit selection without filesystem reread')
 panel=restored
 local projected
 for _,value in ipairs(panel.snapshot.jobs)do if value.attempt_id==job.attempt_id then projected=value end end
 check(projected and projected.pending_bytes==#bytes and projected.pending_digest==load('wire/codec').sha256(bytes),
  'bounded state carries exact pending length/digest without duplicating the raw result')
 local pendingStore=clone(saved)
 local imported=request('import_records',{setup_run_id=job.setup_run_id,attempt_id=job.attempt_id,pending_digest=projected.pending_digest,confirmed=true})
 check(imported.ok and imported.result.imported==4 and panel.snapshot.records[4].prompt==proposed[4].prompt
  and #panel.snapshot.attempts==1 and reads==1,'confirmed automatic import consumes original bytes without launching imported records or rereading the path')
 local consumed=assert(A.setup_pending(panel.binding,job.attempt_id))
 check(consumed.consumed and consumed.bytes==nil,'successful import consumes the pending bytes within existing durable authority')
 local second=request('import_records',{setup_run_id=job.setup_run_id,attempt_id=job.attempt_id,pending_digest=projected.pending_digest,confirmed=true})
 check(second and not second.ok and #panel.snapshot.records==4,'another confirmation cannot consume one accepted result twice')
 -- A separate continuation of the accepted durable state: original Config and
 -- conversation are closed. Only Advanced in the same host/session may recover.
 saved=pendingStore
 inventory.sessions[1].tabs[1].blocks={{id=8}}
 paneList={{pane=8,program='spawn.spawner',cwd='/work'}}
 local recoveryCx={pane=8,save=function()end,render=function()end}
 local recovery=definition.init(recoveryCx,{runtime.json.encode({host={name='submission'},native_window='fixture-window',page='setup'})},nil)
 local recoveryAction='manual-recover:'..job.attempt_id..'@'..recovery.snapshot.config_revision
 definition.event(recovery,{ev='action',act=recoveryAction},recoveryCx)
 check(recovery.import_review==nil and reads==1,'Normal Config cannot recover another closed Config source implicitly')
 definition.event(recovery,{ev='action',id='main',act='spawn.setup-result-select',value=runtime.json.encode({attempt_id=job.attempt_id})},recoveryCx)
 check(recovery.setup_result_attempt==nil,'automatic result selection retains the original Config pane binding')
 definition.event(recovery,{ev='action',act='advanced-open'},recoveryCx)
 local recoverControl=false
 for _,section in ipairs(definition.view(recovery,recoveryCx).main.children[1].p.sections)do
  for _,item in ipairs(section.rows)do
   if item.id=='manual-recover-'..job.attempt_id then recoverControl=item.control.act==recoveryAction and item.hint:find('does not prove original automatic%-source provenance')~=nil end
  end
 end
 check(recoverControl,'Advanced explicitly exposes retained result recovery with its provenance disclaimer')
 definition.event(recovery,{ev='action',act=recoveryAction},recoveryCx)
 check(recovery.import_review and recovery.import_review.bytes==bytes and recovery.import_text==bytes and reads==1
  and #recovery.snapshot.records==0,'closed-source recovery reviews original immutable bytes, not the replaced file, without importing')
 definition.event(recovery,{ev='action',act='manual-confirm@'..recovery.snapshot.config_revision},recoveryCx)
 local recovered=assert(A.setup_pending(recovery.binding,job.attempt_id))
 check(recovered.consumed and #recovery.snapshot.records==4 and recovery.snapshot.records[4].prompt==proposed[4].prompt
  and #recovery.snapshot.attempts==1 and reads==1,'explicit same-session Advanced confirmation imports and consumes retained closed-source bytes without launching: '..tostring(recovery.notice))
 local recoveryReply=false;for _,reply in pairs(recovery.snapshot.replies)do if reply.observer_id=='config-8' then recoveryReply=true end end
 check(not recoveryReply,'closed-source Advanced recovery preserves durable reply acknowledgement')
 fake.getenv=priorGetenv
 fake.fs.read=readFile;saved,inventory,paneList=priorSaved,priorInventory,priorPanes
end
do
 local priorSaved,priorPanes=saved,paneList
 saved={}
 local binding=assert(A.open('host:relay-fixture',1,nil))
 paneList={{pane=70,program='spawn.dispatch'},{pane=80,program='orchplus.orchestrator'}}
 local D=load('dispatch')
 local originalRequest,originalCurrent,originalExecution,originalStage=D.request,D.current,D.execution,D.stage
 local calls,stages,lastBytes,lastTag=0,0,nil,nil
 D.request=function(request,received,session)
  calls+=1
  check(session==1,'host consumes explicitly delegated native session, not the desktop pane ID')
  if not request.setup_origin then check(received.authority_id==binding.authority_id,'relay preserves real authority binding')end
  return P.reject(request,'binding_mismatch','Fixture response '..tostring(calls))
 end
 D.current=function()return nil end
 D.execution=function()return nil end
 D.stage=function(request,_binding,_session,bridge,bytes,tag)
  stages+=1;lastBytes=bytes;lastTag=tag
  check(bridge==80,'internal bridge correlation names the actual ORCH host pane, never a synthetic SPAWN pane')
  return P.body(request,'pending')
 end
 local bridge=definitions.dispatch
 local retained={request_json='retained-exact-bytes',origin_session=1,creator={old='unaltered'}}
 local panel=bridge.init({pane=70},{'untrusted creation'},retained)
 bridge.event(panel,{ev='action',act='launch',value='anything'},{pane=70})
 check(calls==0 and stages==0 and P.equal(bridge.save(panel),retained),'old dispatch panes are inert and preserve exact recovery state')
 local relay=load('dispatch_relay').install()
 check(carrierOpens==1 and relay==load('dispatch_relay').install(),'pane-free receiver installs exactly once without any block')
 local origin={logical_session_id='relay-session',owner_id='owner',owner_generation=1,host_pane_id='80',alias_nonce='relay-source',
  window_key='remote-window',window_epoch='desktop-epoch',native_session_id='1',window_host_id='42'}
 local request={schema=2,origin='orchplus',op='status',request_id='relay-read',action_id='relay-read',authority_namespace='relay-authority',
  logical_session_id='relay-session',admission_seq=1,controller_pane='180',controller_generation=1,target_request_id='target',target_request_serial=1,origin_binding=origin}
 local source={schema=1,relay_endpoint='endpoint',relay_boot='orch-boot',lane_id='lane',host_pane_id='80',source_nonce='relay-source',
  origin=origin,desktop_proof='delegated_native_window',host_program='orchplus.orchestrator'}
 local sequence=0
 local function enqueue(act,bytes,boot)
  sequence+=1
  table.insert(carrierInbox,{peer='orchplus',recipient='spawn',route='spawn.request',incarnation='orch-boot',id='message-'..sequence,
   binding='endpoint:lane:'..act..(if boot then ':'..boot else ''),body=bytes})
  return 'message-'..sequence
 end
 local priorInspect=modules.native_cli.inspect
 modules.native_cli.inspect=function()error('Pane-free remote relay must not invoke local desktop CLI')end
 enqueue('bind',runtime.json.encode(source));relay.poll()
 check(relay.lanes['endpoint:lane']~=nil and #carrierAcks==1,'trusted ORCH bind observes real source program without local desktop inspection')
 check(runtime.json.decode(carrierSent[1].body).kind=='host_boot','startup announces current host boot before projections without granting a lane')
 local handshake=runtime.json.decode(carrierSent[2].body)
 check(handshake.peer_boot==relay.boot and handshake.bind_request.id=='message-1' and handshake.bind_request.incarnation=='orch-boot','bind response causally echoes the exact current request receipt')
 local bytes=runtime.json.encode(request)..' '
 check(P.decode(bytes)~=nil,'relay fixture uses real exact closed request bytes')
 enqueue('status',bytes,relay.boot);relay.poll()
 check(calls==1 and #carrierAcks==2,'boot-pinned read is handled before delivery acknowledgement')
 local idleSends=#carrierSent;relay.poll()
 check(#carrierSent==idleSends,'idle polling writes no unchanged projections')
 local catalog=clone(request);catalog.op='catalog';catalog.request_id='relay-catalog';catalog.action_id='relay-catalog'
 catalog.target_request_id=nil;catalog.target_request_serial=nil
 catalog.request_serial=1;catalog.next_request_serial=2;catalog.settled_before=1;catalog.consumed=runtime.json.array()
 local catalogBytes=runtime.json.encode(catalog)..' '
 check(P.decode(catalogBytes)~=nil,'catalog stage fixture uses the real closed schema')
 enqueue('catalog',catalogBytes,relay.boot);relay.poll()
 check(stages==1 and lastBytes==catalogBytes and type(lastTag)=='string' and #lastTag==64,'stage preserves exact request bytes and immutable canonical relay binding digest')
 enqueue('status',bytes,'prior-spawn-boot');relay.poll()
 check(calls==1 and runtime.json.decode(carrierSent[#carrierSent].body).error=='stale_endpoint','durable old-boot request is refused rather than refreshed')
 paneList[2].program='unrelated'
 enqueue('status',bytes,relay.boot);relay.poll()
 check(calls==1,'actual ORCH program is checked again at synchronous request consumption')
 paneList[2].program='orchplus.orchestrator'
 carrierBlocked=true
 enqueue('status',bytes,relay.boot);relay.poll()
 local beforeRetry=calls
 check(#carrierInbox==1 and relay.error.code=='backpressure','backpressure retains unacknowledged obligations')
 carrierBlocked=false;relay.poll()
 check(#carrierInbox==0 and calls==beforeRetry,'backpressure retry publishes retained result without reexecuting reducer')
 carrierAckBlocked=true
 enqueue('status',bytes,relay.boot);relay.poll()
 local beforeAckRetry=calls
 carrierAckBlocked=false;relay.poll()
 check(calls==beforeAckRetry and #carrierInbox==0,'delayed transport ACK never reexecutes a consumed domain event')
 local readHandler=D.request
 D.request=function(r)return P.reject(r,'storage_error','Existing configuration requires Review existing setup')end
 for _,op in ipairs({'status','owner_status'})do
  local read=clone(request);read.op=op
  if op=='owner_status' then read.target_request_id=nil;read.target_request_serial=nil end
  local readBytes=runtime.json.encode(read)
  check(P.decode(readBytes)~=nil,'recoverable '..op..' fixture uses the closed request schema')
  enqueue(op,readBytes,relay.boot);relay.poll()
  local lane=relay.lanes['endpoint:lane']
  local published
  for index=#carrierSent,1,-1 do
   local frame=carrierSent[index]
   if frame.binding=='endpoint:lane' and frame.route=='spawn.response' then published=P.unframe(frame.body,read);break end
  end
  local code=if op=='owner_status' then 'migration_blocked' else 'storage_error'
  check(not lane.held and #carrierInbox==0 and published and P.equal(published,lane.body) and published.error.code==code,
   'read-only '..op..' publishes its canonical refusal and ACK without an uncertain effect hold')
 end
 D.request=readHandler
 enqueue('status',bytes,relay.boot);relay.poll()
 check(not relay.lanes['endpoint:lane'].held and relay.lanes['endpoint:lane'].body.error.code=='binding_mismatch',
  'a repaired read recovers on the same exact bound lane')
 local changed=clone(source);changed.origin.window_epoch='new-desktop'
 enqueue('bind',runtime.json.encode(changed));relay.poll()
 check(relay.error.code=='endpoint_conflict' and relay.lanes['endpoint:lane'].source.origin.window_epoch=='desktop-epoch','same endpoint cannot silently rebind to a new desktop incarnation')
 carrierInbox={}
 local setupOrigin={host_pane_id='80',window_key='remote-window',window_epoch='desktop-epoch',native_session_id='1',window_host_id='42'}
 local setup={schema=2,origin='orchplus',op='catalog',request_id='relay-setup',action_id='relay-setup',setup_origin=setupOrigin}
 local setupSource=clone(source);setupSource.relay_endpoint='setup';setupSource.origin=setupOrigin
 sequence+=1;table.insert(carrierInbox,{peer='orchplus',route='spawn.request',incarnation='orch-boot',id='message-'..sequence,binding='setup:lane:bind',body=runtime.json.encode(setupSource)})
 relay.poll()
 local beforeSetup=clone(saved)
 sequence+=1;table.insert(carrierInbox,{peer='orchplus',route='spawn.request',incarnation='orch-boot',id='message-'..sequence,binding='setup:lane:catalog:'..relay.boot,body=runtime.json.encode(setup)})
 relay.poll()
 check(relay.lanes['setup:lane'].setup_read~=nil and P.equal(saved,beforeSetup),'setup catalog stages only a read-only observation without Authority.binding or opening a store')
 local setupLane=relay.lanes['setup:lane']
 local setupReceipt=clone(setupLane.execution_receipt)
 local callback={request_json=runtime.json.encode(setup),observation_id='wrong-observation',relay_execution=clone(setupReceipt)}
 local beforeCatalog=calls
 local function setupCallback()
  sequence+=1;table.insert(carrierInbox,{peer='orchplus',route='spawn.request',incarnation='orch-boot',id='message-'..sequence,
   binding='setup:lane:spawn.setup_catalog:'..relay.boot,body=runtime.json.encode(callback)})
  relay.poll()
 end
 setupCallback()
 check(calls==beforeCatalog and setupLane.setup_read~=nil,'matching transport receipt does not replace the private live setup nonce')
 callback.observation_id=setupLane.setup_read.observation_id;callback.relay_execution.id='foreign-receipt'
 setupCallback()
 check(calls==beforeCatalog and setupLane.setup_read~=nil,'exact private observation cannot borrow another execution receipt')
 local setupRequestHandler=D.request
 D.request=function(r)
  calls+=1;return P.reject(r,'storage_error','Existing configuration requires Review existing setup')
 end
 carrierOrdinaryBlocked=true
 callback.relay_execution=clone(setupReceipt);setupCallback()
 check(calls==beforeCatalog+1 and setupLane.setup_read==nil and P.equal(saved,beforeSetup),'exact source and current private observation complete a read-only catalog once')
 check(not setupLane.held and setupLane.body.error.code=='storage_error',
  'setup review refusal remains the authoritative readable response, not an uncertain callback')
 D.request=setupRequestHandler
 local consumedProof
 for _,frame in ipairs(carrierSent)do
  if frame.route=='spawn.source' then
   local value=runtime.json.decode(frame.body)
   if value.consumed_execution then consumedProof=value;check(frame.priority=='settlement','consumed proof uses reserved settlement capacity')end
  end
 end
 check(consumedProof and P.equal(consumedProof.consumed_execution,setupReceipt),'only SPAWN successful handling emits the exact execution-consumed proof')
 check(#carrierInbox==0,'normal projection backpressure cannot delay ACK after durable response and consumed proof on reserved slots')
 carrierOrdinaryBlocked=false;relay.poll()
 check(calls==beforeCatalog+1,'optional projection drainage never replays the consumed callback')
 setupCallback()
 check(calls==beforeCatalog+1,'duplicate callback cannot consume an already completed observation')
 sequence+=1;table.insert(carrierInbox,{peer='orchplus',route='spawn.request',incarnation='orch-boot',id='message-'..sequence,
  binding='setup:lane:catalog:'..relay.boot,body=runtime.json.encode(setup)})
 relay.poll()
 callback.observation_id=setupLane.setup_read.observation_id;callback.relay_execution=clone(setupLane.execution_receipt)
 setupCallback()
 check(not setupLane.held and calls==beforeCatalog+2 and setupLane.body.error.code=='binding_mismatch' and #carrierInbox==0,
  'setup can refresh on the same lane after a recoverable storage refusal without a reload or rebind')
 local originalReleasable=D.relay_releasable
 D.relay_releasable=function()return false end
 local function releaseSetup()
  sequence+=1;table.insert(carrierInbox,{peer='orchplus',route='spawn.request',incarnation='orch-boot',id='message-'..sequence,binding='setup:lane:release:'..relay.boot,body='{}'})
  relay.poll()
 end
 releaseSetup()
 check(relay.lanes['setup:lane']~=nil and relay.error.code=='release_held','absence of a projection does not prove settled native obligations')
 carrierInbox={}
 D.relay_releasable=function(digest)return digest==setupLane.digest end
 carrierObligations['setup:lane']='released-source-file'
 local beforeRelease=clone(saved);releaseSetup()
 check(relay.lanes['setup:lane']==setupLane and setupLane.released and P.equal(saved,beforeRelease),
  'positive release retains a closed tombstone while matching carrier files remain')
 check(runtime.json.decode(carrierSent[#carrierSent].body).released==true,'lane release is acknowledged through an immutable positive source proof')
 local queriesAfterRelease=carrierQueries;relay.poll()
 check(carrierQueries==queriesAfterRelease,'idle release drainage never scans the full carrier on every timer tick')
 carrierObligations['setup:lane']=nil
 local releaseClock=fake.now;fake.now=function()return releaseClock()+10000 end
 relay.poll();fake.now=releaseClock
 check(relay.lanes['setup:lane']==nil and P.equal(saved,beforeRelease),
  'positive exact-domain proof plus no in-flight files collects only volatile released lane state')
 D.relay_releasable=originalReleasable
 local requestHandler=D.request
 D.request=function()calls+=1;error('injected uncertain reducer callback')end
 enqueue('status',bytes,relay.boot);relay.poll()
 local failedCalls=calls;relay.poll()
 check(calls==failedCalls and #carrierInbox==0 and not relay.lanes['endpoint:lane'].held
  and relay.lanes['endpoint:lane'].body.error.code=='storage_error',
  'read exception publishes a recoverable refusal and ACK without replay or an uncertain-effect hold')
 carrierInbox={};D.request=requestHandler
 sequence+=1;table.insert(carrierInbox,{peer='orchplus',route='spawn.request',incarnation='old-orch',id='message-'..sequence,binding='unknown:lane:status:'..relay.boot,body=bytes})
 relay.poll()
 local unknown=runtime.json.decode(carrierSent[#carrierSent].body)
 check(#carrierInbox==0 and unknown.kind=='held' and unknown.error=='endpoint_unbound' and unknown.rejected_message.incarnation=='old-orch',
  'unbound retained delivery receives a durable advisory and ACK without inventing a source or reissuing authority')
 local retainedOutcome=runtime.json.encode({request_json=bytes,executor_id='old-window',result={status='uncertain'},proof={},orch_claim={}})
 sequence+=1;table.insert(carrierInbox,{peer='orchplus',route='spawn.request',incarnation='old-orch',id='message-'..sequence,
  binding='unknown:lane:spawn.result:'..relay.boot,body=retainedOutcome})
 relay.poll();local heldWrites=#carrierSent;relay.poll()
 check(#carrierInbox==1 and carrierInbox[1].body==retainedOutcome and #carrierSent==heldWrites,
  'unbound native outcome bytes remain held after one durable advisory; transport rejection never discards the sole result')
 carrierInbox={}
 local originalRetain,originalSettle=D.retain_relay_result,D.settle_result_deliveries
 local retainedAct,retainedBytes,retainedDelivery
 D.retain_relay_result=function(act,body,delivery)retainedAct=act;retainedBytes=body;retainedDelivery=clone(delivery);return true end
 D.settle_result_deliveries=function(messages)
  check(#messages==1 and P.equal(messages[1],retainedDelivery)
   and P.equal(carrierTrace.proofs[retainedDelivery.slot],retainedDelivery),
   'retained delayed-result settlement follows positive ACK of that exact carrier frame')
  return true
 end
 sequence+=1;table.insert(carrierInbox,{peer='orchplus',route='spawn.request',incarnation='old-orch',id='message-'..sequence,
  binding='unknown:lane:spawn.result:'..relay.boot,body=retainedOutcome})
 local beforeRetainedAck=#carrierAcks;relay.poll()
 check(retainedAct=='spawn.result' and retainedBytes==retainedOutcome and #carrierInbox==0 and #carrierAcks==beforeRetainedAck+1,
  'delayed-result delivery ACK requires successful exact-byte authority retention before the advisory, not a fabricated execution result')
 D.retain_relay_result,D.settle_result_deliveries=originalRetain,originalSettle
 -- Two independent requests share consent progress, but not execution identity.
 local authorizeHandler=D.authorize
 local revision,authorized=1,{}
 local projectionByRequest={}
 D.execution=function(r)
  local projection=projectionByRequest[r.request_id]
  if not projection or authorized[r.request_id] then return nil end
  local live=clone(projection);live.last_authority_revision=revision;return live
 end
 D.authorize=function(r,nonce,_bridge,_changed,claim,executor,proof,digest)
  local expected=projectionByRequest[r.request_id]
  check(nonce==expected.nonce and P.equal(claim,expected.orch_claim) and executor=='executor-'..r.request_id
   and proof.authority_revision==revision and type(digest)=='string',
   'transport preserves the current nonce, exact claim and unmodified native consent proof for the reducer')
  authorized[r.request_id]=true;revision+=1;return P.body(r,'pending')
 end
 local function laneMessage(endpointName,laneName,act,body,incarnation)
  sequence+=1
  table.insert(carrierInbox,{peer='orchplus',route='spawn.request',incarnation=incarnation or 'orch-boot',id='message-'..sequence,
   binding=endpointName..':'..laneName..':'..act..(if act=='bind' then '' else ':'..relay.boot),body=body})
  relay.poll()
 end
 local interleaved={}
 for index=1,2 do
  local name='parallel-'..index
  local bound=clone(source);bound.lane_id=name
  laneMessage('endpoint',name,'bind',runtime.json.encode(bound))
  local r=P.clone(catalog);r.request_id=name;r.action_id=name
  local raw=runtime.json.encode(r)..' '
  check(P.decode(raw)~=nil,'interleaved callback fixture retains the canonical consumed array and closed request shape')
  projectionByRequest[name]={schema=2,kind='authorize',request_json=raw,nonce='nonce-'..name,boot=relay.boot,
   deadline=fake.now()+30000,orch_claim={request_id=name},native_proof={source_nonce='proof-'..name}}
  laneMessage('endpoint',name,'catalog',raw)
  interleaved[index]={request=r,raw=raw,lane=relay.lanes['endpoint:'..name]}
 end
 local secondReceipt=clone(interleaved[2].lane.execution_receipt)
 local function authorize(item)
  local projection=projectionByRequest[item.request.request_id]
  laneMessage('endpoint',item.lane.source.lane_id,'spawn.authorize',runtime.json.encode({
   request_json=item.raw,nonce=projection.nonce,executor_id='executor-'..item.request.request_id,
   orch_claim=projection.orch_claim,proof={authority_revision=revision},relay_execution=clone(item.lane.execution_receipt)}))
 end
 authorize(interleaved[1])
 for _=1,4 do relay.poll()end
 check(P.equal(secondReceipt,interleaved[2].lane.execution_receipt),
  'interleaved session revision changes alone never republish or invalidate the second execution receipt')
 local second=interleaved[2]
 for _,field in ipairs({'nonce','orch_claim','native_proof','request_json'})do
  local projection=projectionByRequest[second.request.request_id]
  local original=clone(projection[field])
  projection[field]=if type(original)=='table' then {changed=true} else original..'-changed'
  laneMessage('endpoint',second.lane.source.lane_id,'spawn.authorize',runtime.json.encode({
   request_json=second.raw,nonce=projection.nonce,executor_id='executor-'..second.request.request_id,
   orch_claim=projection.orch_claim,proof={authority_revision=revision},relay_execution=clone(second.lane.execution_receipt)}))
  check(not authorized[second.request.request_id] and relay.error.code=='stale_execution',
   'only unrelated session revision is excluded; changed '..field..' still refuses the callback')
  projection[field]=original
  for _=1,4 do relay.poll()end
 end
 authorize(interleaved[2])
 check(authorized['parallel-1'] and authorized['parallel-2'] and #carrierInbox==0,
  'both interleaved callbacks reach the reducer without stale_execution or effect replay')
 do
  local previousAuthorize=D.authorize
  local payload=assert(originalRequest(setup,nil,1,function()end).payload)
  D.authorize=function(...)
   local r=...
   previousAuthorize(...)
   return P.body(r,'catalog',payload)
  end
  local bound=clone(source);bound.lane_id='consecutive'
  laneMessage('endpoint',bound.lane_id,'bind',runtime.json.encode(bound))
  local lane=relay.lanes['endpoint:consecutive']
  local items={}
  for index=1,2 do
   local r=P.clone(catalog);r.request_id='consecutive-'..index;r.action_id=r.request_id
   r.request_serial=index;r.next_request_serial=index+1;r.settled_before=index
   local raw=runtime.json.encode(r)..' '
   projectionByRequest[r.request_id]={schema=2,kind='authorize',request_json=raw,nonce='nonce-'..r.request_id,
    boot=relay.boot,deadline=fake.now()+30000,orch_claim={request_id=r.request_id}}
   items[index]={request=r,raw=raw,lane=lane}
  end
  carrierAckBlocked=true
  laneMessage('endpoint',bound.lane_id,'catalog',items[1].raw)
  check(lane.request_json==items[1].raw and lane.published_execution==nil and #carrierInbox==1,
   'catalog stage cannot expose a native challenge before its own immutable input ACK succeeds')
  carrierTrace.events={};carrierAckBlocked=false;relay.poll()
  local stageAck,executionPublished
  for index,event in ipairs(carrierTrace.events)do
   if event.operation=='ack' and event.message.body==items[1].raw then stageAck=index
   elseif event.operation=='send' and event.message.binding==lane.key and event.message.route=='spawn.execution' and event.message.body~='' then executionPublished=index end
  end
  check(stageAck and executionPublished and stageAck<executionPublished and lane.published_execution~=nil,
   'read-only stage drainage ACKs exact input before publishing its one native observation')
  local firstReceipt=clone(lane.execution_receipt)
  carrierAckBlocked=true;authorize(items[1])
  local callbackBytes=assert(carrierInbox[1]).body
  local consumed
  for _,frame in ipairs(carrierSent)do
   if frame.binding==lane.key and frame.route=='spawn.source' then
    local value=runtime.json.decode(frame.body)
    if P.equal(value.consumed_execution,firstReceipt) then consumed=true end
   end
  end
  check(lane.body.status=='catalog' and consumed and #carrierInbox==1,
   'completed catalog and exact source-consumption proof can reach ORCH before callback input ACK')
  local beforeNext=stages
  sequence+=1;table.insert(carrierInbox,1,{peer='orchplus',route='spawn.request',incarnation='orch-boot',id='message-'..sequence,
   binding=lane.key..':catalog:'..relay.boot,body=items[2].raw})
  relay.poll()
  check(stages==beforeNext and lane.request_json==items[1].raw and #carrierInbox==2
   and relay.error.code~='callback_pending',
   'next consecutive catalog waits in its original input behind completed read settlement without a terminal lane hold')
  carrierTrace.events={};carrierAckBlocked=false;relay.poll()
  local callbackAck,received
  for index,event in ipairs(carrierTrace.events)do
   if event.operation=='ack' and event.message.body==callbackBytes then callbackAck=index
   elseif event.operation=='receive' then received=index end
  end
  check(callbackAck and received and callbackAck<received and stages==beforeNext+1
   and lane.request_json==items[2].raw and not P.equal(firstReceipt,lane.execution_receipt),
   'completed callback drains before receiving the earlier-slot next request and stages its unchanged bytes once')
  authorize(items[2])
  check(lane.body.status=='catalog' and lane.body.request_id==items[2].request.request_id and #carrierInbox==0 and not lane.held,
   'consecutive catalog completes on the original source lane without rebind, manual acknowledgement or effect replay')
  local completedRevision=revision
  laneMessage('endpoint',bound.lane_id,'spawn.authorize',callbackBytes)
  check(revision==completedRevision and lane.body.request_id==items[2].request.request_id,
   'late first-catalog callback cannot borrow the second request receipt or repeat authorization')
  D.authorize=previousAuthorize
 end
 D.authorize=authorizeHandler
 D.execution=function()return nil end
 local function laneCount()
  local count=0;for _ in pairs(relay.lanes)do count+=1 end;return count
 end
 D.relay_releasable=function()return false end
 for index=1,32 do
  local bound=clone(source);bound.lane_id='capacity-'..index
  laneMessage('endpoint',bound.lane_id,'bind',runtime.json.encode(bound))
 end
 check(laneCount()>24 and laneCount()<64 and relay.lanes['endpoint:capacity-32']~=nil,
  'logical lanes exceed carrier slot count without treating 24 transient files as a lane ceiling')
 local countBeforeFill=laneCount()
 for index=countBeforeFill+1,64 do
  local bound=clone(source);bound.lane_id='fill-'..index
  laneMessage('endpoint',bound.lane_id,'bind',runtime.json.encode(bound))
 end
 check(laneCount()==64,'the logical lane bound is exactly 64')
 local freshSource=clone(source);freshSource.relay_endpoint='fresh';freshSource.relay_boot='new-orch'
 local function freshBind()
  laneMessage('fresh','lane','bind',runtime.json.encode(freshSource),'new-orch')
 end
 freshBind()
 check(laneCount()==64 and relay.lanes['fresh:lane']==nil and relay.error.code=='backpressure',
  'a new producer incarnation is not positive domain-inert proof')
 local oldLane=relay.lanes['endpoint:lane']
 oldLane.source.host_pane_id='81';oldLane.source.origin=clone(oldLane.source.origin);oldLane.source.origin.host_pane_id='81'
 freshBind()
 check(relay.lanes[oldLane.key]==oldLane and relay.lanes['fresh:lane']==nil,
  'source absence cannot collect a lane without positive domain-inert proof')
 D.relay_releasable=function(digest)return digest==oldLane.digest end
 local function stillHeld(label)
  freshBind()
  check(relay.lanes[oldLane.key]==oldLane and relay.lanes['fresh:lane']==nil,
   'positive domain proof cannot collect while '..label)
 end
 oldLane.setup_read={deadline=fake.now()+30000,request=setup,observation_id='retained-observation'}
 stillHeld('a setup observation remains');oldLane.setup_read=nil
 oldLane.consumed_execution={id='consumed',incarnation=relay.boot}
 stillHeld('a consumed execution proof remains');oldLane.consumed_execution=nil
 D.execution=function(r)return if r.request_id==oldLane.request.request_id then {kind='authorize',nonce='still-current'} else nil end
 stillHeld('a current execution remains');D.execution=function()return nil end
 do
  local previousAckBlocked=carrierAckBlocked
  carrierAckBlocked=true
  laneMessage('endpoint','lane','status',bytes)
  stillHeld('a processed message remains')
  carrierAckBlocked=previousAckBlocked
  relay.poll()
 end
 relay.outgoing[oldLane.key..'\nspawn.current']={frame={binding=oldLane.key,body='pending'}}
 stillHeld('an outgoing send attempt remains');relay.outgoing[oldLane.key..'\nspawn.current']=nil
 for _,obligation in ipairs({'incoming-data','outgoing-data','incoming-ack','outgoing-ack'})do
  carrierObligations[oldLane.key]=obligation;stillHeld('the carrier retains '..obligation)
 end
 carrierObligations[oldLane.key]=nil
 carrierQuiescentError=true;stillHeld('carrier absence cannot be read');carrierQuiescentError=false
 freshBind()
 check(relay.lanes[oldLane.key]==nil and relay.lanes['fresh:lane']~=nil and laneCount()==64,
  'only positive domain-inert and carrier-empty proof collects an old lane to admit the 64th current binding')
 local beforeLate=stages
 laneMessage('endpoint','lane','catalog',catalogBytes)
 check(stages==beforeLate and relay.lanes['endpoint:lane']==nil and relay.error.code=='endpoint_unbound',
  'a delayed event after collection is refused, never recreated or replayed as a native effect')
 D.relay_releasable=originalReleasable
 modules.native_cli.inspect=priorInspect
 D.request,D.current,D.execution,D.stage=originalRequest,originalCurrent,originalExecution,originalStage
 saved,paneList=priorSaved,priorPanes
end
do
 -- Real private control challenges and the actual publisher; only carrier IO
 -- and time are injected. Retirement is never a successful domain callback.
 local priorSaved,priorPanes,priorRelay,priorDispatch=saved,paneList,modules.dispatch_relay,modules.dispatch
 local priorNow=rawget(fake,'now')
 saved={};assert(A.open('host:control-retirement',1,nil))
 local base=clone(saved)
 local D,relay,lane,now,sequence,authorizations
 local source={schema=1,relay_endpoint='revocation',relay_boot='revocation-orch',lane_id='lane',host_pane_id='80',
  source_nonce='revocation-source',origin={logical_session_id='revocation-session',owner_id='owner',owner_generation=1,
   host_pane_id='80',alias_nonce='revocation-source',window_key='remote-window',window_epoch='desktop-epoch',
   native_session_id='1',window_host_id='42'},desktop_proof='delegated_native_window',host_program='orchplus.orchestrator'}
 local function request(id)
  return {schema=2,origin='orchplus',op='admit_session',request_id=id,action_id=id,authority_namespace='revocation-authority',
   authority_revision=10,logical_session_id='revocation-session',admission_seq=1,
   control_origin={kind='active',binding=clone(source.origin),controller_pane='180'},
   compatibility={schema=1,kind='current',protocol=2,authority_namespace='revocation-authority',spawn_namespace='revocation-spawn'},
   generation_floor=0,next_request_serial=2,settled_before=1,consumed=runtime.json.array()}
 end
 local function enqueue(act,body)
  sequence+=1
  table.insert(carrierInbox,{peer='orchplus',recipient='spawn',route='spawn.request',incarnation='revocation-orch',id='control-'..sequence,
   binding='revocation:lane:'..act..(if act=='bind' then '' else ':'..relay.boot),body=body})
 end
 local function reset()
  saved=clone(base)
  saved['dispatch-v1']={version=2,revision=0,namespace='revocation-spawn',authority_namespace='revocation-authority',
   next_id=1,admission_cursor=0,sessions={},workers={},controls={},requests={},mailboxes=load('mailbox').empty(),gates={}}
  saved['dispatch-v1-initialized']='revocation-spawn'
  paneList={{pane=80,program='orchplus.orchestrator'}}
  carrierInbox,carrierSent,carrierAcks={},{},{}
  carrierBlocked,carrierAckBlocked,carrierOrdinaryBlocked=false,false,false;carrierSendError=nil
  carrierTrace={events={},data={},proofs={},probe_error=nil,receives=0}
  now,sequence,authorizations=10000,0,0;fake.now=function()return now end
  modules.dispatch=nil;D=load('dispatch')
  D.current=function()return nil end;D.qualification=function()end
  local authorize=D.control_authorize
  D.control_authorize=function(...)
   authorizations+=1;return authorize(...)
  end
  modules.dispatch_relay=nil;relay=load('dispatch_relay').install()
  enqueue('bind',runtime.json.encode(source));relay.poll()
  lane=assert(relay.lanes['revocation:lane'])
 end
 local function stage(id)
  local r=request(id);local bytes=runtime.json.encode(r)..' '
  check(P.decode(bytes)~=nil,'control retirement fixture uses real closed control request bytes')
  enqueue(r.op,bytes);relay.poll()
  return r,bytes
 end
 local function peer(r)
  return {protocol=2,phase='stable',authority_namespace=r.authority_namespace,authority_revision=r.authority_revision,
   spawn_namespace='revocation-spawn',session={admission_seq=r.admission_seq,control={phase='open',generation_floor=0,
    request_floor=1,next_request_serial=2,last_authority_revision=r.authority_revision,binding=clone(source.origin)}}}
 end
 local function callback(challenge,receipt)
  enqueue('spawn.control_authorize',runtime.json.encode({request_json=challenge.request_json,nonce=challenge.nonce,
   executor_id='control-window',peer=peer(challenge.request),relay_execution=clone(receipt)}))
  relay.poll()
 end
 local function proofs()
  local out={}
  for _,frame in ipairs(carrierSent)do
   if frame.binding==lane.key and frame.route=='spawn.source' then
    local value=runtime.json.decode(frame.body)
    if value.revoked_execution then
     check(value.consumed_execution==nil and value.peer_boot==relay.boot and P.equal(value.bind_request,lane.bind_request)
      and frame.priority=='settlement','revocation is exact source-bound retirement on reserved capacity, never consumption')
     table.insert(out,{frame=frame,value=value})
    end
   end
  end
  return out
 end
 local function rejected(challenge)
  local response=D.control_authorize(challenge.request,challenge.nonce,80,'control-window',peer(challenge.request),lane.digest)
  authorizations-=1
  check(response and response.error and response.error.code=='stale_revision','invalidated exact private control callback cannot execute')
 end
 do
  reset()
  local stageHandler,stages=D.stage,0
  D.stage=function(...)stages+=1;return stageHandler(...)end
  carrierAckBlocked=true
  enqueue('bind',runtime.json.encode(source));relay.poll()
  local bound=clone(assert(carrierInbox[1]))
  local r=request('after-delayed-bind');local bytes=runtime.json.encode(r)..' \n\t'
  enqueue(r.op,bytes)
  table.insert(carrierInbox,1,table.remove(carrierInbox))
  local sends=#carrierSent
  relay.poll()
  local retained=clone(assert(carrierInbox[1]));relay.poll()
  check(stages==0 and authorizations==0 and lane.request_json==nil and #carrierInbox==2
   and P.equal(carrierInbox[1],retained) and retained.body==bytes and #carrierSent==sends,
   'boot-pinned control input behind a delayed bind stays in its exact original carrier without ACK, refusal or domain handling')
  carrierTrace.events={};carrierAckBlocked=false;relay.poll()
  local boundAck,received
  for index,event in ipairs(carrierTrace.events)do
   if event.operation=='ack' and P.equal(event.message,bound) then boundAck=index
   elseif event.operation=='receive' then received=index end
  end
  check(boundAck and received and boundAck<received and stages==1 and lane.request_json==bytes
   and #carrierInbox==0 and lane.published_execution and lane.published_execution.request_json==bytes,
   'key-only bind settlement progresses before later input delivery and stages the original complete control payload once')
  callback(clone(lane.published_execution),clone(lane.execution_receipt))
  for _=1,4 do relay.poll()end
  check(authorizations==1 and stages==1 and saved['dispatch-v1'].sessions['revocation-session']~=nil
   and lane.request_json==bytes and not lane.held,
   'delayed bind overlap eventually admits the original session once without rebind or effect replay')
 end
 do
  reset()
  local stageHandler,stages=D.stage,0
  D.stage=function(...)stages+=1;return stageHandler(...)end
  local _,bytes=stage('completed-control')
  local challenge,receipt=clone(lane.published_execution),clone(lane.execution_receipt)
  carrierAckBlocked=true;callback(challenge,receipt)
  local completed=clone(assert(carrierInbox[1]))
  check(authorizations==1 and lane.body.category=='current_admission' and #carrierInbox==1,
   'control admission completes its one domain invocation before callback ACK succeeds')
  local nextRequest=request('after-completed-control');local nextBytes=runtime.json.encode(nextRequest)..' \n\t'
  enqueue(nextRequest.op,nextBytes)
  table.insert(carrierInbox,1,table.remove(carrierInbox))
  local sends=#carrierSent
  relay.poll()
  local retained=clone(assert(carrierInbox[1]));relay.poll()
  check(stages==1 and authorizations==1 and lane.request_json==bytes and #carrierInbox==2
   and P.equal(carrierInbox[1],retained) and retained.body==nextBytes and #carrierSent==sends,
   'safe non-read control callback overlap preserves later input unchanged without sticky callback refusal or duplicate authorization')
  carrierTrace.events={};carrierAckBlocked=false;relay.poll()
  local callbackAck,received
  for index,event in ipairs(carrierTrace.events)do
   if event.operation=='ack' and P.equal(event.message,completed) then callbackAck=index
   elseif event.operation=='receive' then received=index end
  end
  for _=1,4 do relay.poll()end
  check(callbackAck and received and callbackAck<received and stages==2 and authorizations==1
   and lane.request_json==nextBytes and #carrierInbox==0 and not lane.held,
   'completed control callback drains independently before the earlier-slot successor progresses once with its exact payload')
 end
 reset();stage('live')
 local live=clone(assert(lane.published_execution));local liveReceipt=clone(lane.execution_receipt)
 now=live.deadline;relay.poll()
 check(#proofs()==0 and P.equal(lane.execution_receipt,liveReceipt),'control challenge remains live at its exact deadline')
 paneList[1].program='unavailable';relay.poll()
 check(#proofs()==0 and P.equal(lane.published_execution,live),'source disappearance alone never retires or replaces a live control challenge')
 paneList[1].program='orchplus.orchestrator'
 local execution=D.execution;D.execution=function()return nil end;relay.poll();D.execution=execution
 check(#proofs()==0 and P.equal(lane.execution_receipt,liveReceipt),'an absent execution projection is not positive private revocation evidence')
 for _,field in ipairs({'boot','request_json','deadline','request'})do
  local wrong=clone(live)
  if field=='deadline' then wrong.deadline+=1
  elseif field=='request' then wrong.request.authority_revision+=1
  else wrong[field]..='-changed' end
  check(not D.revoke_control(wrong,80,lane.digest) and P.equal(D.execution(live.request,80,lane.digest),live),
   'private control invalidation requires exact '..field)
 end
 check(not D.revoke_control(live,81,lane.digest) and not D.revoke_control(live,80,string.rep('f',64))
  and P.equal(D.execution(live.request,80,lane.digest),live),'private control invalidation cannot borrow another bridge or relay binding')
 local beforeExpiry=clone(saved['dispatch-v1'])
 now=live.deadline+1;carrierOrdinaryBlocked=true;relay.poll()
 local retired=proofs()
 check(#retired==1 and P.equal(retired[1].value.revoked_execution,liveReceipt) and lane.revoked_execution==nil
  and P.equal(saved['dispatch-v1'],beforeExpiry),'positive private expiry emits exactly one carrier retirement without domain mutation')
 rejected(live);callback(live,liveReceipt)
 check(authorizations==0,'expired transport callback is refused before the control reducer')
 relay.poll();check(#proofs()==1,'blank projection backpressure never republishes the settled retirement proof')
 stage('after-expiry')
 check(lane.pending_execution~=nil and lane.published_execution.nonce==live.nonce,
  'reserved proof can settle while ordinary replacement projection remains backpressured')
 carrierOrdinaryBlocked=false;relay.poll()
 local successor=clone(assert(lane.published_execution));local successorReceipt=clone(lane.execution_receipt)
 check(successor.request.request_id=='after-expiry' and successor.nonce~=live.nonce,'later control challenge publishes after obsolete challenge retirement')
 local proofIndex,nextIndex
 for index,frame in ipairs(carrierSent)do
  if frame.id==retired[1].frame.id then proofIndex=index end
  if frame.route=='spawn.execution' and frame.id==successorReceipt.id then nextIndex=index end
 end
 check(proofIndex and nextIndex and proofIndex<nextIndex,'producer publishes retirement before the later control execution')
 carrierOrdinaryBlocked=true
 callback(successor,successorReceipt)
 check(authorizations==1 and saved['dispatch-v1'].sessions['revocation-session']~=nil and #proofs()==1,
  'only the fresh exact native callback admits the session; successful control consumption is not revocation')
 local consumed=false
 for _,frame in ipairs(carrierSent)do
  if frame.binding==lane.key and frame.route=='spawn.source' then
   local value=runtime.json.decode(frame.body)
   if P.equal(value.consumed_execution,successorReceipt) then consumed=value.revoked_execution==nil and frame.priority=='settlement' end
  end
 end
 check(consumed,'successful native control handling preserves its separate exact consumed-execution proof')
 check(lane.execution_retired and P.equal(lane.execution_receipt,successorReceipt) and lane.pending_execution~=nil,
  'durable exact consumption retires the published control identity even while its blank replacement is backpressured')
 now=successor.deadline+1;relay.poll();stage('after-consumption')
 carrierOrdinaryBlocked=false;relay.poll()
 check(lane.published_execution and lane.published_execution.request.request_id=='after-consumption'
  and #proofs()==1 and authorizations==1,
  'successful control consumption followed by expiry and a new request never emits duplicate retirement for the consumed receipt')
 reset();stage('superseded')
 local old=clone(lane.published_execution);local oldReceipt=clone(lane.execution_receipt)
 stage('replacement')
 check(now<old.deadline and #proofs()==1 and P.equal(proofs()[1].value.revoked_execution,oldReceipt)
  and lane.published_execution.request.request_id=='replacement','positive request supersession retires only the old live private challenge')
 rejected(old)
 check(D.execution(lane.request,80,lane.digest).nonce==lane.published_execution.nonce,'retiring a superseded challenge leaves its replacement executable')
 reset();stage('same-request')
 old=clone(lane.published_execution);oldReceipt=clone(lane.execution_receipt);now=old.deadline+1
 stage('same-request')
 check(#proofs()==1 and P.equal(proofs()[1].value.revoked_execution,oldReceipt)
  and D.execution(lane.request,80,lane.digest).nonce~=old.nonce,'positive nonce replacement retires the old receipt without deleting the new private challenge')
 rejected(old)
 reset();stage('invalidation-held')
 old=clone(lane.published_execution);oldReceipt=clone(lane.execution_receipt)
 local revoke=D.revoke_control;D.revoke_control=function()return false end
 now=old.deadline+1;relay.poll()
 check(#proofs()==0 and P.equal(lane.execution_receipt,oldReceipt) and P.equal(lane.published_execution,old),
  'failed positive invalidation retains the original frame without a proof or a misleading blank replacement')
 D.revoke_control=revoke;relay.poll()
 check(#proofs()==1 and P.equal(proofs()[1].value.revoked_execution,oldReceipt),'proof publication resumes only after exact private invalidation succeeds')
 for _,code in ipairs({'backpressure','write_failed'})do
  reset();stage('proof-'..code)
  old=clone(lane.published_execution);oldReceipt=clone(lane.execution_receipt)
  now=old.deadline+1;carrierSendError={route='spawn.source',code=code};relay.poll()
  local retained=clone(assert(relay.outgoing[lane.key..'\nspawn.source']).frame)
  check(lane.revoked_execution and P.equal(lane.revoked_execution,oldReceipt) and #proofs()==0
   and retained.priority=='settlement','failed retirement retains the exact pending proof and reserved priority')
  rejected(old)
  local nextRequest,nextBytes=stage('proof-next-'..code)
  callback(old,oldReceipt);now+=100;relay.poll()
  check(P.equal(relay.outgoing[lane.key..'\nspawn.source'].frame,retained) and lane.request.request_id==old.request.request_id
   and #carrierInbox==2 and authorizations==0,'source backpressure preserves immutable proof bytes and leaves later inputs unacknowledged')
  carrierSendError=nil;carrierOrdinaryBlocked=true;relay.poll()
  check(#proofs()==1 and proofs()[1].frame.id==retained.id and proofs()[1].frame.body==retained.body
   and lane.revoked_execution==nil,'retirement retries its original identity through reserved settlement, including ambiguous write failure')
  relay.poll();carrierOrdinaryBlocked=false;relay.poll()
  check(lane.request_json==nextBytes and lane.published_execution.request.request_id==nextRequest.request_id
   and #carrierInbox==0 and authorizations==0 and #proofs()==1,'later request progresses after exact proof settlement without replaying an old callback')
 end
 for _,code in ipairs({'backpressure','write_failed'})do
  reset();carrierSendError={route='spawn.execution',code=code};stage('attempt-'..code)
  local pending=clone(assert(lane.pending_execution).value)
  local retained=clone(assert(relay.outgoing[lane.key..'\nspawn.execution']).frame)
  now+=100;stage('attempt-next-'..code)
  now=pending.deadline+1;relay.poll()
  check(P.equal(relay.outgoing[lane.key..'\nspawn.execution'].frame,retained) and #proofs()==0,
   'failed outgoing execution retains its original bytes and identity through supersession and expiry')
  carrierSendError=nil;relay.poll()
  local retiredAttempt=proofs()
  check(#retiredAttempt==1 and retiredAttempt[1].value.revoked_execution.id==retained.id
   and lane.published_execution.request.request_id=='attempt-next-'..code,
   'the attempted old frame is published and explicitly retired before a fresh control challenge')
  local executionIndex,retirementIndex,replacementIndex
  for index,frame in ipairs(carrierSent)do
   if frame.id==retained.id then executionIndex=index;check(frame.body==retained.body,'successful old execution retry is byte-identical') end
   if frame.id==retiredAttempt[1].frame.id then retirementIndex=index end
   if frame.id==lane.execution_receipt.id and frame.route=='spawn.execution' then replacementIndex=index end
  end
  check(executionIndex and retirementIndex and replacementIndex and executionIndex<retirementIndex and retirementIndex<replacementIndex,
   'attempted frame, exact retirement, and successor have stable producer ordering')
  rejected(pending)
 end
 for _,kind in ipairs({'authorize','launch','adopt','enrol','wake','stop','result','wakeresult'})do
  reset()
  local projection={schema=2,kind=kind,nonce='native-effect',request_json='native-effect',deadline=now+10}
  D.execution=function()return projection end
  stage('effect-'..kind)
  local receipt=clone(lane.execution_receipt)
  now+=11;projection=nil;relay.poll()
  check(#proofs()==0 and not lane.revoked_execution and not P.equal(receipt,lane.execution_receipt),
   'native '..kind..' projection expiry never creates private-control retirement proof')
 end
 fake.now=priorNow
 modules.dispatch_relay,modules.dispatch=priorRelay,priorDispatch;saved,paneList=priorSaved,priorPanes
 carrierInbox,carrierSent,carrierAcks={},{},{}
 carrierBlocked,carrierAckBlocked,carrierOrdinaryBlocked=false,false,false;carrierSendError=nil
 carrierTrace={events={},data={},proofs={},probe_error=nil,receives=0}
end
do
 -- Exercise the real host consumer with a durable-dispatch seam. Reducer result
 -- semantics are covered in dispatch.luau; this seam exposes only pending exact
 -- deliveries and atomic settlement, so transport ordering cannot be faked by
 -- a successful domain response.
 local D=load('dispatch')
 local priorSaved,priorPanes,priorRelay=saved,paneList,modules.dispatch_relay
 local originals={}
 for _,name in ipairs({'stage','execution','current','claim','result_deliveries','settle_result_deliveries','retain_relay_result','relay_releasable'})do originals[name]=D[name] end
 saved={}
 do
  local before=writes
  local pending=originals.result_deliveries()
  check(pending and #pending==0 and next(saved)==nil and writes==before,
   'real dispatch pending-delivery read on a fresh host never initializes authority or writes a receipt store')
 end
 local state,relay
 local source={schema=1,relay_endpoint='delivery',relay_boot='delivery-orch',lane_id='lane',host_pane_id='80',source_nonce='delivery-source',
  origin={logical_session_id='delivery-session',owner_id='owner',owner_generation=1,host_pane_id='80',alias_nonce='delivery-source',
   window_key='remote-window',window_epoch='desktop-epoch',native_session_id='1',window_host_id='42'},
  desktop_proof='delegated_native_window',host_program='orchplus.orchestrator'}
 local request={schema=2,origin='orchplus',op='launch',request_id='delivery-launch',action_id='delivery-action',authority_namespace='delivery-authority',
  logical_session_id='delivery-session',admission_seq=1,controller_pane='180',controller_generation=1,origin_binding=clone(source.origin),
  request_serial=1,next_request_serial=2,settled_before=1,consumed=runtime.json.array(),record_id='worker',record_revision=0,
  work_id='work',prompt='delivery fixture',cwd='/work',placement='tab',fresh=true,mailbox_handle='mailbox',
  enrolment={worker_id='worker-id',worker_generation=1,enrolment_token='aaaaaaaaaaaaaaaa',assignment_sha256=load('wire/codec').sha256('delivery fixture')}}
 local requestBytes=runtime.json.encode(request)
 check(P.decode(requestBytes)~=nil,'delivery host fixture uses the real closed launch request codec')
 local function message(id,act,body,slot,boot)
  return {peer='orchplus',recipient='spawn',incarnation='delivery-orch',id=id,route='spawn.request',
   binding='delivery:lane:'..act..(if act=='bind' then '' else ':'..(boot or relay.boot)),body=body,slot=slot}
 end
 local function callbackBytes(receipt)
  return runtime.json.encode({request_json=requestBytes,executor_id='delivery-executor',
   orch_claim={grant_id='delivery-grant'},proof={},result={status='uncertain'},relay_execution=receipt})..' '
 end
 local function reset()
  saved={};paneList={{pane=80,program='orchplus.orchestrator'}}
  assert(A.open('host:delivery-fixture',1,nil))
  carrierInbox,carrierSent,carrierAcks={},{},{}
  carrierBlocked,carrierAckBlocked,carrierOrdinaryBlocked=false,false,false
  carrierObligations,carrierQuiescentError={},false
  carrierTrace={events={},data={},proofs={},probe_error=nil,receives=0}
  state={pending={},applies=0,retains=0,settlements=0,fail_settlement=false,staged=false}
  D.stage=function()state.staged=true;return P.body(request,'pending')end
  D.execution=function()
   return if state.staged and state.applies==0 then {schema=2,kind='result',request_json=requestBytes,nonce='delivery-nonce'} else nil
  end
  D.current=function()return nil end
  D.claim=function(r,_executor,operation,_result,_proof,_claim,digest,delivery)
   check(operation=='result' and type(digest)=='string' and #digest==64,'native result reaches the real adapter result path')
   check(delivery and delivery.body==state.callback.body and P.equal(delivery,state.callback),
    'native outcome commit receives the exact closed carrier message including slot and callback bytes')
   state.applies+=1;state.pending[delivery.id]=clone(delivery);carrierEvent('commit',delivery)
   return P.reject(r,'binding_mismatch','Fixture terminal native result')
  end
  D.result_deliveries=function()
   local pending={};for _,delivery in pairs(state.pending)do table.insert(pending,clone(delivery))end
   table.sort(pending,function(a,b)return a.slot<b.slot end)
   check(#pending<=24,'pending delivery recovery is bounded by carrier slots, not logical lane count')
   return pending
  end
  D.settle_result_deliveries=function(messages)
   state.settlements+=1;carrierEvent('settlement',messages)
   check(#messages>0 and #messages<=24,'host commits one bounded positive-proof batch')
   for _,delivery in ipairs(messages)do
    check(P.equal(state.pending[delivery.id],delivery) and P.equal(carrierTrace.proofs[delivery.slot],delivery),
     'settlement accepts only a pending exact full frame with positive actual ACK proof')
   end
   if state.fail_settlement then return false,'injected authority save failure' end
   for _,delivery in ipairs(messages)do state.pending[delivery.id]=nil end
   return true
  end
  D.retain_relay_result=function(act,bytes,delivery)
   state.retains+=1
   check(act=='spawn.result' and delivery and delivery.body==bytes,'recovery retains original native bytes with their exact delivery')
   local prior=state.pending[delivery.id]
   if prior and not P.equal(prior,delivery) then return false end
   state.pending[delivery.id]=clone(delivery);return true
  end
  D.relay_releasable=function()return next(state.pending)==nil end
  modules.dispatch_relay=nil;relay=load('dispatch_relay').install()
 end
 local function reload()
  modules.dispatch_relay=nil;relay=load('dispatch_relay').install()
 end
 local function prepare()
  reset()
  table.insert(carrierInbox,message('delivery-bind','bind',runtime.json.encode(source),1));relay.poll()
  table.insert(carrierInbox,message('delivery-request','launch',requestBytes,1));relay.poll()
  local lane=assert(relay.lanes['delivery:lane'])
  check(lane.execution_receipt~=nil,'native callback is pinned to a genuinely published host execution')
  local receipt=clone(lane.execution_receipt)
  state.callback=message('delivery-result','spawn.result',callbackBytes(receipt),1)
  carrierTrace.events={};carrierSent={}
  return lane,receipt
 end
 local function operationIndex(operation,id)
  for index,event in ipairs(carrierTrace.events)do
   if event.operation==operation and (id==nil or event.message and event.message.id==id) then return index end
  end
  return nil
 end
 local function callbackOutputs(receipt)
  local response,consumed=false,false
  for _,frame in ipairs(carrierSent)do
   if frame.binding=='delivery:lane' and frame.route=='spawn.response' and frame.body~='' then
    local value=P.unframe(frame.body,request)
    check(value~=nil,'native result publication decodes through the real request-bound response framing contract')
    response=value.status=='rejected' and value.error.code=='binding_mismatch'
   elseif frame.binding=='delivery:lane' and frame.route=='spawn.source' then
    local value=runtime.json.decode(frame.body)
    if value.consumed_execution then
     check(P.equal(value.consumed_execution,receipt),'eventual source publication names only the exact consumed execution')
     consumed=true
    end
   end
  end
  return response,consumed
 end
 do
  reset();carrierOrdinaryBlocked=true;relay.poll()
  check(relay.announced and #carrierSent==1 and runtime.json.decode(carrierSent[1].body).kind=='host_boot',
   'fresh host reconciliation escapes saturated ordinary projection slots through bounded settlement capacity')
  check(state.applies==0 and state.settlements==0,'boot withdrawal neither executes nor fabricates native outcome settlement')
 end
 do
  local _,receipt=prepare()
  carrierBlocked=true;table.insert(carrierInbox,clone(state.callback));relay.poll()
  check(state.applies==1 and #carrierInbox==0 and #carrierSent==0,
   'native input ACK is independent of blocked response/source publication')
  check(next(relay.processed)~=nil,'ACKed input retains volatile output work when both output routes are blocked')
  local committed,acked=operationIndex('commit'),operationIndex('ack','delivery-result')
  check(committed and acked and committed<acked,'native outcome and delivery fence commit before input ACK')
  for index,event in ipairs(carrierTrace.events)do
   if event.operation=='send' and event.message.binding=='delivery:lane' then
    check(index>acked,'no callback response or consumed authorization is attempted before input ACK')
   end
  end
  carrierBlocked=false
  for _=1,4 do relay.poll()end
  local response,consumed=callbackOutputs(receipt)
  check(response and consumed and next(relay.processed)==nil and state.applies==1,
   'independent processed-output drainage publishes response and exact consumed execution without redelivery or reducer replay')
  check(next(state.pending)==nil and carrierTrace.data[1]==nil and carrierTrace.proofs[1]==nil,
   'positive settlement eventually clears the delivery fence and reclaims the original carrier slot')
 end
 do
  local _,receipt=prepare()
  carrierAckBlocked=true;table.insert(carrierInbox,clone(state.callback));relay.poll()
  check(state.applies==1 and #carrierInbox==1 and P.equal(state.pending[state.callback.id],state.callback),
   'failed ACK write preserves the original input and exact durable delivery fence')
  check(#carrierSent==0 and not D.relay_releasable(),
   'failed ACK grants neither response/source authorization nor lane release')
  for _,event in ipairs(carrierTrace.events)do
   check(event.operation~='send' or event.message.binding~='delivery:lane',
    'failed ACK also prevents optional execution/current projection from bypassing the fence')
  end
  carrierAckBlocked=false
  for _=1,4 do relay.poll()end
  local response,consumed=callbackOutputs(receipt)
  check(state.applies==1 and #carrierInbox==0 and response and consumed and next(state.pending)==nil,
   'ACK write retry settles once, publishes exact outputs, and never reruns the native reducer')
 end
 do
  local lane=prepare()
  carrierAckBlocked=true;table.insert(carrierInbox,clone(state.callback));relay.poll()
  local read={schema=2,origin='orchplus',op='catalog',request_id='after-unsettled-effect',action_id='after-unsettled-effect',
   authority_namespace=request.authority_namespace,logical_session_id=request.logical_session_id,admission_seq=1,
   controller_pane=request.controller_pane,controller_generation=1,origin_binding=clone(request.origin_binding),
   request_serial=2,next_request_serial=3,settled_before=2,consumed=runtime.json.array()}
  table.insert(carrierInbox,1,message('effect-following-read','catalog',runtime.json.encode(read),2));relay.poll()
  local refused=false
  for _,frame in ipairs(carrierSent)do
   if frame.route=='spawn.source' and frame.binding=='delivery:lane' then
    local value=runtime.json.decode(frame.body)
    if value.kind=='held' and value.error=='callback_pending' and value.rejected_message
     and value.rejected_message.id=='effect-following-read' and value.rejected_message.incarnation=='delivery-orch' then refused=true end
   end
  end
  -- The intentionally failing ACK overwrites the transient relay.error. The
  -- exact published refusal, not that last IO error, proves the native fence.
  check(refused and lane.request_json==requestBytes and state.applies==1
   and P.equal(state.pending[state.callback.id],state.callback) and not D.relay_releasable(),
   'read-only continuation never bypasses an unacknowledged native result or consumes its durable effect fence')
  carrierAckBlocked=false
  for _=1,4 do relay.poll()end
  check(state.applies==1 and next(state.pending)==nil and lane.request_json==requestBytes,
   'only exact original native result settlement clears the fence; the rejected next read is never replayed')
 end
 do
  prepare();state.fail_settlement=true;table.insert(carrierInbox,clone(state.callback));relay.poll()
  check(carrierTrace.proofs[1]~=nil and state.pending[state.callback.id]~=nil and #carrierSent==0,
   'settlement persistence failure after ACK preserves its fence and publishes no response or source authorization')
  state.fail_settlement=false;carrierTrace.events={};reload();relay.poll()
  local probed,settled,received,cleaned=operationIndex('probe'),operationIndex('settlement'),operationIndex('receive'),operationIndex('cleanup')
  check(probed and settled and received and cleaned and probed<settled and settled<received and received<=cleaned,
   'reloaded host probes durable ACK and commits positive settlement before receive can clean its sole proof')
  check(next(state.pending)==nil and state.applies==1 and carrierTrace.data[1]==nil and carrierTrace.proofs[1]==nil,
   'recovery requires no volatile lane or processed record to settle and reclaim an acknowledged native frame')
 end
 for _,failure in ipairs({'probe','settlement','conflict','ack-conflict'})do
  reset()
  local delivery=message('recovery-'..failure,'spawn.result',callbackBytes({id='old-execution',incarnation='prior-spawn-boot'}),1,'prior-spawn-boot')
  state.pending[delivery.id]=clone(delivery);carrierTrace.data[1]=clone(delivery);carrierTrace.proofs[1]=clone(delivery)
  if failure=='probe' then carrierTrace.probe_error=true
  elseif failure=='settlement' then state.fail_settlement=true
  elseif failure=='ack-conflict' then carrierTrace.proofs[1].id='foreign-ack'
  else carrierTrace.data[1].body='conflicting producer bytes' end
  reload();relay.poll()
  check(carrierTrace.receives==0 and state.pending[delivery.id]~=nil and carrierTrace.proofs[1]~=nil,
   failure..' failure prevents receive cleanup and preserves both result fence and ACK evidence')
  check(failure=='settlement' or state.settlements==0,'unproved ACK never reaches the authority settlement API')
  carrierTrace.probe_error=nil;state.fail_settlement=false;carrierTrace.data[1]=clone(delivery);carrierTrace.proofs[1]=clone(delivery)
  relay.poll()
  check(next(state.pending)==nil and carrierTrace.proofs[1]==nil and carrierTrace.data[1]==nil,
   failure..' repair resumes positive settlement and slot cleanup without native execution')
 end
 do
  reset()
  local delivery=message('recovery-missing','spawn.result',callbackBytes({id='old-execution',incarnation='prior-spawn-boot'}),1,'prior-spawn-boot')
  state.pending[delivery.id]=clone(delivery);carrierTrace.data[1]=clone(delivery);carrierInbox={clone(delivery)}
  carrierAckBlocked=true;reload();relay.poll()
  check(carrierTrace.receives==1 and state.settlements==0 and state.retains==1 and #carrierInbox==1,
   'missing ACK is not a probe error: original input retries exact retention without clearing its fence')
  check(P.equal(state.pending[delivery.id],delivery) and #carrierSent==1,
   'missing ACK retry preserves exact result bytes and publishes no lane advisory before ACK succeeds')
  carrierAckBlocked=false
  for _=1,3 do relay.poll()end
  check(#carrierInbox==0 and next(state.pending)==nil and state.retains==1 and state.applies==0
   and carrierTrace.data[1]==nil and carrierTrace.proofs[1]==nil,
   'original unbound input eventually ACKs and reclaims its slot without inventing a native outcome or replaying retention')
 end
 do
  reset()
  for slot=1,24 do
   local delivery=message('batch-'..slot,'spawn.result',callbackBytes({id='old-execution-'..slot,incarnation='prior-spawn-boot'}),slot,'prior-spawn-boot')
   state.pending[delivery.id]=clone(delivery);carrierTrace.proofs[slot]=clone(delivery)
   if slot%2==0 then carrierTrace.data[slot]=clone(delivery)end
  end
  carrierTrace.probe_error=24;reload();relay.poll()
  check(carrierTrace.receives==0 and state.settlements==0 and #D.result_deliveries()==24,
   'an error on the last pending receipt cannot partially settle earlier positive proofs or allow any cleanup')
  carrierTrace.probe_error=nil;carrierTrace.events={};relay.poll()
  local probes,settlement=0,nil
  for _,event in ipairs(carrierTrace.events)do
   if event.operation=='probe' then probes+=1
   elseif event.operation=='settlement' then
    check(probes==24,'all pending ACK proofs are probed, not merely the four receive-turn slots')
    settlement=event.message
   elseif event.operation=='receive' then check(settlement~=nil,'full positive batch commits before any receive cleanup')end
  end
  check(probes==24 and state.settlements==1 and #settlement==24 and next(state.pending)==nil,
   'one bounded atomic authority batch settles all 24 pending exact receipts after reload')
  check(next(carrierTrace.data)==nil and next(carrierTrace.proofs)==nil and state.applies==0,
   'exact ACK proof works with absent or matching producer data and reclaims every transient slot without native effects')
 end
 for name,value in pairs(originals)do D[name]=value end
 modules.dispatch_relay=priorRelay;saved,paneList=priorSaved,priorPanes
 carrierInbox,carrierSent,carrierAcks={},{},{}
 carrierBlocked,carrierAckBlocked,carrierOrdinaryBlocked=false,false,false
 carrierTrace={events={},data={},proofs={},probe_error=nil,receives=0}
end
do
 local priorSaved,priorPanes,priorRelay=saved,paneList,modules.dispatch_relay
 local priorNow=rawget(fake,'now')
 local D=load('dispatch');local originals={}
 for _,name in ipairs({'current','execution','result_deliveries','admin_source_readonly','admin_apply','admin_bootstrap'})do originals[name]=D[name]end
 local selection={logical_session_ids=runtime.json.array(),mailbox_handles=runtime.json.array()}
 local origin={host_pane_id='80',window_key='migration-window',window_epoch='migration-desktop',native_session_id='1',window_host_id='42'}
 local source={schema=1,relay_endpoint='migration',relay_boot='migration-orch',lane_id='lane',host_pane_id='80',
  source_nonce='migration-source',origin=origin,desktop_proof='delegated_native_window',host_program='orchplus.orchestrator'}
 local creation={request_id='actual-create',orch_session_id='created-session',owner_id='created-controller',generation=1,
  authority_namespace='orch-migration',source_nonce=source.source_nonce}
 local peerProof={source_schema=3,source_revision=20,source_sha256=string.rep('c',64),candidate_namespace='orch-migration',
  protocol=1,state='ready',phase='prepared',managed_sha256=string.rep('b',64),pending_immutable=0,blockers=0}
 local peer={protocol=2,phase='legacy',source_nonce=source.source_nonce,host_pane_id=source.host_pane_id,authority_namespace='orch-migration',
  authority_revision=20,source_sha256=peerProof.source_sha256,qualification={proof=peerProof,selection=selection}}
 local own,phase,relay,lane,sequence,sourceCalls,applyCalls,mutations,mode,candidate,bootstrapCalls,absentSource
 local function qualification()return {proof=clone(own),selection=selection}end
 local function current()
  if mode=='missing' or absentSource then return nil end
  return {protocol=own.protocol,phase=phase,spawn_namespace=own.candidate_namespace,authority_revision=own.source_revision,
   authority_namespace=if own.protocol==2 then 'orch-migration' else nil,qualification=qualification()}
 end
 local function enqueue(act,body,target)
  sequence+=1
  local message={peer='orchplus',recipient='spawn',route='spawn.request',incarnation='migration-orch',id='migration-'..sequence,
   binding='migration:lane:'..act..(if target then ':'..target else ''),body=body}
  table.insert(carrierInbox,message);return message
 end
 local function reset()
  fake.now=priorNow
  saved={};paneList={{pane=80,program='orchplus.orchestrator'}}
  carrierInbox,carrierSent,carrierAcks={},{},{}
  carrierBlocked,carrierAckBlocked,carrierOrdinaryBlocked=false,false,false
  carrierTrace={events={},data={},proofs={},probe_error=nil,receives=0}
  own={source_schema=1,source_revision=10,source_sha256=string.rep('a',64),source_namespace='spawn-migration',candidate_namespace='spawn-migration',
   protocol=1,state='ready',phase='prepared',managed_sha256=string.rep('b',64),pending_immutable=0,blockers=0}
  phase='legacy';sequence=0;sourceCalls=0;applyCalls=0;mutations=0;mode=nil;candidate=nil
  bootstrapCalls=0;absentSource=false
  D.current=current;D.execution=function()return nil end;D.result_deliveries=function()return {}end
  D.admin_source_readonly=function()
   sourceCalls+=1
   if mode=='missing' or mode=='bootstrap_uncertain' then return nil,'Existing managed source is unavailable; retain the original intent','source_unavailable' end
   if absentSource then return nil,'No managed source or initialization marker exists','source_absent' end
   return qualification()
  end
  D.admin_bootstrap=function(observed,onTransition)
   bootstrapCalls+=1
   check(P.equal(observed,creation),'bootstrap sole writer receives the exact native Create identity')
   if not absentSource then return nil,'Existing source cannot be initialized again','refused','bootstrap_refused' end
   if mode=='bootstrap_throw' then error('Injected bootstrap exception before candidate observation')end
   mutations+=1;candidate=clone(own);candidate.source_schema=2;candidate.source_revision=1;candidate.source_sha256=string.rep('f',64)
   onTransition(candidate)
   if mode=='bootstrap_uncertain' then return nil,'Injected ambiguous initialization','uncertain','bootstrap_uncertain' end
   own=clone(candidate);absentSource=false;phase='legacy';return qualification()
  end
  D.admin_apply=function(operation,expected,observed,onTransition)
   applyCalls+=1
   check(P.equal(observed,peer.qualification),'host passes only genuine captured peer qualification to the sole writer')
   if not P.equal(expected,own) then return nil,'Captured source changed','refused' end
   if operation=='inspect' then
    local value=qualification();value.compatibility={schema=1,kind='migration',orch=clone(peerProof),spawn=clone(own)};return value
   end
   mutations+=1;candidate=clone(own);candidate.source_revision+=1
   candidate.source_sha256=string.rep(if operation=='prepare' then 'd' else 'e',64)
   candidate.source_schema=2;candidate.protocol=2;candidate.phase='stable'
   onTransition(candidate)
   if mode=='uncertain' then return nil,'Injected ambiguous write','uncertain' end
   own=clone(candidate);phase=if operation=='prepare' then 'prepared' else 'stable'
   return qualification()
  end
  modules.dispatch_relay=nil;relay=load('dispatch_relay').install()
  enqueue('bind',runtime.json.encode(source));relay.poll();lane=assert(relay.lanes['migration:lane'])
 end
 local function stage(operation,changed)
  local request={schema=2,origin='orchplus',op='catalog',request_id='migration-request-'..tostring(sequence+1),
   action_id='migration-action-'..tostring(sequence+1),setup_origin=origin}
  local value={schema=1,request_json=runtime.json.encode(request),operation=operation}
  if operation=='bootstrap' then value.creation=clone(creation)
  elseif operation~='source' then value.expected=clone(own);value.peer=P.clone(peer)end
  if changed then changed(value)end
  enqueue('migration',runtime.json.encode(value),relay.boot);relay.poll()
  return value
 end
 local function callback(changed)
  local pending=assert(lane.migration)
  local value={request_json=pending.request_json,nonce=pending.nonce,executor_id='migration-window',
   relay_execution=clone(lane.execution_receipt),peer=if pending.peer then P.clone(pending.peer) else nil,
   creation=if pending.creation then clone(pending.creation) else nil}
  if changed then changed(value)end
  local bytes=runtime.json.encode(value)
  enqueue('spawn.migration',bytes,relay.boot);relay.poll();return bytes
 end
 local function observed(operation)
  local result=assert(lane.migration_response)
  check(result.operation==operation and result.response.ok==true and P.equal(result.source.qualification,result.response.value.compatibility
   and {proof=result.response.value.proof,selection=result.response.value.selection} or result.response.value),
   'phase response is correlated to its actual source qualification: '..operation)
  return result
 end
 reset()
 stage('source')
 check(sourceCalls==0 and applyCalls==0 and lane.migration~=nil,'staging source observation does not read, initialize or mutate authority before native witness')
 callback(function(value)value.nonce='wrong-nonce'end)
 check(sourceCalls==0 and lane.migration~=nil,'wrong nonce cannot borrow the live source challenge')
 callback();observed('source')
 check(sourceCalls==1 and mutations==0 and lane.migration_response.source.phase=='legacy','fresh source captures actual legacy phase without preparing it')
 stage('inspect')
 callback(function(value)value.peer.source_nonce='different-source'end)
 check(applyCalls==0,'changed genuine ORCH source incarnation cannot reach the phase reducer')
 callback();observed('inspect')
 stage('prepare')
 carrierBlocked=true
 local preparedCallback=callback()
 check(mutations==1 and #carrierInbox==1 and lane.migration==nil and lane.migration_response.response.ok,
  'prepared outcome is retained before blocked publication and callback input remains unacknowledged')
 relay.poll()
 check(mutations==1 and #carrierInbox==1,'delivery retry never reapplies a committed migration phase')
 carrierBlocked=false;relay.poll()
 check(#carrierInbox==0 and observed('prepare').source.phase=='prepared','exact actual prepared result drains before callback ACK')
 local currentIndex,consumeIndex,ackIndex
 for index,event in ipairs(carrierTrace.events)do
  if event.operation=='send' and event.message.route=='spawn.current' and event.message.body~='' then
   local value=runtime.json.decode(event.message.body)
   if value.migration_response and value.migration_response.operation=='prepare' then currentIndex=index end
  elseif event.operation=='send' and event.message.route=='spawn.source' then
   local value=runtime.json.decode(event.message.body)
   if value.consumed_execution then consumeIndex=index end
  elseif event.operation=='ack' and event.message.body==preparedCallback then ackIndex=index end
 end
 check(currentIndex and consumeIndex and ackIndex and currentIndex<consumeIndex and consumeIndex<ackIndex,
  'migration current outcome is durably published before consumed execution and input ACK')
 enqueue('spawn.migration',preparedCallback,relay.boot);relay.poll()
 check(mutations==1,'delayed exact completed callback cannot repeat a mutation')
 stage('finish');callback()
 check(observed('finish').source.phase=='stable' and mutations==2,'both real mutation phases are reported from their actual resulting source')
 local retainedResult=clone(lane.migration_response);relay.poll()
 check(P.equal(retainedResult,lane.migration_response),'ordinary current polling and carrier cleanup retain the exact administrative outcome until the next phase')
 stage('inspect',function(value)value.expected.source_revision+=1 end)
 check(lane.migration==nil and not lane.migration_response.response.ok and applyCalls==3,
  'changed expected source is refused before issuing a native mutation challenge')
 do
  reset();stage('source');carrierAckBlocked=true
  local sourceCallback=callback()
  check(observed('source').response.ok and #carrierInbox==1,'positive source publication does not fabricate callback ACK success')
  stage('inspect')
  check(lane.migration==nil and applyCalls==0 and sourceCalls==1 and #carrierInbox==2
   and relay.error.code~='callback_pending','next immutable phase waits without nonce, mutation, ACK or terminal ordering refusal')
  carrierTrace.events={};carrierAckBlocked=false;relay.poll()
  local settled,received
  for index,event in ipairs(carrierTrace.events)do
   if event.operation=='ack' and event.message.body==sourceCallback then settled=index
   elseif event.operation=='receive' then received=index end
  end
  check(settled and received and settled<received and lane.migration.operation=='inspect' and sourceCalls==1 and applyCalls==0,
   'known admin settlement drains before fresh inbox stages even when its earlier ACK failed')
  callback();check(observed('inspect').response.ok and applyCalls==1,'queued original phase obtains one challenge and executes once after settlement')
 end
 reset();stage('source');callback();stage('inspect');callback();stage('prepare')
 local expiredAt=lane.migration.deadline+0.5;fake.now=function()return expiredAt end
 callback()
 check(mutations==0 and lane.migration_response.response.disposition=='refused','expired native challenge refuses before the sole writer')
 reset();stage('source');callback();stage('inspect');callback();stage('prepare')
 mode='uncertain';local uncertainCallback=callback()
 check(mutations==1 and lane.migration_uncertain~=nil and lane.migration_response.response.disposition=='uncertain',
  'ambiguous phase retains its exact candidate proof and original uncertainty')
 enqueue('spawn.migration',uncertainCallback,relay.boot);relay.poll()
 check(mutations==1,'uncertain callback replay cannot invoke the sole writer twice')
 stage('source');callback()
 check(lane.migration_uncertain~=nil and lane.migration_response.response.disposition=='uncertain',
  'fresh read of a different source cannot falsely settle an ambiguous candidate')
 mode=nil;own=clone(candidate);phase='prepared'
 stage('source');callback()
 check(observed('source').source.phase=='prepared' and lane.migration_uncertain==nil and mutations==1,
  'only exact actual candidate readback clears uncertainty without another mutation')
 reset();mode='missing';stage('source');callback()
 check(not lane.migration_response.response.ok and lane.migration_response.source==nil and mutations==0,
  'absent source is actionable refusal, not an invented initialized authority')
 do
  reset();absentSource=true;stage('bootstrap')
  check(bootstrapCalls==0 and lane.migration==nil and lane.migration_response.response.code=='bootstrap_refused',
   'Create bootstrap cannot skip its actual same-lane absent-source observation')
  reset();mode='missing';stage('source');callback();stage('bootstrap')
  check(bootstrapCalls==0 and lane.migration==nil and lane.migration_response.response.code=='bootstrap_refused',
   'unavailable or marked-lost source never authorizes bootstrap')
  reset();absentSource=true;stage('source');callback()
  check(lane.migration_response.response.code=='source_absent' and sourceCalls==1 and mutations==0,
   'only the native-observed sole-writer absence result advertises first-use eligibility')
  stage('bootstrap',function(value)value.creation.source_nonce='another-incarnation'end)
  check(bootstrapCalls==0 and lane.migration==nil,'bootstrap stage refuses another ORCH source incarnation')
  stage('bootstrap')
  check(bootstrapCalls==0 and lane.migration.operation=='bootstrap' and P.equal(lane.migration.creation,creation),
   'bootstrap stages the exact Create identity without initializing before native witness')
  callback(function(value)value.creation.owner_id='another-controller'end)
  check(bootstrapCalls==0 and lane.migration~=nil,'changed native Create owner cannot borrow a fresh bootstrap challenge')
  carrierBlocked=true;local bootstrapCallback=callback()
  check(bootstrapCalls==1 and mutations==1 and lane.migration==nil and #carrierInbox==1,
   'bootstrap commits once and retains its result against publication backpressure')
  relay.poll();check(bootstrapCalls==1 and #carrierInbox==1,'retrying blocked bootstrap publication never retries initialization')
  carrierBlocked=false;relay.poll()
  check(observed('bootstrap').source.phase=='legacy' and #carrierInbox==0 and lane.migration_uncertain==nil,
   'bootstrap publishes the actual unpaired source before callback settlement')
  enqueue('spawn.migration',bootstrapCallback,relay.boot);relay.poll()
  check(bootstrapCalls==1 and mutations==1,'duplicate exact bootstrap callback cannot initialize twice')
  stage('inspect');callback();stage('prepare');callback();stage('finish');callback()
  check(observed('finish').source.phase=='stable' and mutations==3 and bootstrapCalls==1,
   'first use completes real inspect, prepare and finish after one consent-bound initialization')
  stage('source');callback();stage('bootstrap')
  check(lane.migration==nil and bootstrapCalls==1 and lane.migration_response.response.code=='bootstrap_refused',
   'an existing initialized source never becomes first-use eligible through another source read')
 end
 do
  reset();absentSource=true;stage('source');callback();stage('bootstrap');mode='bootstrap_uncertain'
  local uncertainBootstrap=callback()
  check(lane.migration_response.response.code=='bootstrap_uncertain' and lane.migration_uncertain~=nil and bootstrapCalls==1,
   'ambiguous bootstrap preserves its candidate proof and explicit uncertain result')
  enqueue('spawn.migration',uncertainBootstrap,relay.boot);relay.poll()
  stage('source');callback()
  check(lane.migration_response.response.code=='source_unavailable' and lane.migration_response.response.disposition=='uncertain',
   'partial initialization remains unavailable rather than looking like pristine absence')
  stage('bootstrap')
  check(bootstrapCalls==1 and lane.migration==nil and lane.migration_response.response.code=='bootstrap_uncertain',
   'unsettled bootstrap never issues a fresh initialization challenge')
  mode=nil;absentSource=false;own=clone(candidate)
  stage('source');callback()
  check(observed('source').response.ok and lane.migration_uncertain==nil and bootstrapCalls==1,
   'exact resulting bootstrap candidate reconciles without replaying initialization')
  reset();absentSource=true;stage('source');callback();stage('bootstrap');mode='bootstrap_throw';callback()
  check(lane.migration_response.response.code=='bootstrap_uncertain' and lane.migration_uncertain~=nil,
   'bootstrap adapter exception retains uncertainty even without a candidate proof')
  stage('source');callback()
  check(lane.migration_response.response.code=='source_unavailable' and lane.migration_response.response.disposition=='uncertain',
   'apparent source absence cannot turn an earlier uncertain initialization into automatic replay eligibility')
  stage('bootstrap');check(bootstrapCalls==1 and lane.migration==nil,'uncertain exception fences repeated initialization')
 end
 reset();stage('source')
 local expiredBody={request_json=lane.migration.request_json,nonce=lane.migration.nonce,executor_id='old-migration-window',
  relay_execution=clone(lane.execution_receipt)}
 local oldBoot=relay.boot
 modules.dispatch_relay=nil;relay=load('dispatch_relay').install()
 enqueue('spawn.migration',runtime.json.encode(expiredBody),oldBoot);relay.poll()
 check(sourceCalls==0 and mutations==0,'host reload never turns old callback bytes into fresh source or mutation consent')
 for name,value in pairs(originals)do D[name]=value end
 fake.now=priorNow
 modules.dispatch_relay=priorRelay;saved,paneList=priorSaved,priorPanes
 carrierInbox,carrierSent,carrierAcks={},{},{}
 carrierBlocked,carrierAckBlocked,carrierOrdinaryBlocked=false,false,false
 carrierTrace={events={},data={},proofs={},probe_error=nil,receives=0}
end
return 'PASS host_editor '..tostring(checks)
