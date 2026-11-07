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
local inventory={clients={{kind='window',window='fixture-window',conn=1,since=1700000000000}},sessions={{id=1,tabs={{blocks={{id=7}}}}}}}
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
local beforeNavigation=clone(saved)
local publicPage={kind='page',page='managed',native_window='fixture-window'}
local inertPage=definition.init(cx,{runtime.json.encode(publicPage)},nil)
check(inertPage.binding==nil and inertPage.client_config==nil and inertPage.page=='managed' and P.equal(saved,beforeNavigation),'public page-only arguments remain inert until SPAWN supplies its own context')
local pageNode=definition.view(inertPage,cx).main.children[3]
check(pageNode.p.key=='spawn-page-context' and pageNode.p.role=='spawn.page.context' and P.equal(runtime.json.decode(pageNode.text).entry,publicPage),'inert page requests only a view-local owner context')
local invalidPublic=clone(publicPage);invalidPublic.client_config={schema=1,agents={}}
local invalidPage=definition.init(cx,{runtime.json.encode(invalidPublic)},nil)
check(invalidPage.binding==nil and invalidPage.page_context_request==nil and P.equal(saved,beforeNavigation),'foreign page arguments cannot carry or import legacy client configuration')
local inertSaved=definition.save(inertPage)
check(inertSaved.page_context_request==nil and inertSaved.client_config==nil and inertSaved.page_entry==nil,'owner context handoff is never a durable protocol or second settings store')
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
-- Managed setup is prominent without removing ordinary Setup/Spawn/Running pages.
local pageIds,pageLabels={},{}
for _,page in ipairs(prefs().pages) do table.insert(pageIds,page.id);pageLabels[page.id]=page.label end
check(P.equal(pageIds,{'managed','setup','agents','spawn','runtime'}) and pageLabels.spawn=='Spawn agents','Config exposes standalone managed setup alongside every ordinary page')
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
-- Native setup drafts/probes are not a second settings store. These injected
-- observations exercise UI fencing only; real platform probes belong to smoke.
for _,pending in ipairs(intents() or {}) do ack(pending.intent_id) end
definition.event(state,{ev='change',item='managed-existing',value=''},cx)
local managedRows=rows_of('managed')
check(managedRows['managed-begin']~=nil and managedRows['managed-probe']~=nil and managedRows['managed-attest']==nil,'cold native setup offers creation/probe, never an unearned attestation')
before=clone(saved)
definition.event(state,{ev='change',item='managed:cwd',value='/fixture/repository'},cx)
definition.event(state,{ev='change',item='managed:executable',value='/fixture/worker'},cx)
check(P.equal(before,saved) and state.managed_draft.cwd=='/fixture/repository','native typed fields are disposable drafts, not authority writes')
for _,op in ipairs({'managed-probe','managed-attest','managed-adopt','managed-route-probe'}) do
 definition.event(state,{ev='action',act=op..'@'..state.snapshot.config_revision},cx)
 local refusal=rows_of('managed')['managed-notice']
 check(P.equal(before,saved) and refusal and not state.managed_busy and state.managed_route==nil,'managed prerequisite refusal is visible on its owner page and changes no authority or native obligation: '..op)
end
definition.event(state,{ev='action',act='managed-begin@'..state.snapshot.config_revision},cx)
check(snapshot().setup.state=='in_progress','native begin uses the canonical setup authority writer')
local managedModule=modules.managed_setup
local originalPrepare=managedModule.prepare
local pendingProbe=nil
managedModule.prepare=function(draft,context,callback)
 check(draft.cwd=='/fixture/repository' and context.host_os~=nil,'native probe receives selected draft and actual host context')
 pendingProbe=callback
