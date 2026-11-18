-- Same-host terminal continuation proof. Observations never launch a provider,
-- write pane input, change credentials or infer that an absent process stopped.
local Native=require('./native_cli')
local Backend=require('./backend')
local Codec=require('./wire/codec')
local M={}
local function integer(value) return type(value)=='number' and value%1==0 and value>0 and value<=9007199254740991 end
local function text(value,maximum) return type(value)=='string' and #value>0 and #value<=maximum and not value:find('%c') end
local function closed(value,allowed)
 if type(value)~='table' then return false end
 for key in pairs(value) do if not allowed[key] then return false end end
 return true
end
function M.valid(value)
 if not closed(value,{platform=true,session=true,route=true,root_pid=true,root_identity=true,provider_pid=true,provider_identity=true,tty=true,group=true,process_session=true,root_argv_sha256=true,provider_argv_sha256=true}) or (value.platform~='linux' and value.platform~='windows' and value.platform~='macos') or not integer(value.session) or not integer(value.root_pid) or not integer(value.provider_pid) or not text(value.root_identity,256) or not text(value.provider_identity,256) then return false end
 local route=value.route
 if not closed(route,{executable=true,socket=true,window=true,pane=true}) or not text(route.executable,8192) or not text(route.socket,8192) or type(route.window)~='string' or #route.window>256 or route.window:find('%c') or not integer(route.pane) then return false end
 if value.platform~='windows' then return type(value.tty)=='string' and value.tty:match('^%-?%d+$')~=nil and value.tty~='0' and type(value.group)=='string' and value.group:match('^%d+$')~=nil and type(value.process_session)=='string' and value.process_session:match('^%d+$')~=nil and type(value.root_argv_sha256)=='string' and #value.root_argv_sha256==64 and type(value.provider_argv_sha256)=='string' and #value.provider_argv_sha256==64 end
 return value.tty==nil and value.group==nil and value.process_session==nil and value.root_argv_sha256==nil and value.provider_argv_sha256==nil
end
local function linux(pid)
 if not integer(pid) then return nil end
 local ok,value=pcall(function()
  local bytes=tern.fs.read('/proc/'..string.format('%.0f',pid)..'/stat',16384)
  local actual,rest=bytes:match('^(%d+) %(.+%) (.+)$')
  if tonumber(actual)~=pid then return nil end
  local fields={};for word in rest:gmatch('%S+') do table.insert(fields,word);if #fields==20 then break end end
  if #fields~=20 or fields[1]=='Z' or fields[1]=='X' then return nil end
  local boot=tern.fs.read('/proc/sys/kernel/random/boot_id',128):gsub('%s+$','')
  if not boot:match('^[%x%-]+$') or #boot~=36 then return nil end
  return {identity=boot..':'..actual..':'..fields[20],parent=tonumber(fields[2]),group=fields[3],session=fields[4],tty=fields[5],foreground=fields[6]}
 end)
 return if ok then value else nil
end
local function argv(pid)
 local ok,bytes=pcall(tern.fs.read,'/proc/'..string.format('%.0f',pid)..'/cmdline',65536)
 if not ok or bytes=='' or bytes:sub(-1)~='\0' then return nil end
 local words={};for word in bytes:gmatch('([^\0]*)\0') do table.insert(words,word) end
 return words,Codec.sha256(bytes)
end
local function invocation(pid,expected)
 local words,hash=argv(pid)
 if not words then return false end
 local offset=#words-#expected.arguments
 if offset<1 or offset>3 then return false end
 local executable=words[offset]
 local matches=if expected.executable:find('/',1,true) then executable==expected.executable else executable:match('([^/]+)$')==expected.executable
 if not matches then return false end
 for index,word in ipairs(expected.arguments) do if words[offset+index]~=word then return false end end
 return true,hash
end
local function process(route,session,done)
 local ok,why=pcall(Native.process,route,session,route.pane,{timeout_ms=5000},function(result,problem)
  if problem or not result or result.timed_out or result.status~=0 or type(result.stdout)~='string' or #result.stdout>2000000 then done(nil,problem or 'Native terminal process observation is unavailable');return end
  local decoded,value=pcall(tern.json.decode,result.stdout)
  if not decoded or type(value)~='table' or value.pane~=route.pane or type(value.child)~='table' or not integer(value.child.pid) then done(nil,'Native process observation does not identify the retained terminal pane');return end
  done(value,nil)
 end)
 if not ok then done(nil,tostring(why):sub(1,512)) end
