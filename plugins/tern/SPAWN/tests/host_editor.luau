-- Native host UI callbacks with real configuration/authority modules; only KV,
-- membership IO and rendering boundaries are injected. No native effects.
local root=...
assert(type(root)=='string','pass the package directory')
local runtime,environment=tern,getfenv()
local modules,definitions,saved={},{},{}
local checks,writes=0,0
local deferred,holdInspection=nil,false
local hooks,timers={},{}
local paneList={}
local function check(value,message) assert(value,message);checks+=1 end
local function clone(value)
 if type(value)~='table' then return value end
 local out={};for key,item in pairs(value) do out[key]=clone(item) end;return out
end
local inventory={clients={{kind='window',window='fixture-window'}},sessions={{id=1,tabs={{blocks={{id=7}}}}}}}
local fake=setmetatable({
 now=function()return 1700000000 end,
 kv={get=function(key)return clone(saved[key]) end,set=function(key,value)writes+=1;saved[key]=clone(value) end},
 json=runtime.json,
 on=function(name,callback)
  hooks[name]=hooks[name] or {};table.insert(hooks[name],callback)
 end,
 timer=function(ms,callback)table.insert(timers,{ms=ms,callback=callback});return {} end,
 pane={write=function()error('Editor attempted provider input') end,list=function()return clone(paneList) end},
 block={define=function(name,definition)definitions[name]=definition end},
 ui={node=function(kind,props)return {k=kind,p=props} end,col=function(children)return {children=children} end,text=function(value)return {text=value} end},
 process={run=function()error('Editor attempted a real subprocess') end},
},{__index=runtime})
modules.native_cli={inspect=function(_window,_options,callback)
 if holdInspection then deferred=callback;return end
 callback({status=0,timed_out=false,stdout=runtime.json.encode(inventory)},nil)
end,epoch=function()return 'fixture-epoch' end}
local function load(name)
 name=name:gsub('^%./','')
 if modules[name]~=nil then return modules[name] end
 local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
 setfenv(chunk,setmetatable({require=load,tern=fake},{__index=environment}))
 modules[name]=chunk() or true;return modules[name]
