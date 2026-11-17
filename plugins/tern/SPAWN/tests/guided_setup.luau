-- SKILLS-194 Guided setup: device choices first, one Start, one approval.
-- Host-side rows with real configuration/authority modules; KV, membership IO and
-- rendering are injected exactly as in host_editor.luau. No native effects.
-- Each phase yields to the native timer so every slice stays inside Tern's 50 ms
-- window-half budget when the group runs under `tern shot`.
local root=...
local function pause() if await then await(tern.sleep(1)) end end
local runtime,environment=tern,getfenv()
local modules,definitions,saved={},{},{}
local checks,writes=0,0
local deferred,holdInspection=nil,false
local hooks,timers={},{}
local paneList={{pane=7,program='spawn.spawner',cwd='/fixture current folder Ω'}}
local failures,failedSections,currentSection={},{},''
local function check(value,message) if value then checks+=1 else table.insert(failures,message);if failedSections[#failedSections]~=currentSection then table.insert(failedSections,currentSection) end end end
local function section(name,fn) pause();currentSection=name;local ok,err=pcall(fn);if not ok then table.insert(failures,name..' raised: '..tostring(err));if failedSections[#failedSections]~=currentSection then table.insert(failedSections,currentSection) end end end
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
 pause()
 local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
 local moduleDirectory=name:match('^(.*[/])') or ''
 setfenv(chunk,setmetatable({require=function(dependency)return load(dependency,moduleDirectory)end,tern=fake},{__index=environment}))
 modules[name]=chunk() or true;return modules[name]
end
-- Carrier IO is injected; these are host-boundary regressions, not native
modules['channel/channel']={open=function()
 return {send=function(frame)return {id=frame.id} end,receive=function()return {} end,acknowledged=function()return false end,
  ack=function()return true end,settle=function()return 0 end,
  quiescent=function(_,roots)local quiet={};for _,key in ipairs(roots)do quiet[key]=true end;return quiet end}
end}
pause()
load('host')
pause()
local P,A=load('bridge_protocol'),load('authority')
local definition=assert(definitions.spawner)
local cx={pane=7,save=function()end,render=function()end,action=function()error('Editor launched a window action') end,open=function()end}
pause()
local state=definition.init(cx,{runtime.json.encode({host={name='fixture'},native_window='fixture-window'})},nil)
check(state.binding~=nil and state.snapshot~=nil,'host opens through original native membership boundary')
pause()
local function prefs()pause();return definition.view(state,cx).main.children[1].p end
local function rows_of(page)
 state.page=page
 local found,ordered,sections={},{},{}
 for _,section in ipairs(prefs().sections) do
  table.insert(sections,section)
  for _,item in ipairs(section.rows) do found[item.id]=item;table.insert(ordered,item) end
 end
 return found,ordered,sections
end
local rev=state.snapshot.config_revision
local rows,guided,sections
local function intents()
 for _,child in ipairs(definition.view(state,cx).main.children) do
  if child.p and child.p.key=='spawn-launch-intent' then return runtime.json.decode(child.text).intents end
 end
 error('no intent node')
end
local function click(act) pause();definition.event(state,{ev='action',act=act..'@'..state.snapshot.config_revision},cx) end

-- 1. Device choices are shown by default, as children of Guided setup.
section('device choices default',function()
rows,_,sections=rows_of('setup')
check(state.setup_topology~=nil and state.setup_topology.mode=='single','a fresh Setup page already holds the Single device default')
check(rows['setup-device-mode']~=nil and rows['setup-device-mode'].control.value=='single','Single/Multi device choice is visible without any Guided setup click')
check(rows['setup-find-devices']~=nil,'Find execution machines is visible without any Guided setup click')
check(rows['setup-device-mode'].indent==1 and rows['setup-find-devices'].indent==1 and rows['setup-start-helper'].indent==1,'the device choices and Start are indented as Guided setup children')
for _,candidate in ipairs(sections) do if candidate.title=='Guided setup' then guided=candidate end end
check(guided~=nil and type(guided.hint)=='string' and #guided.hint>20,'Guided setup is a titled heading section with helper text')
local childIds={}
for _,item in ipairs(guided.rows) do table.insert(childIds,item.id) end
check(childIds[1]=='setup-device-mode' and childIds[2]=='setup-find-devices','the heading section lists the device choice first, then discovery')
end)
section('single disables discovery',function()
-- 1b. Discovery is grey and disabled while Single device is selected, enabled for Multi.
check(type(rows['setup-find-devices'].disabled)=='string' and rows['setup-find-devices'].disabled~='','Find execution machines is disabled while Single device is selected')
click('setup-find-devices')
check(state.setup_topology.request==nil,'a crafted discovery click in Single mode starts no discovery')
definition.event(state,{ev='change',item='setup-device-mode',value='multi'},cx)
rows=rows_of('setup')
check(state.setup_topology.mode=='multi' and rows['setup-find-devices'].disabled==nil,'Find execution machines is enabled for Multi device')
definition.event(state,{ev='change',item='setup-device-mode',value='single'},cx)
rows=rows_of('setup')
check(type(rows['setup-find-devices'].disabled)=='string','returning to Single device disables discovery again')
end)
pause()
section('one start',function()
-- 2. Guided setup is a heading plus helper text; exactly one Start action follows.
check(rows['setup-flow']==nil,'Guided setup is no longer a row with its own button')
local startCount=0
for _,item in ipairs(guided.rows) do if item.label=='Start Guided setup — may use model credits' then startCount+=1 end end
check(startCount==1 and rows['setup-start-helper'].control.act=='setup-start-helper@'..rev,'exactly one Start Guided setup action exists after the device choices')
local startsLaunchSetup=false
for _,item in ipairs(guided.rows) do if item.control.k=='action' and tostring(item.control.act):find('^launch%-setup') then startsLaunchSetup=true end end
check(not startsLaunchSetup,'no peer button reveals the device choices any more')
check(rows['setup-start-helper'].disabled==nil,'Single device needs no discovery before Start')
click('setup-start-helper')
check(#intents()==1 and intents()[1].kind=='setup','Single device Start queues one setup intent without a discovery step')
check(rows_of('setup')['setup-start-helper'].disabled~=nil,'a queued helper disables the only Start action')
end)
pause()
section('prepare for orch',function()
-- 4. ORCH+ order: one Prepare action for missing work, none when everything is prepared.
local function record(id,verified)
 local r={id=id,provider='custom',account_label=id,backend='local-terminal',command='ordinary-cli',arguments={},enabled=true,placement='tab',cwd='/fixture'}
 return r
end
state.intents={}
local seeded={record('prep-a'),record('prep-b')}
check(A.edit(state.binding,state.snapshot.config_revision,'replace-records',{records=seeded}),'seed two unprepared agents')
definition.event(state,{ev='action',act='refresh'},cx)
rows=rows_of('setup')
check(rows['setup-managed']~=nil and rows['setup-managed'].control.k=='action' and rows['setup-managed'].label=='Prepare agents for ORCH+','missing preparation offers the one Prepare agents for ORCH+ action')
check(rows['setup-managed'].control.act:find('^managed%-prepare%-missing')~=nil,'the Prepare action targets only the missing work')
local preparedCount=0
for _,item in pairs(rows) do if item.label=='Prepare agents for ORCH+' then preparedCount+=1 end end
check(preparedCount==1,'there is exactly one Prepare agents for ORCH+ action')
pause()
-- Preparation evidence (a verified managed mailbox) is only ever written by the real
-- preparation path, which needs a live native window. The view reads it from the
-- host's own state, so the fixture sets it there and renders without a reload.
for index,r in ipairs(state.config.agents) do
 r.mailbox={permitted_root='/mb',helper_path='/mb/h.sh',producer_helper_path='/mb/p.sh',worker_identity='w',evidence_ref='ev-'..index,verified=true,wake='worker-poll-v1',capabilities={'report-files-v1'}}
end
rows=rows_of('setup')
check(rows['setup-managed']==nil,'all agents prepared shows no Prepare agents for ORCH+ button')
check(rows['setup-managed-state']~=nil and rows['setup-managed-state'].control.k~='action' and rows['setup-managed-state'].disabled~=nil,'the prepared state is visible as a read-only row, not a button')
state.config.agents[2].mailbox=nil
rows=rows_of('setup')
check(rows['setup-managed']~=nil and rows['setup-managed'].hint:find('1 saved agent',1,true)~=nil,'one agent still missing offers the action for that missing work only')
state.config.agents[1].mailbox={permitted_root='/mb',helper_path='/mb/h.sh',producer_helper_path='/mb/p.sh',worker_identity='w',evidence_ref='ev-1',verified=true,wake='worker-poll-v1',capabilities={'report-files-v1'}}
pause()
click('managed-prepare-missing')
local batch=state.managed_batch
check(batch~=nil and #batch.entries==1 and batch.entries[1].record_id=='prep-b','the one Prepare action batches only the agent that is missing, reusing the prepared one')
state.managed_batch=nil
for index,r in ipairs(state.config.agents) do
 r.mailbox={permitted_root='/mb',helper_path='/mb/h.sh',producer_helper_path='/mb/p.sh',worker_identity='w',evidence_ref='ev-'..index,verified=true,wake='worker-poll-v1',capabilities={'report-files-v1'}}
end
click('managed-prepare-missing')
check(state.managed_batch==nil and state.notice:find('already prepared',1,true)~=nil,'with everything prepared the action refuses and starts no check')
-- Per-agent inspection stays under Advanced.
definition.event(state,{ev='action',act='advanced-open'},cx)
rows=rows_of('setup')
check(rows['setup-managed-advanced']~=nil and rows['setup-managed-advanced'].control.k=='action','Advanced keeps per-agent inspection and re-preparation')
definition.event(state,{ev='action',act='advanced-close'},cx)
check(rows_of('setup')['setup-managed-advanced']==nil,'normal Setup hides per-agent inspection')
end)
pause()
section('stale notice',function()
-- Stale notice: a retained result lead must clear once setup completes.
local stale='Setup result received. SPAWN saves, prepares and verifies the approved agents automatically.'
state.notice=stale
state.setup_result_attempt=nil
definition.event(state,{ev='action',act='refresh'},cx)
definition.view(state,cx)
check(state.notice~=stale,'the received-result lead does not survive once no pending result exists')
state.notice=stale
pause()
check(tern.json.encode(definition.view(state,cx)):find(stale,1,true)==nil,'no rendered lead still announces a result that is no longer pending')
local source=tern.fs.read(root..'/host.luau')
check(source:find('ready for review',1,true)==nil,'the old "ready for review" notice text no longer exists')
end)
pause()
section('single approval in the window',function()
 -- The window half cannot be driven here (window_dispatch needs a native desktop);
 -- these are source-level guards on the exact code path, next to the pure plan tests
 -- in setup_review and the full window_dispatch walk.
 local window=tern.fs.read(root..'/window.luau')
 check(window:find('Review the complete submitted configuration',1,true)==nil,'no floating review popup is built for a submitted setup result')
 check(window:find('Save and prepare these agents',1,true)==nil and window:find('Save settings only',1,true)==nil,'no second Save and prepare choice exists in the window')
 check(window:find('Review.automatic_plan(pending.review.records, pending.review.paid_checks)',1,true)~=nil,'a bound submission is turned into an automatic plan, not a prompt')
 local body=window:match('local function commit_setup.-\nlocal function review_setup') or ''
 check(body:find('"import_records"',1,true)~=nil and body:find('pending_digest = pending.digest',1,true)~=nil and body:find('pending_setup(check_cx, run, value, pending)',1,true)~=nil,'the automatic save keeps the exact run, result digest and last-moment source fence')
 check(body:find('start_reviewed',1,true)~=nil and body:find('capture_reviewed',1,true)~=nil,'preparation stays bound to the saved revision through the existing once-only capture')
 check(body:find('managed-exercise',1,true)==nil and body:find('exercise',1,true)==nil,'optional provider-backed exercises are never started by the automatic flow')
 local skill=tern.fs.read(root..'/skills/setup/SKILL.md')
 check(skill:find('Save and prepare these agents',1,true)==nil,'the setup skill no longer promises a second approval action')
end)
pause()
section('paid scope in the window',function()
 local window=tern.fs.read(root..'/window.luau')
 local body=window:match('local function commit_setup.-\nlocal function review_setup') or ''
 check(body:find('plan.prepare_ids',1,true)~=nil and body:find('selected_records',1,true)~=nil and body:find('capture_reviewed(cx, run.origin.pane, run.bootstrap.host_config_pane, selected_records',1,true)~=nil,'only the plan\'s records, never the whole roster, are captured for preparation')
 check(window:find('Not checked (no paid check was disclosed)',1,true)~=nil,'the owner is told which native accounts were not checked')
end)
pause()
section('disclosed prepare action',function()
 state.intents={}
 local omp={id='omp-a',provider='OMP',account_label='Work',backend='native-agent',command='omp',arguments={},enabled=true,placement='tab',cwd='/fixture',prompt='Begin.',model='model-x'}
 pause()
 check(A.edit(state.binding,state.snapshot.config_revision,'replace-records',{records={omp}}),'seed one unprepared native OMP account')
 pause()
 definition.event(state,{ev='action',act='refresh'},cx)
 pause()
 local rows=rows_of('setup')
 local action=rows['setup-managed']
 check(action~=nil and action.control.k=='action','the single Prepare action is offered for the native account')
 local hint=(action and action.hint or '')
 check(action~=nil and action.label:find('uses model credits',1,true)~=nil,'the label says the click uses model credits')
 check(hint:find('Work',1,true)~=nil and hint:find('model-x',1,true)~=nil and hint:find('credits',1,true)~=nil and hint:find('not a sandbox',1,true)~=nil,'the hint names the account, model, credits and sandbox before the click')
 local terminal={id='term-a',provider='custom',account_label='term-a',backend='local-terminal',command='ordinary-cli',arguments={},enabled=true,placement='tab',cwd='/fixture'}
 pause()
 check(A.edit(state.binding,state.snapshot.config_revision,'replace-records',{records={terminal}}),'seed a terminal-only roster')
 pause()
 definition.event(state,{ev='action',act='refresh'},cx)
 pause()
 action=rows_of('setup')['setup-managed']
 check(action~=nil and action.label=='Prepare agents for ORCH+' and action.hint:find('credits',1,true)==nil and action.hint:find('offline',1,true)~=nil,'terminal-only work stays offline and mentions no credits')
end)
pause()
section('stale preparation',function()
 local base={id='prep-c',provider='custom',account_label='prep-c',backend='local-terminal',command='ordinary-cli',arguments={},enabled=true,placement='tab',cwd='/fixture',
  mailbox={permitted_root='/mailboxes',helper_path='/tools/mailbox_target.sh',producer_helper_path='/tools/mailbox_worker.sh',worker_identity='worker',producer={read=true,write=true,hash=true,journal=true,poll=true},capabilities={'report-files-v1','worker-poll-v1','argv-v1'},wake='worker-poll-v1',verified=false,evidence_ref='fixture-unverified'}}
 pause()
 check(A.edit(state.binding,state.snapshot.config_revision,'replace-records',{records={base}}),'seed a record with a mailbox')
 pause()
 definition.event(state,{ev='action',act='refresh'},cx)
 local agent=state.config.agents[1]
 agent.mailbox.verified=true
 check(rows_of('setup')['setup-managed']==nil,'a verified record with no contract change counts as prepared')
 agent.user='someone-else'
 pause()
 local rows=rows_of('setup')
 check(rows['setup-managed']~=nil and rows['setup-managed'].control.k=='action' and rows['setup-managed-state']==nil,'a saved OS account that differs from the verified worker identity is not prepared')
 agent.user=nil
 -- Editing a contract field of a prepared record withdraws the preparation.
 local revision=state.snapshot.config_revision
 pause()
 definition.event(state,{ev='change',item='agent:prep-c:cwd:'..revision,value='/fixture/other'},cx)
 pause()
 local saved_record=A.snapshot(state.binding).records[1]
 check(saved_record.cwd=='/fixture/other' and saved_record.mailbox.verified==false,'changing a prepared record\'s folder withdraws its verification')
 pause()
 definition.event(state,{ev='action',act='refresh'},cx)
 check(rows_of('setup')['setup-managed']~=nil,'the withdrawn preparation is offered again as missing work')
end)
assert(#failures==0,'guided_setup FAILED sections: '..table.concat(failedSections,', ')..' || '..(table.concat(failures,' | '):gsub('[%c"]',' ')))
return 'PASS guided_setup '..checks
