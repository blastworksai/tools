-- Native host UI callbacks with real configuration/authority modules; only KV,
-- membership IO and rendering boundaries are injected. No native effects.
local root=...
assert(type(root)=='string','pass the package directory')
local runtime,environment=tern,getfenv()
local modules,definitions,saved={},{},{}
local checks,writes=0,0
local deferred,holdInspection=nil,false
local hooks,timers={},{}
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
 pane={write=function()error('Editor attempted provider input') end,list=function()return {} end},
 block={define=function(name,definition)definitions[name]=definition end},
 ui={node=function(kind,props)return {k=kind,p=props} end,col=function(children)return {children=children} end,text=function(value)return {text=value} end},
 process={run=function()error('Editor attempted a real subprocess') end},
},{__index=runtime})
modules.native_cli={inspect=function(_window,_options,callback)
 if holdInspection then deferred=callback;return end
 callback({status=0,timed_out=false,stdout=runtime.json.encode(inventory)},nil)
end}
local function load(name)
 name=name:gsub('^%./','')
 if modules[name]~=nil then return modules[name] end
 local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
 setfenv(chunk,setmetatable({require=load,tern=fake},{__index=environment}))
 modules[name]=chunk() or true;return modules[name]
end
load('host')
local A,P=load('authority'),load('bridge_protocol')
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
 return {id=id,provider='custom',account_label=id,backend='local-terminal',command='ordinary-cli',arguments={},enabled=true,include_all=true,duplicate_policy='skip',placement='tab'}
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
return 'host_editor checks: '..checks
