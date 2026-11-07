-- Host-side observations only: no configuration/KV writes and no provider task launch.
local Backend = require('./backend')
local Codec = require('./wire/codec')
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
 local out={'sudo','-n','-u',user,'--'};for _,v in ipairs(argv) do table.insert(out,v) end;return out
end
M.run=run
M.as_user=as_user
function M.identity(user,done)
 local windows=tern.runtime.os=='windows'
 if windows and user and user~='' then done(nil,'Windows cross-user execution is unsupported');return end
 run(if windows then {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command','[Security.Principal.WindowsIdentity]::GetCurrent().Name'} else as_user({'id','-un'},user),nil,function(bytes,why)
  local identity=bytes and bytes:gsub('[\r\n]+$','')
  if not identity or identity=='' or #identity>256 or identity:find('%c') then done(nil,why or 'Actual execution identity is unavailable');return end
  done(identity,nil)
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
 local plan,why=Backend.build(record,context,{fresh=true,prompt='SPAWN argv probe: "quoted" \\ Unicode Ω',cwd=record.cwd,placement='tab'})
 if not observe('launch-construction',plan~=nil,why or (record.backend..' on '..context.host_os..'; launch construction accepted, not execution of the configured CLI or validation of its flags')) then finish();return end
 local executable=record.fresh_executable or 'omp'
 local command
 if windows then
  local data=tern.base64.encode(tern.json.encode({executable=executable,cwd=record.cwd,identity=record.mailbox.worker_identity}))
  command="$ErrorActionPreference='Stop';$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"..data.."'))|ConvertFrom-Json;if([Security.Principal.WindowsIdentity]::GetCurrent().Name -ne $d.identity){throw 'Identity differs'};if(!(Test-Path -LiteralPath $d.cwd -PathType Container)){throw 'Repository inaccessible'};$c=Get-Command -Name ([Management.Automation.WildcardPattern]::Escape($d.executable)) -CommandType Application -ErrorAction Stop;if([IO.Path]::GetExtension($c.Source) -ne '.exe'){throw 'A native CRT .exe is required'};git -C $d.cwd rev-parse --show-toplevel;if($LASTEXITCODE -ne 0){throw 'Repository is inaccessible or untrusted'};Write-Output 'prerequisites-passed'"
 else
  command='set -eu; [ "$(id -un)" = "$1" ]; test -x "$(command -v "$2")"; test -d "$3"; git -C "$3" rev-parse --show-toplevel; for tool in sh git jq awk iconv base64; do command -v "$tool" >/dev/null; done; command -v sha256sum >/dev/null || command -v shasum >/dev/null; printf "prerequisites-passed\\n"'
 end
 local argv=if windows then {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',tern.base64.encode(assert(Backend.utf16le(command)))} else as_user({'sh','-c',command,'spawn-prereq',record.mailbox.worker_identity,executable,record.cwd},record.user)
 run(argv,nil,function(bytes,err)
  if not observe('account-cli-repository-dependencies',bytes~=nil and bytes:find('prerequisites-passed',1,true)~=nil,err or bytes or 'Prerequisites failed') then finish();return end
  local sentinel='SPAWN literal argv "quote" \\ Ω'
  local probe_helper=record.mailbox.helper_path:gsub('mailbox_target%.ps1$','setup_argv.ps1')
  local probe_command,serialize_error=Backend.serialize(if windows then 'powershell.exe' else 'printf',if windows then {'-NoLogo','-NoProfile','-NonInteractive','-File',probe_helper,'-Value:',sentinel} else {'%s',sentinel},nil,context.host_os,context.host_shell,windows)
  if not probe_command then observe('argv',false,serialize_error);finish();return end
  local check=if windows then {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-Command',probe_command} else as_user({'sh','-c',probe_command},record.user)
  run(check,nil,function(output,problem)
   if not observe('serializer-argv',output==(if windows then tern.base64.encode(sentinel) else sentinel),problem or 'Harmless argv echo round-tripped the production serializer. The configured CLI flags, fresh-session behavior and native startup body were not executed; independently verify and attest those before saving.') then finish();return end
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
