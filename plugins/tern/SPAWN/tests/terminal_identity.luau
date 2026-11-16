-- Exercises actual process-proof construction/revalidation with isolated native
-- observations and procfs bytes. No providers, native CLI or child processes run.
local root=...
assert(type(root)=='string','pass package directory')
local runtime,environment=tern,getfenv()
local checks=0
local function check(value,message)assert(value,message);checks+=1 end
local files={}
local boot='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
files['/proc/sys/kernel/random/boot_id']=boot..'\n'
local function stat(pid,parent,group,tty,foreground,started)
 local fields={'S',tostring(parent),tostring(group),'100',tostring(tty),tostring(foreground)}
 for _=7,19 do table.insert(fields,'0') end
 table.insert(fields,tostring(started))
 files['/proc/'..pid..'/stat']=tostring(pid)..' (fixture process) '..table.concat(fields,' ')..'\n'
end
local function seed()
 stat(100,1,100,123,200,111);stat(200,100,200,123,200,222);stat(300,200,200,123,200,333)
 files['/proc/100/cmdline']='/bin/sh\0-c\0approved-launch-command\0'
 files['/proc/200/cmdline']='/tools/provider\0--task\0literal assignment Ω\0'
 files['/proc/300/cmdline']='/bin/sh\0report-helper\0token\0'
end
seed()
local native={pane=55,child={pid=100,argv={'/bin/sh','-c','approved-launch-command'}},foreground={pid=300}}
local observations=0
local fake=setmetatable({runtime={os='linux'},fs={read=function(path,maximum)
 local bytes=files[path];assert(bytes,'unavailable observed process '..path);assert(not maximum or #bytes<=maximum,'bounded procfs read');return bytes
end},process={run=function()error('Linux terminal proof must not start a child')end}},{__index=runtime})
local modules={}
local function load(name)
 name=name:gsub('^%./','')
 if name=='native_cli' then return {process=function(route,session,pane,_,done)
  observations+=1;assert(route.pane==55 and pane==55 and session==3,'exact retained native target')
  done({status=0,timed_out=false,stdout=runtime.json.encode(native)},nil)
 end} end
 if modules[name] then return modules[name] end
 local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
 setfenv(chunk,setmetatable({tern=fake,require=load},{__index=environment}))
 modules[name]=chunk();return modules[name]
end
local T=load('terminal_identity')
local route={executable='/tools/tern',socket='/runtime/socket',window='',pane=55}
local expected={executable='/tools/provider',arguments={'--task','literal assignment Ω'}}
local proof,problem
T.capture(route,3,expected,function(value,why)proof=value;problem=why end)
check(proof and T.valid(proof) and proof.provider_pid==200 and proof.root_pid==100 and problem==nil,'capture selects exact configured provider argv in native foreground ancestry, not its transient report helper')
local function verify()
 local passed,why
 T.verify(proof,function(value,problem)passed=value;why=problem end)
 return passed,why
end
check(verify()==true,'same original root/provider creation identities, argv and foreground tty verify')
stat(200,100,200,123,200,999)
check(verify()==false,'PID reuse with changed OS start identity remains held')
seed();stat(200,100,200,999,200,222)
check(verify()==false,'changed controlling tty remains held')
seed();stat(200,100,200,123,400,222)
check(verify()==false,'provider moved out of the foreground process group remains held')
seed();files['/proc/200/cmdline']='/tools/provider\0--task\0a different conversation\0'
check(verify()==false,'exec/argv replacement under the same PID and start identity remains held')
seed();stat(400,100,200,123,200,444);native.foreground.pid=400
check(verify()==false,'unrelated foreground process is not accepted merely because it shares the tty group')
native.foreground.pid=300;native.child.pid=999
check(verify()==false,'a different native pane root remains held')
native.child.pid=100;files['/proc/200/stat']=nil
check(verify()==false,'missing original process is unknown rather than a fabricated stop or a replacement identity')
local before=observations
local missing
T.verify(nil,function(value)missing=value end)
check(missing==false and observations==before,'legacy absence of retained launch proof cannot be reconstructed from a current pane label')
seed();files['/proc/200/cmdline']='/tools/bootstrap-helper\0--task\0literal assignment Ω\0'
local unqualified
T.capture(route,3,expected,function(value)unqualified=value end)
check(unqualified==nil,'a transient helper carrying the task bytes cannot qualify as the configured provider executable')
return 'PASS terminal_identity '..tostring(checks)