end
local probeRevision=state.snapshot.config_revision
definition.event(state,{ev='action',act='managed-probe@'..probeRevision},cx)
check(state.managed_busy and pendingProbe~=nil,'probe waits for actual asynchronous observations')
definition.event(state,{ev='action',act='managed-probe@'..probeRevision},cx)
check(state.managed_busy,'a second click cannot duplicate an in-flight probe')
local concurrentRoster=clone(snapshot().records);concurrentRoster[1].account_label='manual-edit-during-probe'
check(A.edit(state.binding,probeRevision,'replace-records',{records=concurrentRoster}),'manual authority writer advances the same config revision')
before=clone(saved)
pendingProbe(nil,{passed=true,observations={}},nil)
check(not state.managed_busy and state.managed_probe==nil and P.equal(before,saved),'concurrent manual edit invalidates probe results without overwriting records')
definition.event(state,{ev='action',act='managed-probe@'..state.snapshot.config_revision},cx)
check(not state.managed_busy and state.notice:find('stale%-config'),'refreshing the form cannot rebase an old draft onto manual changes')
definition.event(state,{ev='change',item='managed-existing',value='editable'},cx)
check(state.managed_draft.account_label=='manual-edit-during-probe' and state.managed_draft_revision==state.snapshot.config_revision,'explicit selection adopts current saved values and revision')
managedModule.prepare=function(_,_,callback)callback(nil,nil,'Fixture resource permission denied')end
before=clone(saved)
definition.event(state,{ev='action',act='managed-probe@'..state.snapshot.config_revision},cx)
check(P.equal(before,saved) and state.managed_probe==nil and not state.managed_busy and rows_of('managed')['managed-notice'],'actual resource failure reaches native Managed setup preferences without creating an attested record')
managedModule.prepare=originalPrepare
-- Actual native boundary proof is asynchronous; only Authority retains its cleanup obligation.
state.managed_record=clone(snapshot().records[1])
state.managed_probe={schema=1,passed=true,record_sha256=string.rep('a',64),observations={},provision_handle='setup-fixture-native'}
state.managed_probe_revision=state.snapshot.config_revision
local nativeRevision=state.snapshot.config_revision
definition.event(state,{ev='action',act='managed-route-probe@'..nativeRevision},cx)
local nativeRoute=state.managed_route
check(nativeRoute and saved.authority.setup_probe and saved.authority.setup_probe.nonce==nativeRoute.nonce,'native launch consent persists one exact cleanup obligation before window effects')
check(snapshot().config_revision==nativeRevision and intents()[1].kind=='route_probe' and intents()[1].native_window=='fixture-window','native runtime obligation addresses only its owner window without bumping settings revision or launching through host process.run')
local routeIntent=intents()[1].intent_id
local function routeEvent(act,extra)
 local value={nonce=nativeRoute.nonce,window='fixture-window',pane=9}
 for key,item in pairs(extra or {}) do value[key]=item end
 definition.event(state,{ev='action',act=act,value=runtime.json.encode(value)},cx)
end
routeEvent('managed-route-preflight',{pane=0})
check(nativeRoute.launch_ready and nativeRoute.launch_ready.native_conn==1 and nativeRoute.launch_ready.native_since==1700000000000,'fresh read-only preflight captures the exact current native client incarnation')
table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd})
local originalObserve=managedModule.observe_route
local pendingNative
managedModule.observe_route=function(route,session,pane,callback)
 check(route.nonce==nativeRoute.nonce and session==1 and pane==9,'actual observer is fenced to original native scope')
 pendingNative=callback
end
routeEvent('managed-route-started')
check(saved.authority.setup_probe.pane==9 and nativeRoute.owned_pane==9,'exact native command/cwd/client membership binds the owned diagnostic')
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
routeEvent('managed-route-finished',{cleaned=true,error='Configuration changed'})
check(saved.authority.setup_probe==nil and nativeRoute.status=='failed' and snapshot().setup.state=='in_progress','independent native absence clears only the obligation, never fabricates setup completion')
managedModule.observe_route=originalObserve
ack(routeIntent)
definition.event(state,{ev='change',item='managed-existing',value='editable'},cx)
local function nextNativeFixture(handle)
 definition.event(state,{ev='change',item='managed-existing',value='editable'},cx)
 state.managed_record=clone(snapshot().records[1])
 state.managed_probe={schema=1,passed=true,record_sha256=string.rep('a',64),observations={},provision_handle=handle}
 state.managed_probe_revision=state.snapshot.config_revision
 definition.event(state,{ev='action',act='managed-route-probe@'..state.snapshot.config_revision},cx)
 nativeRoute=state.managed_route
 return intents()[1].intent_id
