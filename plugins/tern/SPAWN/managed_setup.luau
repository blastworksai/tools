-- Native setup drafts are disposable; Authority remains the only settings writer.
local Config=require('./config')
local Codec=require('./wire/codec')
local Backend=require('./backend')
local Prereq=require('./prereq')
local Adapter=require('./mailbox_adapter')
local Native=require('./native_cli')
local M={}
local sequence=0
local ASSETS={'mailbox_target.sh','mailbox_worker.sh','mailbox_json.awk','mailbox_reply.jq','mailbox_target.ps1','mailbox_worker.ps1','setup_argv.ps1','setup_route.sh','setup_route.ps1'}
function M.defaults(cwd)
 return {id='managed-local',provider=if tern.runtime.os=='windows' then 'Local worker' else 'Native agent',account_label='Current OS account',backend=if tern.runtime.os=='windows' then 'local-terminal' else 'native-agent',executable=if tern.runtime.os=='windows' then '' else 'omp',arguments='',task_argument_index='',cwd=if Adapter.absolute_path(cwd,tern.runtime.os=='windows') then cwd else '',root=tern.plugin.data..'/managed',user=''}
end
local function ordinary_route(record,user)
 local words,why=Config.parse_arguments(record.command or 'omp')
 if not words or #words==0 then return nil,why or 'Saved ordinary command is empty' end
 local executable=table.remove(words,1)
 for _,argument in ipairs(record.arguments or {}) do table.insert(words,argument) end
 return Backend.same_host_route(executable,words,user)
end
function M.from_record(record,cwd)
 local d=M.defaults(cwd)
 d.id=record.id;d.provider=record.provider;d.account_label=record.account_label;d.backend=record.backend;d.executable=record.fresh_executable or record.command or 'omp'
 d.provider_family=record.provider_family
 d.arguments=Config.render_arguments(record.fresh_arguments or record.arguments or {});d.cwd=if record.cwd and record.cwd~='' then record.cwd else d.cwd;d.user=record.user or ''
 -- The native fresh default is deliberately independent of ordinary resume argv.
 if record.fresh_native_default then d.executable='omp';d.arguments='' end
 d.task_argument_index=if record.task_argument_index then tostring(record.task_argument_index) else ''
 if record.mailbox then d.root=record.mailbox.permitted_root end
 d.source_record=assert(Config.validate_record(record))
 if record.backend~='ssh-command' and tern.runtime.os~='windows' then
  local ordinary,why=ordinary_route(record,record.user)
  local fresh=ordinary
  if ordinary and (record.fresh_executable or record.fresh_native_default) then
   fresh,why=Backend.same_host_route(d.executable,record.fresh_arguments or {},record.user)
  end
  if not ordinary or not fresh then d.preparation_error=why
  elseif ordinary.user~=fresh.user then d.preparation_error='Fresh and ordinary routes select different OS accounts; review both saved launch contracts'
  else
   d.executable=fresh.executable;d.arguments=Config.render_arguments(fresh.arguments);d.user=fresh.user
   if record.task_argument_index then
    local slot=record.task_argument_index-fresh.removed
    if slot<1 then d.preparation_error='Task argument position targets the sudo wrapper; choose a position within the worker arguments'
    else d.task_argument_index=tostring(slot) end
   end
  end
 end
 return d
end
local SESSION_REUSE_FLAGS={['--restore']=true,['--resume']=true,['--continue']=true,['--restore-session']=true,['--resume-session']=true,['--session']=true,['--session-id']=true,['--conversation-id']=true,['--session-dir']=true}
local function fresh_route_error(arguments)
 for index,argument in ipairs(arguments) do
  local option=argument:match('^(%-%-[^=]+)=') or argument
  if SESSION_REUSE_FLAGS[option] or (index==1 and (argument=='restore' or argument=='resume' or argument=='continue')) then
   return 'Fresh native route required: '..option..' selects or reuses a conversation/session. Choose an explicit fresh executable/argument contract in Managed setup or configure a genuinely fresh Tern default; the active conversation route is preserved and no continuation flags are stripped automatically.'
  end
 end
 return nil