end
local function windows(root,provider,expected,foreground,done)
 -- StartTime ticks distinguish PID reuse; CIM establishes the live parent edge.
 -- No argv, account data or environment is returned by this read-only observer.
 if not integer(foreground) then done(nil,'Current native Windows foreground association is unavailable');return end
 local select
 local setup,stdin='',''
 if provider then select='$p=Get-CimInstance Win32_Process -Filter "ProcessId = '..string.format('%.0f',provider)..'";if(!$p -or [long]$p.ParentProcessId -ne $r.Id){throw "Provider parent changed"}'
 else
  local words={};for _,word in ipairs(expected.arguments) do table.insert(words,Backend.windows_argument(word)) end
  stdin=tern.json.encode({executable=expected.executable,tail=table.concat(words,' ')})
  setup='$expected=([Console]::In.ReadToEnd()|ConvertFrom-Json);'
  select='$children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId = '..string.format('%.0f',root)..'"|Where-Object {$exe=[string]$_.ExecutablePath;$name=[IO.Path]::GetFileName($expected.executable);if(![IO.Path]::GetExtension($name)){$name+=".exe"};$match=([IO.Path]::GetFileName($exe) -ieq $name);if([IO.Path]::IsPathRooted($expected.executable)){$match=$match -and ($exe -ieq $expected.executable)};$cmd=[string]$_.CommandLine;$tail=[string]$expected.tail;if($tail.Length){$suffix=" "+$tail;$match=$match -and $cmd.EndsWith($suffix,[StringComparison]::Ordinal);if($match){$cmd=$cmd.Substring(0,$cmd.Length-$suffix.Length)}};$prefix=$cmd.Trim();$match -and ($prefix -eq $exe -or $prefix -eq (\'"\'+$exe+\'"\'))});if($children.Count -ne 1){throw "The exact configured provider argv is not uniquely associated with the terminal"};$p=$children[0]'
 end
 local script='$ErrorActionPreference="Stop";'..setup..'$r=Get-Process -Id '..string.format('%.0f',root)..';'..select..';$c=Get-Process -Id $p.ProcessId;$cursor='..string.format('%.0f',foreground)..';$associated=$false;for($i=0;$i -lt 64;$i++){if($cursor -eq $c.Id){$associated=$true;break};if($cursor -eq $r.Id -or $cursor -lt 1){break};$ancestor=Get-CimInstance Win32_Process -Filter ("ProcessId = "+$cursor);if(!$ancestor -or $ancestor.ParentProcessId -eq $cursor){break};$cursor=[long]$ancestor.ParentProcessId};if(!$associated){throw "Current native foreground is unrelated to the retained provider"};[Console]::Write((@{root_pid=$r.Id;root_identity=([string]$r.Id+":"+$r.StartTime.ToUniversalTime().Ticks);provider_pid=$c.Id;provider_identity=([string]$c.Id+":"+$c.StartTime.ToUniversalTime().Ticks)}|ConvertTo-Json -Compress))'
 local ok,why=pcall(tern.process.run,{'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',tern.base64.encode(assert(Backend.utf16le(script)))},{stdin=stdin,timeout_ms=5000},function(result)
  if result.timed_out or result.status~=0 or type(result.stdout)~='string' or #result.stdout>4096 then done(nil,'Windows process creation/parent observation is unavailable');return end
  local decoded,value=pcall(tern.json.decode,result.stdout)
  if not decoded or not closed(value,{root_pid=true,root_identity=true,provider_pid=true,provider_identity=true}) or value.root_pid~=root or not integer(value.provider_pid) or not text(value.root_identity,256) or not text(value.provider_identity,256) then done(nil,'Windows process identity response is invalid');return end
  done(value,nil)
 end)
 if not ok then done(nil,tostring(why):sub(1,512)) end
