-- SKILLS-174: a remote client's window key names a window of the CLIENT's daemon.
-- The host must never run `tern inspect --window <client key>` against its own daemon.
-- The topology below comes from two REAL isolated Tern daemons (see remote_window_key.py,
-- which regenerates remote_window_key.fixture.json): the client machine has windows "" and
-- "2"; the host machine has one window "" and refuses `inspect --window 2` with the real
-- message recorded in the fixture. The host's real HOST code runs against that daemon model.
local root=...
assert(type(root)=='string','pass the package directory')
local runtime,environment=tern,getfenv()
local fixture=runtime.json.decode(runtime.fs.read(root..'/tests/remote_window_key.fixture.json'))
local modules,definitions,saved,journalFiles={}, {}, {}, {}
local checks=0
local function check(value,message) assert(value,message);checks+=1 end
local function clone(value)
 if type(value)~='table' then return value end
 local out={};for key,item in pairs(value) do out[key]=clone(item) end
 return out
end
local function journalExists(path)
 if journalFiles[path]~=nil then return true end
 for name in pairs(journalFiles) do if name:sub(1,#path+1)==path..'/' then return true end end
 return false
end
local function journalList(path)
 local seen,entries={}, {}
 for name in pairs(journalFiles) do
  if name:sub(1,#path+1)==path..'/' then
   local child=name:sub(#path+2):match('^[^/]+')
   if not seen[child] then seen[child]=true;table.insert(entries,child) end
  end
 end
 table.sort(entries);return entries
end
local PANE=fixture.host_pane
local paneList={{pane=PANE,program='spawn.spawner',cwd='/fixture folder'}}
local fake=setmetatable({
 context='host',
 fs={exists=journalExists,list=journalList,mkdir=function()end,
  read=function(path)return assert(journalFiles[path],'missing fixture file '..path)end,
  remove=function(path)
   for name in pairs(journalFiles) do if name==path or name:sub(1,#path+1)==path..'/' then journalFiles[name]=nil end end
  end,
  write=function(path,bytes)journalFiles[path]=bytes end},
 now=function()return 1700000000 end,
 kv={get=function(key)return clone(saved[key]) end,set=function(key,value)saved[key]=clone(value) end},
 json=runtime.json,
 on=function()end,
 timer=function(_,callback)return {} end,
 pane={write=function()error('Config attempted provider input') end,list=function()return clone(paneList) end},
 block={define=function(name,definition)definitions[name]=definition end},
 ui={node=function(kind,props)return {k=kind,p=props} end,col=function(children)return {children=children} end,text=function(value)return {text=value} end,span=function(value)return value end},
 process={run=function()error('Config attempted a real subprocess') end},
},{__index=runtime})
-- The host machine's daemon: every call lands here, keyed exactly as `tern inspect --window`.
local calls={}
local function daemon(inventory)
 local keys={}
 for _,client in ipairs(inventory.clients) do if client.kind=='window' or client.kind=='remote' then keys[client.window]=true end end
 return function(window,_options,callback)
  table.insert(calls,window==nil and '<none>' or window)
  if window~=nil and not keys[window] then
   callback({status=fixture.host_refusal.status,timed_out=false,stdout='',stderr=fixture.host_refusal.stderr},nil)
   return
  end
  callback({status=0,timed_out=false,stdout=runtime.json.encode(inventory),stderr=''},nil)
 end
end
local observed_windows={}
modules.native_cli={inspect=daemon(fixture.host_inventory),epoch=function()return 'fixture-epoch' end,
 -- the host daemon's process inspection: keyed exactly like `tern inspect --window`
 observe_process=function(window,_session,_pane,callback)
  table.insert(observed_windows,window)
  callback(nil,'fixture: no native process')
 end}
modules['channel/channel']={open=function()
 return {send=function(frame)return {id=frame.id} end,receive=function()return {} end,acknowledged=function()return false end,
  ack=function()return true end,settle=function()return 0 end,quiescent=function(_,roots)local quiet={};for _,key in ipairs(roots) do quiet[key]=true end;return quiet end}
end}
local function load(name,directory)
 if name:sub(1,2)=='./' then name=(directory or '')..name:sub(3) end
 if modules[name]~=nil then return modules[name] end
 local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
 local moduleDirectory=name:match('^(.*[/])') or ''
 setfenv(chunk,setmetatable({require=function(dependency)return load(dependency,moduleDirectory)end,tern=fake},{__index=environment}))
 modules[name]=chunk() or true;return modules[name]
end
load('host')
local definition=assert(definitions.spawner)
local cx={pane=PANE,save=function()end,render=function()end}
local function open(host_kind,window,inventory)
 calls={}
 modules.native_cli.inspect=daemon(inventory or fixture.host_inventory)
 return definition.init(cx,{runtime.json.encode({host={name='fixture',kind=host_kind},native_window=window})},nil)
end
local client_window=fixture.client_window
-- The fixture's premise, proven from the recorded real daemons.
check(client_window=='2' and #fixture.client_keys==2 and fixture.client_keys[2]=='2','real client machine has a second window keyed "2"')
local host_keys={}
for _,client in ipairs(fixture.host_inventory.clients) do if client.kind=='remote' then host_keys[client.window]=true end end
check(host_keys['']==true and host_keys['2']==nil,'real host daemon knows its remote client only as ""')
check(fixture.host_refusal.stderr:find('no window has key 2',1,true)~=nil,'real host daemon refuses --window 2')

-- 1. THE DEFECT: client window "2", remote execution host. Pre-fix this ran inspect --window 2.
local remote=open('remote',client_window)
check(remote.binding~=nil and remote.snapshot~=nil and remote.scope_error==nil,'remote client window "2" opens Config on a host that knows it as ""')
for _,window in ipairs(calls) do check(window~=client_window,'the client key "2" is never passed to the host daemon') end
check(remote.native_window=='2' and remote.host_window=='','the client key stays a routing hint; the host daemon\'s own key is resolved from membership')

-- 2. Single machine, key "" on both sides: unchanged behaviour, the hint is used directly.
local local_inventory=clone(fixture.host_inventory)
for _,client in ipairs(local_inventory.clients) do if client.kind=='remote' then client.kind='window' end end
local single=open('local','',local_inventory)
check(single.binding~=nil and single.scope_error==nil and single.host_window==nil,'single machine "" opens Config with its own key')
check(#calls>0 and calls[1]=='','single machine inspects exactly the captured key')

-- 3. Negative control: a local host does not rewrite a client key, so an unknown key still refuses.
local refused=open('local',client_window,local_inventory)
check(refused.binding==nil and refused.scope_error~=nil,'a non-remote host never substitutes another window for an unknown key')

-- 4. Negative control: a remote host whose pane is in no window refuses instead of guessing.
paneList[1].pane=PANE+1000
cx.pane=PANE+1000
local missing=open('remote',client_window)
check(missing.binding==nil and missing.scope_error~=nil and missing.host_window==nil,'remote host refuses when the Config pane belongs to no host window')
cx.pane=PANE;paneList[1].pane=PANE

-- 5. The page entry (Managed setup / readiness) takes the same road: SPAWN's own owner context
-- carries the client key "2"; the remote host must still open its authority.
calls={}
modules.native_cli.inspect=daemon(fixture.host_inventory)
local page=definition.init(cx,{runtime.json.encode({kind='page',page='managed',native_window=client_window})},nil)
check(page.binding==nil and page.page_context_request~=nil,'page entry waits for SPAWN owner context')
definition.event(page,{ev='action',id='main',act='spawn.page-context',value=runtime.json.encode({nonce=page.page_context_request.nonce,
 context={kind='context',host={id=0,name='remote-host',kind='remote',address='203.0.113.9'},native_window=client_window}})},cx)
check(page.binding~=nil and page.scope_error==nil and page.host_window=='','page entry from client window "2" binds on the remote host')
for _,window in ipairs(calls) do check(window~=client_window,'page entry never sends the client key to the host daemon') end

-- 6. Guided setup from client window "2" on a remote host. The request carries the client's key
-- as its echo ("2"); the host's own client inventory knows the window only as "". Pre-fix the
-- authority searched the host inventory for "2" and refused with "Original native setup window
-- is unavailable", and the helper prompt told the host daemon `--window 2`.
local A=load('authority')
local binding=remote.binding
journalFiles[tostring(runtime.plugin.dir)..'/skills/setup/SKILL.md']='Fixture setup skill.'
local block_cwd=fixture.host_inventory.sessions[1].tabs[1].blocks[1].cwd
local function setup_request(sequence,run_id,window)
 return {version=2,request_id='window/'..sequence,authority_id=binding.authority_id,observer_id='window',request_sequence=sequence,
  acknowledged_requests={},expected_config_revision=remote.snapshot.config_revision,op='start_setup',
  data={setup_run_id=run_id,command='truthful-default --opaque',cwd=block_cwd,window=window,config_pane=700}}
end
local function setup_reply(request,context)
 local ok,why=A.request(binding,request,context)
 local snapshot=A.snapshot(binding,'fixture-epoch')
 return ok,why,snapshot and snapshot.replies[request.request_id]
end
local remote_context={config_pane=PANE,window=client_window,host_window=remote.host_window,epoch='fixture-epoch',inventory=fixture.host_inventory}
-- Negative control first (the pre-fix context: no resolved host window): the host inventory cannot match "2".
local _,_,legacy=setup_reply(setup_request(1,'legacy-setup',client_window),{config_pane=PANE,window=client_window,epoch='fixture-epoch',inventory=fixture.host_inventory})
check(legacy~=nil and legacy.ok==false and tostring(legacy.error):find('Original native setup window is unavailable',1,true)~=nil,'without the resolved host window the client key cannot match the host inventory: '..tostring(legacy and legacy.error))
local ok,why,reply=setup_reply(setup_request(2,'remote-setup',client_window),remote_context)
check(ok and reply~=nil and reply.ok,'guided setup from client window "2" is admitted by a host that knows it as "": '..tostring(reply and reply.error))
local prompt=reply.result.job.initial_prompt
check(type(prompt)=='string' and prompt:find("'--window' '' '--json'",1,true)~=nil,"the setup helper is told the host daemon's own window key")
check(prompt:find("'--window' '2'",1,true)==nil,'the setup helper is never told the client key')

-- 7. Managed diagnostic route: its window stays the client echo, the host's process inspection
-- must be keyed by the host daemon's window.
local Managed=load('managed_setup')
local function route_window(host_window)
 observed_windows={}
 Managed.observe_route({backend='native-agent',window=client_window,cwd='/fixture folder',expected_arguments={'--x'},host_os='linux'},1,2,function()end,host_window)
 return observed_windows[1]
end
check(route_window(remote.host_window)=='','managed route process inspection uses the host daemon window, not "2"')
check(route_window(nil)==client_window,'single machine: with no host window the route keeps its own window')
return 'PASS '..tostring(checks)..' SPAWN remote window key checks'
