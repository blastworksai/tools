-- Actual bounded detector with isolated host filesystem observations.
local root=...
assert(type(root)=='string','pass package directory')
local runtime,environment=tern,getfenv()
local checks=0
local function check(value,message)assert(value,message);checks+=1 end
local function observe(installations,missing,unreadable)
 local directories={['/']={'one','two'},['/one']={'project'},['/one/project']={},['/two']={'plugin'},['/two/plugin']={}}
 local files={}
 for _,path in ipairs(installations) do
  table.insert(directories[path],'.claude')
  directories[path..'/.claude']={'scripts'}
  directories[path..'/.claude/scripts']={'workspaces.py','plan_check.py'}
  files[path..'/.claude/scripts/workspaces.py']='workspace discovery'
  files[path..'/.claude/scripts/plan_check.py']='member gate'
 end
 if missing then directories[missing]=nil end
 local fake={plugin={dir='/two/plugin'},fs={list=function(path)return assert(directories[path],'inaccessible directory')end,read=function(path,maximum)
  assert(path~=unreadable,'permission denied')
  local bytes=assert(files[path],'missing regular file');assert(#bytes<=maximum);return bytes
 end}}
 local chunk=assert(loadstring(runtime.fs.read(root..'/setup_discovery.luau'),'setup_discovery'))
 setfenv(chunk,setmetatable({tern=fake},{__index=environment}))
 return chunk().glitch('/one/project')
end
local single=observe({'/one'})
check(single.state=='detected' and single.root=='/one','one verified installation is selected without enabling integration')
local multiple=observe({'/one','/two'})
check(multiple.state=='ambiguous' and #multiple.candidates==2 and multiple.root==nil,'different working-folder and plugin installation roots remain an explicit ambiguity')
local absent=observe({})
check(absent.state=='not_detected_in_known_ancestors' and absent.root==nil,'accessible known ancestors without markers are genuinely not detected')
local inaccessible=observe({'/one'},'/two')
check(inaccessible.state=='unavailable' and #inaccessible.candidates==1 and inaccessible.root==nil,'an inaccessible second chain is not silently interpreted as a unique installation or absence')
local unreadable=observe({'/one'},nil,'/one/.claude/scripts/workspaces.py')
check(unreadable.state=='unavailable' and unreadable.root==nil,'permission failure of an actual marker remains unavailable rather than not found')
local detector=assert(loadstring(runtime.fs.read(root..'/setup_discovery.luau'),'setup_discovery'))()
local machines={
 {id=8,name='Execution VM',kind='remote',address='existing@example.test',state='connected',sessions={81}},
 {id=0,name='Personal desktop',kind='local',state='connected',sessions={1}},
 {id=9,name='Offline workstation',kind='remote',address='offline.example.test',state='failed',sessions={}},
}
local observed=assert(detector.devices(machines,machines[1]))
check(observed.current==8 and #observed.devices==3,'actual current remote execution host is the default, not the desktop')
local primary=assert(detector.primary(observed,observed.current,'single'))
check(primary.id==8 and primary.kind=='remote','single-device setup can execute locally within the Tern-attached VM without another SSH hop')
check(detector.primary(observed,0,'multi').name=='Personal desktop','multi-device choice can select another actually discovered execution machine')
check(detector.primary(observed,999,'multi')==nil,'an undiscovered device is never accepted or guessed')
check(detector.primary(observed,9,'multi')==nil,'known failed connections remain explicit prerequisites rather than eligible launch hosts')
check(detector.primary(observed,8,'unspecified')==nil,'device topology is required before execution selection')
local noSession={devices={{id=5,name='Connected without session',kind='remote',state='connected',sessions={}}},current=5}
check(detector.primary(noSession,5,'multi')==nil,'a connected machine without a real Tern session does not create a helper or transport terminal')
check(detector.devices(nil,machines[1])==nil,'unavailable SDK inventory is not represented as absence')
check(detector.devices({machines[1],machines[1]},machines[1])==nil,'duplicate device identity is refused')
check(detector.devices(machines,{id=8,name='Renamed VM',kind='remote',address='existing@example.test'})==nil,'current host identity drift cannot choose a same-numbered replacement')
machines[1].sessions[1]=999
check(primary.sessions[1]==81,'captured native membership is isolated from later SDK table mutation')
return 'PASS setup_discovery '..tostring(checks)
