-- Host-side observations only: no configuration/KV writes and no provider task launch.
local Backend = require('./backend')
local Codec = require('./wire/codec')
local TerminalIdentity = require('./terminal_identity')
local M = {}
local function run(argv,stdin,done)
 local ok,why=pcall(tern.process.run,argv,{stdin=stdin or '',timeout_ms=15000},function(result)
  if result.timed_out or result.status~=0 then done(nil,(result.stderr or 'Process failed'):sub(1,1024));return end
  done(result.stdout,nil)
 end)
 if not ok then done(nil,tostring(why):sub(1,1024)) end
end
local function as_user(argv,user)
 if not user or user=='' then return argv end
 -- The launch route (sudo -i login shell, argv carried as encoded data): preparation sees the same PATH as the launch.
 return Backend.login_argv(user,argv)
end
M.run=run
M.as_user=as_user
-- Optional platform capability, separate from launch/helper/account readiness.
function M.terminal_continuation(done)
 TerminalIdentity.capability(done)
end
local function valid_user(user)
 return type(user)=='string' and #user>0 and #user<=256 and user:sub(1,1)~='-' and not user:find('[%s%c:/]')
end
-- Read only: prove authorized identity and resolve its home/CLI before publishing helpers.
function M.account(user,executable,cwd,done)
 if tern.runtime.os=='windows' then done(nil,'Windows cross-user execution is unsupported');return end
 if not valid_user(user) then done(nil,'Existing POSIX account name is invalid');return end
 local lookup=if tern.runtime.os=='macos' then {'dscl','.','-read','/Users/'..user,'NFSHomeDirectory'} else {'getent','passwd',user}
 run(lookup,nil,function(bytes,why)
  local name,home
  if bytes and tern.runtime.os=='macos' then name=user;home=bytes:match('^NFSHomeDirectory: ([^\r\n]+)[\r\n]*$')
  elseif bytes then name,home=bytes:match('^([^:\r\n]+):[^:\r\n]*:%d+:%d+:[^:\r\n]*:([^:\r\n]+):[^:\r\n]*[\r\n]*$') end
  if name~=user or not home or home:sub(1,1)~='/' or home:find('%c') or home:find('/%.%./') or home:find('/%./') or home:find('//',1,true) then done(nil,'Selected existing POSIX account/home unavailable: '..tostring(why or user));return end
  local script='set -eu; [ "$(id -un)" = "$1" ] || { printf "Selected identity differs\\n" >&2; exit 1; }; [ "$HOME" = "$2" ] || { printf "Selected HOME differs\\n" >&2; exit 1; }; test -d "$HOME"; test -x "$HOME"; command=$3; case "$command" in */*) ;; *) command=$(command -v "$command" || true); if [ -z "$command" ]; then for bin in "$HOME/.local/bin" "$HOME/bin"; do if [ -f "$bin/$3" ] && [ -x "$bin/$3" ]; then command="$bin/$3"; break; fi; done; fi;; esac; case "$command" in /*) ;; *) printf "Selected account executable unavailable\\n" >&2; exit 1;; esac; test -f "$command"; test -x "$command"; test -d "$4"; test -r "$4"; test -x "$4"; for tool in sh git jq awk iconv base64; do command -v "$tool" >/dev/null || { printf "Missing prerequisite: %s\\n" "$tool" >&2; exit 1; }; done; command -v sha256sum >/dev/null || command -v shasum >/dev/null; printf "%s\\n%s\\n%s\\n" "$(id -un)" "$HOME" "$command"'
  run(as_user({'sh','-c',script,'spawn-account',user,home,executable,cwd},user),nil,function(actual,problem)
   local identity,observed_home,path
   if actual then identity,observed_home,path=actual:match('^([^\r\n]+)\n([^\r\n]+)\n([^\r\n]+)\n$') end
   if identity~=user or observed_home~=home or not path or path:sub(1,1)~='/' then done(nil,'Selected-account prerequisite failed (existing noninteractive sudo authorization, identity, home, executable, working folder and helper tools required): '..tostring(problem or 'Invalid account observation'));return end
   done({identity=identity,home=home,executable=path},nil)
  end)
 end)