end
local MAC_SETUP='Automatic macOS terminal continuation requires detected Python 3 with standard-library ctypes and native libproc access on this execution host. Install Python 3 through your approved macOS installer if absent, then use SPAWN → Required resources and capabilities → Check terminal continuation capability. SPAWN does not install it; standalone launch and native OMP do not require it.'
local function macos(request,done)
 local capability=request==nil
 local argv={'python3',tern.plugin.dir..'/macos_process.py'}
 if capability then table.insert(argv,'capability') end
 local ok,why=pcall(tern.process.run,argv,{stdin=if request then tern.json.encode(request) else '',timeout_ms=5000},function(result)
  if result.timed_out or result.status~=0 or type(result.stdout)~='string' or #result.stdout>4096 then done(nil,MAC_SETUP..' Observation: '..tostring(result.stderr or 'native process observer failed'):sub(1,512));return end
  local decoded,value=pcall(tern.json.decode,result.stdout)
  if not decoded or type(value)~='table' then done(nil,'The macOS process observer returned an invalid bounded result');return end
  done(value,nil)
 end)
 if not ok then done(nil,MAC_SETUP..' Observation: '..tostring(why):sub(1,512)) end
end
function M.capability(done)
 if tern.runtime.os~='macos' then done(false,'The Python/libproc continuation capability is only needed for macOS terminal workers');return end
 macos(nil,function(value,why)
  local available=closed(value,{available=true,abi_bytes=true}) and value.available==true and value.abi_bytes==136
  done(available,if available then 'Python 3 ctypes and a complete matching native libproc process record were observed. This is capability support, not provider/conversation qualification.' else why or MAC_SETUP)
 end)
end
function M.capture(route,session,expected,done)
 if tern.runtime.os~='linux' and tern.runtime.os~='windows' and tern.runtime.os~='macos' then done(nil,'This host has no implemented exact terminal process-creation observer');return end
 process(route,session,function(value,problem)
  if not value then done(nil,problem);return end
  if tern.runtime.os=='macos' then
   local foreground=type(value.foreground)=='table' and value.foreground.pid or nil
   if not integer(foreground) then done(nil,'Current native macOS foreground process association is unavailable');return end
   macos({mode='capture',root_pid=value.child.pid,foreground_pid=foreground,expected=expected},function(proof,why)
    if not proof then done(nil,why);return end
    proof.platform='macos';proof.route=route;proof.session=session
    if not M.valid(proof) then done(nil,'The native macOS process proof is malformed');return end
    done(proof,nil)
   end);return
  end
  if tern.runtime.os=='windows' then
   windows(value.child.pid,nil,expected,type(value.foreground)=='table' and value.foreground.pid or nil,function(proof,why)
    if not proof then done(nil,why);return end
    proof.platform='windows';proof.route=route;proof.session=session;done(proof,nil)
   end);return
  end
  local root=linux(value.child.pid)
  if not root or root.tty=='0' then done(nil,'The original terminal root has no verifiable live controlling tty');return end
  local provider=nil
  local foreground=type(value.foreground)=='table' and value.foreground.pid or nil
  local candidate=if integer(foreground) then foreground else value.child.pid
  for _=1,64 do
   local matches=invocation(candidate,expected)
   if matches then provider=candidate end
   if candidate==value.child.pid then break end
   local state=linux(candidate)
   if not state or not state.parent or state.parent<1 or state.parent==candidate then break end
   candidate=state.parent
  end
  if candidate~=value.child.pid or not provider then done(nil,'The exact configured provider argv is not associated with the native foreground process ancestry');return end
  local state=linux(provider)
  if not state or state.tty~=root.tty or state.session~=root.session or state.group~=state.foreground then done(nil,'The provider is not associated with the original foreground tty');return end
  local _,root_hash=argv(value.child.pid);local _,provider_hash=argv(provider)
  if not root_hash or not provider_hash then done(nil,'Terminal process argv could not be retained completely');return end
  done({platform='linux',session=session,route=route,root_pid=value.child.pid,root_identity=root.identity,provider_pid=provider,provider_identity=state.identity,tty=state.tty,group=state.group,process_session=state.session,root_argv_sha256=root_hash,provider_argv_sha256=provider_hash},nil)
 end)