end
-- Adopt only a literal same-host route. Names/labels never select OS accounts.
function M.from_native(command,cwd)
 local words,why=Config.parse_arguments(command)
 if not words or #words==0 then return nil,why or 'Native command is empty' end
 local executable=table.remove(words,1)
 local route,route_error=Backend.same_host_route(executable,words,'')
 if not route then return nil,route_error end
 executable=route.executable;words=route.arguments
 local fresh_error=fresh_route_error(words)
 if fresh_error then return nil,fresh_error end
 local draft=M.defaults(cwd)
 draft.executable=executable;draft.arguments=Config.render_arguments(words);draft.user=route.user
 draft.account_label=if route.user~='' then route.user else 'Current OS account'
 return draft,nil
end
local SAFE_POSIX=[[set -eu
umask 077
p=$1
case "$p" in /*) ;; *) exit 1;; esac
case "$p" in *'/../'*|*'/./'*|*'//'*) exit 1;; esac
walk=$p
while [ "$walk" != / ]; do [ ! -L "$walk" ] || exit 1; if [ -e "$walk" ]; then [ -d "$walk" ] || exit 1; fi; walk=${walk%/*}; [ -n "$walk" ] || walk=/; done
mkdir -p -- "$p"
]]
local function directory(path,user,done)
 if not Adapter.absolute_path(path,tern.runtime.os=='windows') then done(nil,'Choose an absolute root without traversal segments or line breaks');return end
 if tern.runtime.os=='windows' then
  local q=Backend.powershell_quote(path)
  local script="$ErrorActionPreference='Stop';$p="..q..";if(![IO.Path]::IsPathRooted($p)){throw 'Absolute root required'};$w=$p;while($w){if(Test-Path -LiteralPath $w){$i=Get-Item -LiteralPath $w -Force;if(!$i.PSIsContainer -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe root ancestry'}};$w=[IO.Path]::GetDirectoryName($w)};[IO.Directory]::CreateDirectory($p)|Out-Null"
  Prereq.run({'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',tern.base64.encode((assert(Backend.utf16le(script))))},nil,done)
 else Prereq.run(Prereq.as_user({'sh','-c',SAFE_POSIX,'spawn-root',path},user),nil,done) end
end
local function bundle(base,user,done)
 local assets,parts={},{}
 local function install()
 local digest=Codec.sha256(table.concat(parts,'\n'));local root=base..'/helper-bundles/'..digest
 directory(root,user,function(_,err)
  if err then done(nil,err);return end
  local index=0
  local function step()
   index+=1;local name=ASSETS[index]
   if not name then done({root=root,digest=digest},nil);return end
   local path=root..'/'..name;local bytes=assets[name]
   -- Publish fully written bytes without replacement, then read back under the
   -- selected identity. Interrupted temporary copies never become a helper.
   local windows=tern.runtime.os=='windows'
   local argv
   if windows then
    local script="$ErrorActionPreference='Stop';$p="..Backend.powershell_quote(path)..";$b=[Convert]::FromBase64String([Console]::In.ReadToEnd());if(!(Test-Path -LiteralPath $p)){$tmp=$p+'.part.'+[Guid]::NewGuid().ToString('N');$f=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($b,0,$b.Length);$f.Flush()}finally{$f.Dispose()};try{[IO.File]::Move($tmp,$p)}catch{if(!(Test-Path -LiteralPath $p)){throw}};if(Test-Path -LiteralPath $tmp){[IO.File]::Delete($tmp)}};$i=Get-Item -LiteralPath $p -Force;if($i.PSIsContainer -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe bundle file'};[Console]::Write([Convert]::ToBase64String([IO.File]::ReadAllBytes($p)))"
    argv={'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',tern.base64.encode((assert(Backend.utf16le(script))))}
   else argv=Prereq.as_user({'sh','-c','set -eu; umask 077; [ ! -L "$1" ]; if [ ! -e "$1" ]; then tmp="$1.part.$$"; (set -C; cat > "$tmp"); ln "$tmp" "$1" || test -f "$1"; rm -- "$tmp"; fi; [ ! -L "$1" ] && [ -f "$1" ]; cat -- "$1"','spawn-bundle',path},user) end
   Prereq.run(argv,if windows then tern.base64.encode(bytes) else bytes,function(actual,write_error)
    if write_error or actual~=(if windows then tern.base64.encode(bytes) else bytes) then done(nil,'Bundle creation/readback refused; existing bytes preserved: '..tostring(write_error or path));return end
    tern.timer(1,step)
   end)
  end
  step()
 end)
 end
 local index=0
 local function collect()
  index+=1;local name=ASSETS[index]
  if not name then install();return end
  local ok,bytes=pcall(tern.fs.read,tern.plugin.dir..'/'..name,262144)
  if not ok then done(nil,'Packaged helper unavailable: '..tostring(bytes));return end
  assets[name]=bytes
  local hash=Codec.sha256_begin();Codec.sha256_feed(hash,bytes)
  local function hash_step()
   if not Codec.sha256_step(hash,128) then tern.timer(1,hash_step);return end
   table.insert(parts,name..':'..Codec.sha256_digest(hash));tern.timer(1,collect)
  end
  hash_step()
 end
 collect()
end
local EXPLICIT_INPUT={['--']=true,['-i']=true,['--prompt-interactive']=true,['-p']=true,['--print']=true,['--prompt']=true}
local function declares_interactive_input(help)
 if type(help)~='string' or #help>65536 then return false end
 for line in help:gmatch('[^\r\n]+') do
  local option=line:match('^%s*(%-%-[%w%-]+)') or line:match('^%s*%-%w,%s*(%-%-[%w%-]+)')
  if option=='--prompt-interactive' then return true end
 end
 return false
end
function M.prepare(draft,context,done)
 draft=table.clone(draft)
 local argv,why=Config.parse_arguments(draft.arguments)
 if draft.source_record and draft.source_record.id~=draft.id then done(nil,nil,'Existing stable record IDs are immutable; choose Create a new managed record');return end
 if draft.source_record and draft.source_record.fresh_native_default and (draft.source_record.model or draft.source_record.profile) then
  done(nil,nil,'Native fresh default cannot retain model/profile selectors; review an explicit fresh executable/argv contract in the full record editor');return
 end
 if not argv then done(nil,nil,why);return end
 if draft.preparation_error then done(nil,nil,draft.preparation_error);return end
 local slot=if draft.task_argument_index==nil or draft.task_argument_index=='' then #argv+1 else tonumber(draft.task_argument_index)
 if not slot or slot%1~=0 or slot<1 or slot>#argv+1 then done(nil,nil,'Task argument position must be between 1 and the argument count plus one');return end
 local ordinary
 if tern.runtime.os~='windows' and draft.backend~='ssh-command' then
  local route,route_error=Backend.same_host_route(draft.executable,argv,draft.user)
  if not route then done(nil,nil,route_error);return end
  draft.executable=route.executable;draft.user=route.user;argv=route.arguments;slot-=route.removed
  if slot<1 then done(nil,nil,'Task argument position targets the sudo wrapper; choose a position within the worker arguments');return end
  if draft.source_record and draft.source_record.backend~='ssh-command' then
   ordinary,route_error=ordinary_route(draft.source_record,draft.source_record.user)
   if not ordinary then done(nil,nil,route_error);return end
   if ordinary.removed==0 then ordinary.user=draft.user end
   if ordinary.user~=draft.user then done(nil,nil,'Fresh and ordinary routes select different OS accounts; review both saved launch contracts');return end
  end
 end
 local ordinary_argv=argv
 if draft.backend=='native-agent' then local fresh_error=fresh_route_error(argv);if fresh_error then done(nil,nil,fresh_error);return end end
 if not Adapter.absolute_path(draft.cwd,tern.runtime.os=='windows') then done(nil,nil,'Choose an accessible absolute working folder; a Git repository is not required');return end
 if draft.executable=='' then done(nil,nil,'Choose an actual worker CLI executable');return end
 draft.user=draft.user or ''
 if draft.backend~='native-agent' and draft.backend~='local-terminal' then done(nil,nil,'Choose Native OMP or local terminal; managed SSH is unsupported');return end
 if tern.runtime.os=='windows' then
  if draft.backend=='native-agent' or draft.user~='' then done(nil,nil,'Windows native OMP and cross-user workers are unsupported');return end
 end
 local function prepare_identity(identity,identity_error,account)
  if not identity then done(nil,nil,identity_error);return end
  if account then
   draft.executable=account.executable
   if draft.root==tern.plugin.data..'/managed' then draft.root=account.home..'/.local/share/tern-spawn/managed' end
  end
  bundle(if draft.user~='' then draft.root else tern.plugin.data,draft.user,function(installed,bundle_error)
   if not installed then done(nil,nil,bundle_error);return end
   directory(draft.root,draft.user,function(_,root_error)
    if root_error then done(nil,nil,root_error);return end
    local native=draft.backend=='native-agent';local windows=tern.runtime.os=='windows'
    local capabilities={'report-files-v1',if native then 'native-ask-v1' else 'worker-poll-v1','check-runner-v1','release-manager-v1'}
    if not native then table.insert(capabilities,'argv-v1') end
    table.insert(capabilities,'coordinator-control-v1')
    table.insert(capabilities,'project-start-v1')
    local record={id=draft.id,provider=draft.provider,provider_family=draft.provider_family,account_label=draft.account_label,backend=draft.backend,enabled=true,placement='tab',command=draft.executable,arguments=ordinary_argv,fresh_executable=draft.executable,fresh_arguments=argv,cwd=draft.cwd,prompt=if native then 'Follow the explicitly assigned task. Role text is guidance, not identity isolation.' else nil,user=if draft.user~='' then draft.user else nil,target_os=tern.runtime.os,host_shell=context.host_shell,task_argument_index=if native then nil else #argv+1,argv_contract=if windows then 'windows-crt' else nil,mailbox={permitted_root=draft.root,helper_path=installed.root..'/mailbox_target.'..(if windows then 'ps1' else 'sh'),producer_helper_path=installed.root..'/mailbox_worker.'..(if windows then 'ps1' else 'sh'),worker_identity=identity,verified=false,wake=if native then 'native-ask-v1' else 'worker-poll-v1',producer={read=true,write=true,hash=true,journal=true,poll=not native},capabilities=capabilities}}
    record.task_argument_index=if native then nil else slot
    if not windows and draft.executable:find('%s') then record.command=Config.render_arguments({draft.executable}) end
    if draft.source_record then
     -- Preserve selectors, capacity, ordinary launch/resume and unrelated metadata.
     -- Only the explicitly reviewed managed fields are upgraded by this wizard.
     local prior=assert(Config.validate_record(draft.source_record))
     for _,key in ipairs({'model','profile','variant_id','capacity_binding','capacity_limit','selector_evidence','placement','enabled','review_required','review_reason'}) do record[key]=prior[key] end
     -- SSH destinations/keys do not describe the explicitly selected same-host route.
     -- Existing native/local host bindings still participate in the eligibility guard.
     if prior.backend~='ssh-command' then record.host=prior.host;record.key_path=prior.key_path end
     if ordinary and ordinary.removed>0 then
      record.command=Config.render_arguments({ordinary.executable});record.arguments=ordinary.arguments
     else record.command=prior.command;record.arguments=prior.arguments end
     record.prompt=prior.prompt
    end
    local canonical,err=Config.validate_record(record)
    if not canonical then done(nil,nil,err);return end
    sequence+=1
    local probe_context={host_os=context.host_os,host_shell=context.host_shell,bundle_digest=installed.digest,provision_handle='setup-'..Codec.sha256(identity..':'..tostring(tern.now())..':'..tostring(sequence)):sub(1,40)}
    local function probe() Prereq.probe(canonical,probe_context,function(result) done(canonical,result,nil) end) end
    if native then
     directory(canonical.mailbox.permitted_root..'/'..probe_context.provision_handle..'-route-native',canonical.user,function(_,problem)
      if problem then done(nil,nil,problem);return end
      probe()
     end)
    else probe() end
   end)
  end)
 end
 local function prepare_input(identity,problem,account)
  if not identity or draft.backend~='local-terminal' or slot~=#argv+1 then prepare_identity(identity,problem,account);return end
  for _,argument in ipairs(argv) do
   if EXPLICIT_INPUT[argument:match('^(%-%-[^=]+)=') or argument] then prepare_identity(identity,problem,account);return end
  end
  local executable=if account then account.executable else draft.executable
  Prereq.run(Prereq.as_user({executable,'--help'},draft.user),nil,function(help)
   -- Only a declared option changes this inferred final task slot. Existing
   -- modes/custom positions remain explicit; help is not provider readiness.
   if declares_interactive_input(help) then argv=table.clone(argv);table.insert(argv,'--prompt-interactive');slot+=1 end
   prepare_identity(identity,problem,account)
  end)
 end
 if draft.user~='' then
  Prereq.account(draft.user,draft.executable,draft.cwd,function(account,problem)
   prepare_input(if account then account.identity else nil,problem,account)
  end)
 else Prereq.identity('',prepare_input) end
end
-- Required native route proof is separate from resource preparation and optional readiness.
function M.route(record,probe,context,revision,window,nonce)
 assert(type(nonce)=='string' and #nonce>0 and #nonce<=256 and not nonce:find('%c'),'Explicit diagnostic consent nonce required')
 local route={schema=1,nonce=nonce,config_revision=revision,window=window,record_sha256=probe.record_sha256,backend=record.backend,cwd=record.cwd,status='pending',worker_identity=record.mailbox.worker_identity,user=record.user,host_os=context.host_os}
 local sentinel='SPAWN diagnostic '..nonce..': literal "quotes" \\ Ω. Reply only READY. Do not call tools or change files.'
 if record.backend=='native-agent' then
  local candidate=assert(Config.validate_record(record))
  local fresh_error=fresh_route_error(candidate.fresh_arguments or {})
  if fresh_error then return nil,fresh_error end
  candidate.fresh_arguments=table.clone(candidate.fresh_arguments or {})
  -- Unique diagnostic storage identifies a launch even if start returns no pane.
  table.insert(candidate.fresh_arguments,'--session-dir')
  table.insert(candidate.fresh_arguments,record.mailbox.permitted_root..'/'..nonce..'-native')
  local launch,why=Backend.build(candidate,context,{fresh=true,prompt=sentinel,cwd=record.cwd,placement='tab'})
  if not launch then return nil,why end
  route.command=launch.command;route.prompt=sentinel;route.expected_arguments=candidate.fresh_arguments
 else
  route.output=record.mailbox.permitted_root..'/'..nonce..'.observation'
  route.expected=nonce..'\n'..Codec.sha256(sentinel)..'\n'..record.mailbox.worker_identity..'\n'
  local windows=context.host_os=='windows'
  local helper=record.mailbox.helper_path:gsub('mailbox_target%.ps1$','setup_route.ps1'):gsub('mailbox_target%.sh$','setup_route.sh')
  local argv=if windows then {'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-File',helper,'-Output:',route.output,'-Nonce:',nonce,'-Value:',sentinel} else Prereq.as_user({'sh',helper,route.output,nonce,sentinel},record.user)
  local executable=table.remove(argv,1)
  local command,why=Backend.serialize(executable,argv,nil,context.host_os,context.host_shell,windows)
  if not command then return nil,why end
  route.command=command
 end
 return route,nil
end
function M.observe_route(route,session,pane,done)
 if route.backend=='native-agent' then
  local function checked(child)
   local argv=if type(child)=='table' then child.argv else nil
   if type(child)~='table' or type(child.pid)~='number' or child.pid<1 or child.pid%1~=0 or child.cwd~=route.cwd then done(nil,'Native child process/cwd identity differs or is unavailable');return end
   local expected=route.expected_arguments
   if type(argv)~='table' or #argv<#expected+1 then done(nil,'Actual native child argv is unavailable or differs; no launch proof was accepted');return end
   local matches=0
   for offset=2,#argv-#expected+1 do
    local same=true
    for index,word in ipairs(expected) do if argv[offset+index-1]~=word then same=false;break end end
    if same then matches+=1 end
   end
   if matches~=1 then done(nil,'Actual native child argv does not uniquely retain the selected diagnostic argument sequence');return end
   done('Selected diagnostic argv and cwd observed in the actual native agent process; owned diagnostic cleanup separately required',nil)
  end
  Native.observe_process(route.window,session,pane,function(result,err)
   if err or not result or result.status~=0 or result.timed_out or type(result.stdout)~='string' or #result.stdout>2000000 then done(nil,err or 'Native process inspection failed or exceeded its bound');return end
   local ok,value=pcall(tern.json.decode,result.stdout)
   if not ok or type(value)~='table' or value.pane~=pane then done(nil,'Native process identity is unavailable');return end
   if route.host_os=='linux' and route.user and route.user~='' then
    local pid=if type(value.child)=='table' then value.child.pid else nil
    if type(pid)~='number' or pid<1 or pid%1~=0 then done(nil,'Native foreground process identity is unavailable');return end
    local root_identity=Native.process_identity(pid)
    if not root_identity then done(nil,'Native foreground process epoch is unavailable');return end
    Prereq.native_child(pid,route.user,root_identity,route.expected_arguments,function(child,problem)
     if not child then done(nil,problem);return end
     if child.worker_identity~=route.worker_identity or Native.process_identity(pid)~=root_identity
      or type(child.pid)~='number' or child.pid<1 or child.pid%1~=0 or Native.process_identity(child.pid)~=child.process_identity then done(nil,'Native process changed during selected-account inspection');return end
     checked(child)
    end)
   else checked(value.child) end
  end)
 else
  local argv
  if route.host_os=='windows' then
   local encoded=tern.base64.encode(route.output)
   local script="$ErrorActionPreference='Stop';[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"..encoded.."'));if(!(Test-Path -LiteralPath $p)){[Console]::Write('SPAWN_ROUTE_PENDING');exit 0};$f=Get-Item -LiteralPath $p -Force;if($f.PSIsContainer -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $f.Length -gt 1024){throw 'Unsafe or oversized observation'};try{[Console]::Write([IO.File]::ReadAllText($p,[Text.Encoding]::UTF8))}catch [IO.IOException]{$code=$_.Exception.HResult -band 65535;if($code -eq 32 -or $code -eq 33 -or $code -eq 2){[Console]::Write('SPAWN_ROUTE_PENDING')}else{throw}}"
   argv={'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',tern.base64.encode((assert(Backend.utf16le(script))))}
  else argv=Prereq.as_user({'sh','-c','set -eu; [ ! -L "$1" ]; if [ ! -e "$1" ]; then printf SPAWN_ROUTE_PENDING; exit 0; fi; [ -f "$1" ]; [ "$(wc -c < "$1")" -le 1024 ]; cat -- "$1"','spawn-route-read',route.output},route.user) end
  Prereq.run(argv,nil,function(bytes,err)
   if bytes=='SPAWN_ROUTE_PENDING' or (type(bytes)=='string' and #bytes<#route.expected and bytes==route.expected:sub(1,#bytes)) then
    done(nil,'Native terminal observation is not yet completely published',true);return
   end
   if bytes~=route.expected then done(nil,err or 'Actual native terminal literal argv/account observation differs');return end
   done('Offline native terminal creation and exact literal argv/account readback observed; configured provider CLI semantics and readiness remain unverified',nil)
  end)
 end
end
return M