end
function M.identity(user,done)
 local windows=tern.runtime.os=='windows'
 if windows and user and user~='' then done(nil,'Windows cross-user execution is unsupported');return end
 if not windows and user and user~='' and not valid_user(user) then done(nil,'Existing POSIX account name is invalid');return end
 run(if windows then {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command',"[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);[Console]::Write([Security.Principal.WindowsIdentity]::GetCurrent().Name)"} else as_user({'id','-un'},user),nil,function(bytes,why)
  local identity=bytes and bytes:gsub('[\r\n]+$','')
  if not identity or identity=='' or #identity>256 or identity:find('%c') then done(nil,why or 'Actual execution identity is unavailable');return end
  if user and user~='' and identity~=user then done(nil,'Selected execution identity differs; no current-user fallback');return end
  done(identity,nil)
 end)
end
-- sudo remains the native foreground process. Inspect only its selected-account
-- descendants; reading another UID's /proc cwd from the daemon is not proof.
local NATIVE_CHILD_SCRIPT=[=[
set -eu
root=$1; identity=$2; root_identity=$3; expected=$4
[ "$(id -un)" = "$identity" ] || { printf 'Selected native process account differs\n' >&2; exit 1; }
uid=$(id -u)
meta() {
 awk '{ sub(/^[0-9]+ \(.+\) /,""); if(NF<20 || $2 !~ /^[0-9]+$/ || $20 !~ /^[0-9]+$/)exit 1; print $2 " " $20 }' "/proc/$1/stat" 2>/dev/null
}
root_meta=$(meta "$root") || { printf 'Native foreground process is unavailable\n' >&2; exit 1; }
root_start=${root_meta#* }
boot=$(cat /proc/sys/kernel/random/boot_id)
[ "$boot:$root:$root_start" = "$root_identity" ] || { printf 'Native foreground process changed before inspection\n' >&2; exit 1; }
chain() {
 cursor=$1; depth=0; result=
 while [ "$cursor" -gt 0 ] && [ "$depth" -lt 32 ]; do
  row=$(meta "$cursor") || return 1
  parent=${row% *}; started=${row#* }
  result="$result$cursor:$started;"
  if [ "$cursor" = "$root" ]; then [ "$started" = "$root_start" ] || return 1; printf '%s' "$result"; return 0; fi
  cursor=$parent; depth=$((depth+1))
 done
 return 1
}
queue=$root; seen=' '; count=0; tasks=0; matches=0
while [ -n "$queue" ]; do
 set -- $queue; pid=$1; shift; queue="$*"
 case "$seen" in *" $pid "*) continue;; esac
 seen="$seen$pid "
 count=$((count+1)); [ "$count" -le 256 ] || { printf 'Native process tree bound exceeded\n' >&2; exit 1; }
 for children_file in /proc/"$pid"/task/*/children; do
  [ -f "$children_file" ] || continue
  tasks=$((tasks+1)); [ "$tasks" -le 1024 ] || { printf 'Native process task bound exceeded\n' >&2; exit 1; }
  if children=$(cat "$children_file"); then
   for child in $children; do
    case "$child" in ''|*[!0-9]*) printf 'Invalid native child identity\n' >&2; exit 1;; esac
    queue="$queue $child"
   done
  elif [ -f "$children_file" ]; then printf 'Native child tree is inaccessible\n' >&2; exit 1; fi
 done
 before=$(chain "$pid") || continue
 owner=$(awk '/^Uid:/ { print $2 " " $3; exit }' "/proc/$pid/status" 2>/dev/null) || continue
 [ "$owner" = "$uid $uid" ] || continue
 argv=$(jq -Rs 'split("\u0000") | if .[-1]=="" then .[:-1] else error("Incomplete argv") end' <"/proc/$pid/cmdline" 2>/dev/null) || continue
 printf '%s' "$argv" | jq -e --argjson expected "$expected" '[range(1;length-($expected|length)+1) as $i | select(.[$i:$i+($expected|length)]==$expected)] | length==1' >/dev/null || continue
 cwd=$(readlink "/proc/$pid/cwd" | jq -Rs 'if endswith("\n") then .[:-1] else error("Incomplete cwd") end') || continue
 after=$(chain "$pid") || continue
 [ "$before" = "$after" ] || continue
 child_meta=$(meta "$pid") || continue
 started=${child_meta#* }
 matches=$((matches+1)); [ "$matches" -eq 1 ] || { printf 'Native child arguments are ambiguous\n' >&2; exit 1; }
 jq -cn --argjson pid "$pid" --argjson argv "$argv" --argjson cwd "$cwd" --arg identity "$identity" --arg root_identity "$root_identity" --arg process_identity "$boot:$pid:$started" '{pid:$pid,argv:$argv,cwd:$cwd,worker_identity:$identity,root_identity:$root_identity,process_identity:$process_identity}'
done
[ "$matches" -eq 1 ] || { printf 'No unique selected-account descendant retains the native diagnostic arguments\n' >&2; exit 1; }
root_after=$(meta "$root") || { printf 'Native foreground process ended during inspection\n' >&2; exit 1; }
[ "${root_after#* }" = "$root_start" ] || { printf 'Native foreground process changed during inspection\n' >&2; exit 1; }
]=]
function M.native_child(pid,user,root_identity,expected,done)
 if tern.runtime.os~='linux' or not valid_user(user) or type(pid)~='number' or pid<1 or pid%1~=0
  or type(root_identity)~='string' or type(expected)~='table' then done(nil,'Selected-account native process observation is unavailable');return end
 run(as_user({'sh','-c',NATIVE_CHILD_SCRIPT,'spawn-native-child',string.format('%.0f',pid),user,root_identity,tern.json.encode(expected)},user),nil,function(bytes,why)
  if not bytes or #bytes>2000000 then done(nil,why or 'Native child observation exceeded its bound');return end
  local ok,value=pcall(tern.json.decode,bytes)
  if not ok or type(value)~='table' or value.worker_identity~=user or value.root_identity~=root_identity then done(nil,'Native child observation identity differs');return end
  done(value,nil)
 end)
end
function M.probe(record,context,done)
 local observations={}
 local result={schema=1,passed=false,record_sha256=Codec.sha256(tern.json.encode(record)),observations=observations,bundle_digest=context.bundle_digest,worker_identity=record.mailbox.worker_identity,provision_handle=context.provision_handle}
 local function observe(id,passed,summary)
  table.insert(observations,{id=id,state=if passed then 'passed' else 'failed',summary=tostring(summary):gsub('%c',' '):sub(1,1024)})
  return passed
 end
 local function finish() done(result) end
 local windows=context.host_os=='windows'
 if not windows and record.backend~='ssh-command' and record.user and record.user~='' and record.user~=record.mailbox.worker_identity then
  observe('execution-identity',false,'Selected OS account differs from the prepared mailbox identity; prepare a new account-bound transport')
  finish();return
 end
 local plan,why=Backend.build(record,context,{fresh=true,prompt='SPAWN argv probe: "quoted" \\ Unicode Ω',cwd=record.cwd,placement='tab'})
 if not observe('launch-construction',plan~=nil,why or (record.backend..' on '..context.host_os..'; launch construction accepted, not execution of the configured CLI or validation of its flags')) then finish();return end
 local executable=record.fresh_executable or 'omp'
 local command
 if windows then
  local data=tern.base64.encode(tern.json.encode({executable=executable,cwd=record.cwd,identity=record.mailbox.worker_identity}))
  command="$ErrorActionPreference='Stop';$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"..data.."'))|ConvertFrom-Json;if([Security.Principal.WindowsIdentity]::GetCurrent().Name -ne $d.identity){throw 'Identity differs'};if(!(Test-Path -LiteralPath $d.cwd -PathType Container)){throw 'Working folder inaccessible'};$c=Get-Command -Name ([Management.Automation.WildcardPattern]::Escape($d.executable)) -CommandType Application -ErrorAction Stop;if([IO.Path]::GetExtension($c.Source) -ne '.exe'){throw 'A native CRT .exe is required'};Get-Command git -CommandType Application -ErrorAction Stop|Out-Null;Write-Output 'prerequisites-passed'"
 else
  command='set -eu; [ "$(id -un)" = "$1" ]; test -x "$(command -v "$2")"; test -d "$3"; test -r "$3"; test -x "$3"; for tool in sh git jq awk iconv base64; do command -v "$tool" >/dev/null; done; command -v sha256sum >/dev/null || command -v shasum >/dev/null; printf "prerequisites-passed\\n"'
 end
 local argv=if windows then {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',tern.base64.encode((assert(Backend.utf16le(command))))} else as_user({'sh','-c',command,'spawn-prereq',record.mailbox.worker_identity,executable,record.cwd},record.user)
 run(argv,nil,function(bytes,err)
  if not observe('account-cli-folder-dependencies',bytes~=nil and bytes:find('prerequisites-passed',1,true)~=nil,err or bytes or 'Prerequisites failed') then finish();return end
  local sentinel='SPAWN literal argv "quote" \\ Ω'
  local probe_helper=record.mailbox.helper_path:gsub('mailbox_target%.ps1$','setup_argv.ps1')
  local probe_command,serialize_error=Backend.serialize(if windows then 'powershell.exe' else 'printf',if windows then {'-NoLogo','-NoProfile','-NonInteractive','-File',probe_helper,'-Value:',sentinel} else {'%s',sentinel},nil,context.host_os,context.host_shell,windows)
  if not probe_command then observe('argv',false,serialize_error);finish();return end
  local check=if windows then {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command',probe_command} else as_user({'sh','-c',probe_command},record.user)
  run(check,nil,function(output,problem)
   if not observe('serializer-argv',output==(if windows then tern.base64.encode(sentinel) else sentinel),problem or 'Harmless arguments round-tripped the production serializer. Custom provider flags, permissions, authentication and task readiness remain unverified.') then finish();return end
   local box=context.provision_handle
   local binding={logical_session_id=box,worker_id='setup-probe',worker_generation=1,launch_request_id=box,work_id='setup-probe',enrolment_token=Codec.sha256(box),mailbox_handle=box}
   local descriptor=tern.json.encode({version=1,handle=box,binding_digest=Codec.sha256(tern.json.encode(binding)),binding=binding,capabilities=record.mailbox.capabilities})
   local values={record.mailbox.permitted_root,box,'provision','provision.json',box,record.mailbox.worker_identity,'0','0',record.mailbox.producer_helper_path}
   local helper
   if windows then
    helper={'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-File',record.mailbox.helper_path}
    local names={'Root','Handle','Mode','Selected','Operation','Identity','ReportFloor','ReplyFloor','ProducerHelper'}
    for i,v in ipairs(values) do table.insert(helper,'-'..names[i]..':');table.insert(helper,v) end
   else helper={'sh',record.mailbox.helper_path};for _,v in ipairs(values) do table.insert(helper,v) end;helper=as_user(helper,record.user) end
   run(helper,tern.base64.encode(descriptor)..'\n',function(provisioned,provision_error)
    if not observe('helper-provision',provisioned~=nil and provisioned:gsub('\r\n','\n')=='provisioned\n',provision_error or provisioned or 'Provisioning probe failed; on Windows inspect execution policy without bypassing it') then finish();return end
    local path=record.mailbox.permitted_root..'/'..box..'/provision.json'
    local readargv=if windows then {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command',"[Console]::Write([Convert]::ToBase64String([IO.File]::ReadAllBytes("..Backend.powershell_quote(path)..")))"} else as_user({'cat',path},record.user)
    run(readargv,nil,function(actual,read_error)
     if not observe('provision-readback',actual==(if windows then tern.base64.encode(descriptor) else descriptor),read_error or 'Exact provision bytes read back under selected account; helper exclusive-create, hash and no-replace link succeeded') then finish();return end
     result.passed=true;finish()
    end)
   end)
  end)
 end)
end
return M