end
-- Positive process liveness for Forget. 'gone' only when the retained identity (boot id, pid and start time) is positively not
-- running; 'alive' when it still is; anything else (unreadable /proc, another platform, a malformed proof) is 'unknown' and is never
-- evidence of absence. Linux reads /proc synchronously; other platforms are not implemented here and stay 'unknown'.
local function proc_state(pid,identity)
 if not integer(pid) or type(identity)~='string' then return 'unknown' end
 local path='/proc/'..string.format('%.0f',pid)..'/stat'
 local exists_ok,exists=pcall(tern.fs.exists,path)
 if not exists_ok then return 'unknown' end
 if not exists then
  -- A missing entry proves absence only while /proc itself is readable and this is the same boot.
  local boot_ok,boot=pcall(tern.fs.read,'/proc/sys/kernel/random/boot_id',128)
  if not boot_ok or type(boot)~='string' then return 'unknown' end
  return 'gone'
 end
 local current=linux(pid)
 if current==nil then
  -- Present but unparsable: a zombie or exited process reads as nil; an unreadable one is unknown.
  local ok,bytes=pcall(tern.fs.read,path,16384)
  if not ok or type(bytes)~='string' then return 'unknown' end
  local state=bytes:match('^%d+ %(.+%) (%a)')
  if state=='Z' or state=='X' then return 'gone' end
  return 'unknown'
 end
 return if current.identity==identity then 'alive' else 'gone'
end
function M.liveness(proof,done)
 if not M.valid(proof) or proof.platform~=tern.runtime.os or proof.platform~='linux' then done('unknown');return end
 local root=proc_state(proof.root_pid,proof.root_identity)
 local provider=proc_state(proof.provider_pid,proof.provider_identity)
 if root=='alive' or provider=='alive' then done('alive');return end
 if root=='gone' and provider=='gone' then done('gone');return end
 done('unknown')
end
function M.verify(proof,done)
 if not M.valid(proof) or proof.platform~=tern.runtime.os then done(false,'No exact retained terminal process proof is available on this host');return end
 process(proof.route,proof.session,function(value,problem)
  if not value or value.child.pid~=proof.root_pid then done(false,problem or 'The original native pane now has a different root process');return end
  if proof.platform=='macos' then
   local foreground=type(value.foreground)=='table' and value.foreground.pid or nil
   if not integer(foreground) then done(false,'Current native macOS foreground association is unavailable');return end
   macos({mode='verify',root_pid=proof.root_pid,foreground_pid=foreground,proof=proof},function(current,why)
    done(closed(current,{verified=true}) and current.verified==true,why or 'The retained macOS process/foreground proof is no longer current')
   end);return
  end
  if proof.platform=='windows' then
   windows(proof.root_pid,proof.provider_pid,nil,type(value.foreground)=='table' and value.foreground.pid or nil,function(current,why)
    done(current~=nil and current.root_identity==proof.root_identity and current.provider_identity==proof.provider_identity,why or 'The retained Windows provider process identity changed')
   end);return
  end
  local root=linux(proof.root_pid);local provider=linux(proof.provider_pid)
  if not root or not provider or root.identity~=proof.root_identity or provider.identity~=proof.provider_identity or root.tty~=proof.tty or provider.tty~=proof.tty or provider.session~=proof.process_session or provider.group~=proof.group or provider.foreground~=proof.group then done(false,'The exact retained provider/root process or foreground tty association is not current');return end
  local _,root_hash=argv(proof.root_pid);local _,provider_hash=argv(proof.provider_pid)
  if root_hash~=proof.root_argv_sha256 or provider_hash~=proof.provider_argv_sha256 then done(false,'The retained terminal/provider exec image or argv changed');return end
  local foreground=type(value.foreground)=='table' and value.foreground.pid or nil
  if not integer(foreground) then done(false,'Current native foreground association is unavailable');return end
  local current=foreground;local associated=false
  for _=1,64 do
   if current==proof.provider_pid then associated=true;break end
   local state=linux(current)
   if not state or not state.parent or state.parent<1 or current==proof.root_pid or state.parent==current then break end
   current=state.parent
  end
  if not associated then done(false,'The current native foreground belongs to another process, not the retained provider');return end
  local candidate=proof.provider_pid
  for _=1,64 do
   if candidate==proof.root_pid then done(true,nil);return end
   local state=linux(candidate)
   if not state or not state.parent or state.parent<1 or state.parent==candidate then break end
   candidate=state.parent
  end
  done(false,'The retained provider is no longer descended from its original native terminal root')
 end)
end
return M
