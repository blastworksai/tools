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
-- SKILLS-210: a Glitch installation outside the launch folder's ancestors is found from /opt/glitch, the home
-- Glitch folder or WORK's saved root, and verified exactly like an ancestor.
local function direct(directories,files,options)
 options=options or {}
 local fake={plugin={dir='/plugins/spawn',data='/plugins-data/spawn'},runtime={os=options.os or 'linux'},
  getenv=function(name)return (options.env or {})[name] end,
  json={decode=function(text)return assert(loadstring('return '..text))()end},
  fs={list=function(path)return assert(directories[path],'inaccessible directory')end,read=function(path,maximum)
   assert(path~=options.unreadable,'permission denied')
   local bytes=assert(files[path],'missing regular file');assert(#bytes<=maximum);return bytes
  end}}
 local chunk=assert(loadstring(runtime.fs.read(root..'/setup_discovery.luau'),'setup_discovery'))
 setfenv(chunk,setmetatable({tern=fake},{__index=environment}))
 return chunk().glitch(options.cwd or '/home/you')
end
local function installation(directories,files,path)
 directories[path]={'.claude'};directories[path..'/.claude']={'scripts'};directories[path..'/.claude/scripts']={'workspaces.py','plan_check.py'}
 files[path..'/.claude/scripts/workspaces.py']='workspace discovery';files[path..'/.claude/scripts/plan_check.py']='member gate'
end
local function machine()
 return {['/']={'home','opt'},['/home']={'you'},['/home/you']={},['/opt']={},['/plugins']={'spawn'},['/plugins/spawn']={}},{}
end
do
 local directories,files=machine()
 installation(directories,files,'/opt/glitch')
 local found=direct(directories,files)
 check(found.state=='detected' and found.root=='/opt/glitch','a /home/<operator> launch folder finds the Glitch folder at /opt/glitch')
 local missing,none=machine()
 check(direct(missing,none).state=='not_detected_in_known_ancestors','no candidate anywhere is a genuine bounded miss, not unavailable')
 local homeDirectories,homeFiles=machine()
 installation(homeDirectories,homeFiles,'/home/you/Glitch')
 local home=direct(homeDirectories,homeFiles,{env={HOME='/home/you'},cwd='/opt'})
 check(home.state=='detected' and home.root=='/home/you/Glitch','the Glitch folder in the operator home is found')
 local windowsDirectories,windowsFiles=machine()
 installation(windowsDirectories,windowsFiles,'C:/Users/you/Glitch');windowsDirectories['C:/Users/you']={'Glitch'}
 local windows=direct(windowsDirectories,windowsFiles,{os='windows',env={USERPROFILE='C:\\Users\\you'}})
 check(windows.state=='detected' and windows.root=='C:/Users/you/Glitch','on Windows the folder is %USERPROFILE%\\Glitch')
 local savedDirectories,savedFiles=machine()
 installation(savedDirectories,savedFiles,'/srv/saved-glitch')
 savedFiles['/plugins-data/tern-work/config.json']='{glitch_root="/srv/saved-glitch"}'
 local saved=direct(savedDirectories,savedFiles)
 check(saved.state=='detected' and saved.root=='/srv/saved-glitch','WORK\'s saved Glitch root is a candidate when its configuration is readable')
 local unreadableSaved=direct(savedDirectories,savedFiles,{unreadable='/plugins-data/tern-work/config.json'})
 check(unreadableSaved.state=='not_detected_in_known_ancestors','an unreadable WORK configuration is skipped, never an error')
 local both,bothFiles=machine()
 installation(both,bothFiles,'/opt/glitch');installation(both,bothFiles,'/srv/saved-glitch')
 bothFiles['/plugins-data/tern-work/config.json']='{glitch_root="/srv/saved-glitch"}'
 local ambiguous=direct(both,bothFiles)
 check(ambiguous.state=='ambiguous' and #ambiguous.candidates==2 and ambiguous.root==nil,'two verified candidates stay an explicit ambiguity')
 local sameDirectories,sameFiles=machine()
 installation(sameDirectories,sameFiles,'/opt/glitch');sameFiles['/plugins-data/tern-work/config.json']='{glitch_root="/opt/glitch"}'
 check(direct(sameDirectories,sameFiles,{cwd='/opt/glitch'}).state=='detected','the same root reached as ancestor and as candidate is one installation')
 local marker,markerFiles=machine()
 installation(marker,markerFiles,'/opt/glitch')
 check(direct(marker,markerFiles,{unreadable='/opt/glitch/.claude/scripts/workspaces.py'}).state=='unavailable','a candidate whose marker cannot be read is unavailable, never selected')
end
return 'PASS setup_discovery '..tostring(checks)