end
local unboundIntent=nextNativeFixture('setup-fixture-unbound')
inventory.clients[1].conn=2
routeEvent('managed-route-preflight',{pane=0})
check(nativeRoute.cleanup_blocked and nativeRoute.launch_ready==nil and saved.authority.setup_probe~=nil,'changed native incarnation refuses preflight before authorizing an effect')
inventory.clients[1].conn=1
routeEvent('managed-route-finished',{pane=0,cleaned=true,error='No pane currently visible'})
check(saved.authority.setup_probe~=nil and saved.authority.setup_probe.pane==nil and not nativeRoute.discovery_complete,'zero inventory cannot settle an unbound uncertain native start')
table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd})
routeEvent('managed-route-started')
check(saved.authority.setup_probe.pane==9,'late positively discovered native command is bound even for cleanup-only recovery')
table.remove(inventory.sessions[1].tabs[1].blocks)
routeEvent('managed-route-finished',{cleaned=true,error='Uncertain owned actor settled'})
check(saved.authority.setup_probe==nil,'positive binding followed by native absence can settle the formerly uncertain obligation')
ack(unboundIntent)
for _,identity in ipairs({'wrong-command','wrong-cwd','absent'}) do
 local falseIntent=nextNativeFixture('setup-fixture-'..identity)
 routeEvent('managed-route-preflight',{pane=0})
 if identity~='absent' then
  table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=if identity=='wrong-command' then 'unrelated-live-command' else nativeRoute.command,cwd=if identity=='wrong-cwd' then '/foreign-cwd' else nativeRoute.cwd})
 end
 before=clone(saved)
 managedModule.observe_route=function()error('Unverified diagnostic must not read output')end
 routeEvent('managed-route-started')
 check(P.equal(before,saved) and saved.authority.setup_probe.pane==nil and nativeRoute.pane==nil and nativeRoute.owned_pane==nil and not nativeRoute.observing,'unverified started event cannot persist or cache native ownership or read output: '..identity)
 if identity~='absent' then table.remove(inventory.sessions[1].tabs[1].blocks) end
 routeEvent('managed-route-finished',{cleaned=true})
 check(P.equal(before,saved) and saved.authority.setup_probe.pane==nil and not nativeRoute.discovery_complete,'later empty inventory cannot settle a rejected native identity: '..identity)
 table.insert(inventory.sessions[1].tabs[1].blocks,{id=9,command=nativeRoute.command,cwd=nativeRoute.cwd})
 refresh()
 check(saved.authority.setup_probe.pane==9 and nativeRoute.owned_pane==9,'owner reload can still positively bind the exact late diagnostic for cleanup: '..identity)
 table.remove(inventory.sessions[1].tabs[1].blocks)
 routeEvent('managed-route-finished',{cleaned=true,error='Rejected start later positively recovered'})
 check(saved.authority.setup_probe==nil and nativeRoute.status=='failed','positive recovery and native absence clear cleanup without blessing rejected output: '..identity)
 managedModule.observe_route=originalObserve
 ack(falseIntent)
end
local deadlineIntent=nextNativeFixture('setup-fixture-deadline')
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
ack(deadlineIntent)
local exitedIntent=nextNativeFixture('setup-fixture-exited')
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
managedModule.observe_route=originalObserve
ack(exitedIntent)
definition.event(state,{ev='change',item='managed-existing',value='editable'},cx)
-- Injected serializer success is deliberately not configured-CLI execution proof.
state.managed_probe={passed=true,record_sha256=string.rep('a',64),observations={}}
state.managed_probe_revision=state.snapshot.config_revision
state.managed_cli_attestation=nil
before=clone(saved)
definition.event(state,{ev='action',act='managed-attest@'..state.snapshot.config_revision},cx)
check(P.equal(before,saved) and state.notice:find('actual native route',1,true),'serializer success cannot substitute for the required actual native route')
definition.event(state,{ev='action',act='managed-cli-attest@'..state.snapshot.config_revision},cx)
check(state.managed_cli_attestation==nil,'operator CLI attestation cannot bypass actual native route proof')
-- Explicit deterministic window-proof fixture, not a runtime probe fallback.
state.managed_route={status='passed',nonce='fixture-native-route'}
definition.event(state,{ev='action',act='managed-attest@'..state.snapshot.config_revision},cx)
check(P.equal(before,saved) and state.notice:find('echo probe',1,true),'native route proof still requires independent exact-CLI semantic attestation')
definition.event(state,{ev='action',act='managed-cli-attest@'..state.snapshot.config_revision},cx)
check(state.managed_cli_attestation==state.managed_probe.record_sha256 and P.equal(before,saved),'exact-CLI operator attestation binds the reviewed fingerprint but creates no machine evidence or saved record')
definition.event(state,{ev='change',item='managed:arguments',value='--changed-flags'},cx)
definition.event(state,{ev='action',act='managed-attest@'..state.snapshot.config_revision},cx)
check(state.managed_probe==nil and P.equal(before,saved),'editing CLI flags invalidates the probe and prior attestation route')
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
local afterOwner=clone(saved)
definition.event(pageState,{ev='action',id='main',act='page-entry',value=runtime.json.encode({kind='page',page='managed',native_window='foreign-window'})},cx)
check(P.equal(saved,afterOwner) and pageState.native_window=='fixture-window','existing Config refuses a foreign native-window page entry instead of rebinding')
return 'PASS host_editor '..tostring(checks)