end
load('host')
-- The host sweep timer is the last one host load arms; it needs no Config block.
local sweepTimer=timers[#timers]
check(sweepTimer~=nil and sweepTimer.ms==1,'host load arms the first settlement sweep at once')
local A,P,C=load('authority'),load('bridge_protocol'),load('config')
local definition=assert(definitions.spawner)
local cx={pane=7,save=function()end,render=function()end,action=function()error('Editor launched a window action') end}
local state=definition.init(cx,{runtime.json.encode({host={name='fixture'},native_window='fixture-window'})},nil)
check(state.binding~=nil and state.snapshot~=nil,'host opens through original native membership boundary')
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
local function record(id)
 return {id=id,provider='custom',account_label=id,backend='local-terminal',command='ordinary-cli',arguments={},enabled=true,include_all=true,placement='tab'}
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
local rendered=definition.view(state,cx)
local foundEditor=false
for _,section in ipairs(rendered.main.children[1].p.sections) do
 for _,item in ipairs(section.rows) do
  if item.id==row() then foundEditor=item.control.k=='text' and item.control.value=='' end
 end
end
check(foundEditor,'Config exposes a full-record JSON row without embedding the entire record in every rendered field')
check(rendered.main.children[2].text:sub(1,15)=='SPAWN_STATE_V2 ','native snapshot surface keeps released v2 transport')
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
edited=activate()
edited.mailbox.verified=true;edited.mailbox.evidence_ref='fixture-only-reviewed-duplex-evidence'
edited.fresh_arguments={'--fresh','--task','--literal-profile'};edited.task_argument_index=3
edited.model='model-new';edited.profile='profile-new';edited.selector_evidence='fixture-only-selector-evidence'
state.editing.draft=runtime.json.encode(edited)
check(definition.key(state,{name='enter'},cx),'full-record JSON saves through existing keyboard commit')
local changed=snapshot()
check(changed.config_revision==baseline.config_revision+1,'full-record save uses one canonical revision increment')
check(changed.records[1].review_required==true and type(changed.records[1].review_reason)=='string','changed JSON always enters the existing settings review gate')
check(changed.records[1].mailbox.verified and changed.records[1].mailbox.evidence_ref==edited.mailbox.evidence_ref,'operator-edited mailbox attestation and evidence are preserved exactly')
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
check(approved.records[1].mailbox.evidence_ref==edited.mailbox.evidence_ref and P.equal(approved.records[2],baseline.records[2]),'approval preserves edited evidence and other records')
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
check(hooks.spawn~=nil and #hooks.spawn==1 and #timers>=1,'real host executor installs only deferred hooks while editor tests execute no native effects')
local function prefs()return definition.view(state,cx).main.children[1].p end
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
-- Pages: Setup, Configured agents, Spawn agents, Running agents; saved and discovered restore accept spawn.
local pageIds,pageLabels={},{}
for _,page in ipairs(prefs().pages) do table.insert(pageIds,page.id);pageLabels[page.id]=page.label end
check(P.equal(pageIds,{'setup','agents','spawn','runtime'}) and pageLabels.spawn=='Spawn agents','Config pages are setup, agents, spawn, runtime with a Spawn agents page')
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
-- Spawn agents rows: Spawn all, then one row per saved record in Config order.
local roster=clone(snapshot().records)
local argsy=record('argsy');argsy.provider='kimi';argsy.account_label='Work';argsy.arguments={'--model','x y'};argsy.cwd='/srv'
local off=record('off');off.enabled=false
local needs=record('needs');needs.review_required=true;needs.review_reason='Review the new command'
table.insert(roster,argsy);table.insert(roster,off);table.insert(roster,needs)
check(A.edit(state.binding,snapshot().config_revision,'replace-records',{records=roster}),'seed launchable, disabled and needs-review records')
refresh()
local rev=state.snapshot.config_revision
local spawnRows,spawnOrder=rows_of('spawn')
check(spawnOrder[1].id=='spawn-launch-all' and spawnOrder[1].control.act=='launch-all@'..rev and spawnOrder[1].disabled==nil,'Spawn agents starts with one Spawn all button')
check(spawnOrder[1].hint:find('^4 enabled records are included in Spawn all'),'Spawn all detail counts enabled included records')
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
-- Launch intents: every click queues a fresh intent (oldest first); an ack removes only its own.
local function intents()
 local node=definition.view(state,cx).main.children[3]
 if node==nil then return nil end
 check(node.p.key=='spawn-launch-intent' and node.p.role=='spawn.launch.intent','intents ride the keyed spawn.launch.intent node')
 local value=runtime.json.decode(node.text)
 check(value.schema==1 and type(value.intents)=='table' and #value.intents>0,'the node carries a non-empty schema-1 intents list')
 return value.intents
end
local function ack(id)definition.event(state,{ev='action',id='main',act='spawn.launch-intent-ack',value=id},cx) end
check(intents()==nil,'no intent node while nothing is pending')
before=clone(saved)
definition.event(state,{ev='action',act='launch-all@'..rev},cx)
definition.event(state,{ev='action',act='launch:argsy@'..rev},cx)
definition.event(state,{ev='action',act='launch:argsy@'..rev},cx)
local queued=intents()
check(#queued==3,'three rapid clicks queue three intents')
check(queued[1].kind=='all' and queued[1].record_id==nil and queued[1].config_revision==rev,'the oldest intent is the Spawn all click at the current revision')
check(queued[2].kind=='record' and queued[2].record_id=='argsy' and queued[3].kind=='record' and queued[3].record_id=='argsy','repeat clicks of one record each queue their own intent')
check(queued[1].intent_id~=queued[2].intent_id and queued[2].intent_id~=queued[3].intent_id and queued[1].intent_id~=queued[3].intent_id,'every click gets a fresh intent id')
check(P.equal(before,saved),'launch clicks write no durable state and admit nothing on the host')
ack('not-a-pending-intent')
check(P.equal(intents(),queued),'a mismatched ack removes nothing')
ack(queued[2].intent_id)
local left=intents()
check(#left==2 and left[1].intent_id==queued[1].intent_id and left[2].intent_id==queued[3].intent_id,'an ack removes only its own intent and keeps the order')
ack(queued[2].intent_id)
check(#intents()==2,'a repeated ack removes nothing more')
ack(queued[1].intent_id);ack(queued[3].intent_id)
check(intents()==nil,'acking every intent removes the node')
for _=1,16 do definition.event(state,{ev='action',act='launch-all@'..rev},cx) end
local full=intents()
check(#full==16,'the queue holds 16 intents')
definition.event(state,{ev='action',act='launch-all@'..rev},cx)
check(#intents()==16 and state.notice=='Too many launches queued; wait a moment','a 17th click is refused')
check(rows_of('spawn')['spawn-queue-full']~=nil,'the refusal is shown as a notice row on Spawn agents')
for _,pending in ipairs(full) do ack(pending.intent_id) end
check(intents()==nil and rows_of('spawn')['spawn-queue-full']==nil,'draining the queue clears the node and the notice row')
definition.event(state,{ev='action',act='launch-all@'..(rev-1)},cx)
check(intents()==nil and state.notice:find('stale%-config'),'a stale click queues no intent')
-- Setup page: Guided setup goes through the intent; Review setup result only while a setup run is active.
local setupRows=rows_of('setup')
check(setupRows['setup-flow'].control.act=='launch-setup@'..rev and setupRows['setup-result']==nil,'Guided setup row uses the intent; no Review setup result without an active run')
definition.event(state,{ev='action',act='launch-setup@'..rev},cx)
check(intents()[1].kind=='setup','Guided setup click queues a setup intent instead of calling a window action')
table.insert(state.snapshot.attempts,{id='attempt-setup',record_id='editable',purpose='setup',phase='Running',mode='Native OMP',observer_id='fixture',scope='fixture',unresolved=true})
setupRows=rows_of('setup')
check(setupRows['setup-result']~=nil and setupRows['setup-result'].control.act=='launch-result@'..rev,'Review setup result appears while a setup run is active')
definition.event(state,{ev='action',act='launch-result@'..rev},cx)
local setupQueue=intents()
check(#setupQueue==2 and setupQueue[2].kind=='result','Review setup result click queues a result intent after the setup intent')
refresh()
return 'PASS host_editor '..tostring(checks)
