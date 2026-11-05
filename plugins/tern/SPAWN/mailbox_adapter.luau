-- Fixed helper protocol. Helpers are reviewed package assets installed explicitly
-- on the target; public requests cannot choose helper, root, shell or SSH options.
local Backend = require('./backend')
local Codec = require('./codec')
local Capabilities = require('./mailbox_capabilities')
local M = {}
local active = {}
local running = 0
local assembly_reserved = 0
local function rejected(code) return {status='rejected',error={code=code}} end
local function absolute(path,windows)
 if type(path)~='string' or #path==0 or #path>4096 or path:find('[%z\r\n]') then return false end
 if path:find('..',1,true) then return false end
 return if windows then path:match('^[A-Za-z]:[\\/]')~=nil else path:sub(1,1)=='/'
end
function M.validate_target(t)
 if type(t)~='table' then return false end
 local fields={root=true,helper=true,producer_helper=true,worker_identity=true,os=true,shell=true,kind=true,backend=true,host=true,user=true,key_path=true,host_os=true,host_shell=true}
 for key in pairs(t) do if not fields[key] then return false end end
 if t.backend~='native-agent' and t.backend~='local-terminal' and t.backend~='ssh-command' then return false end
 if not absolute(t.root,t.os=='windows') or not absolute(t.helper,t.os=='windows') or not absolute(t.producer_helper,t.os=='windows') or Backend.shell_kind(t.os,t.shell)~=t.kind or (t.kind~='posix' and t.kind~='powershell') or not Backend.shell_kind(t.host_os,t.host_shell) then return false end
 if type(t.worker_identity)~='string' or #t.worker_identity==0 or #t.worker_identity>256 or t.worker_identity:find('[%z\r\n]') then return false end
 for _,key in ipairs({'host','user','key_path'}) do if t[key]~=nil and (type(t[key])~='string' or #t[key]>4096 or t[key]:find('[%z\r\n]')) then return false end end
 if t.backend=='ssh-command' then
  if not Backend.ssh_arguments(t,'true',false) then return false end
 elseif t.os~=t.host_os or t.os=='windows' and t.user and t.user~='' then return false end
 return true
end
function M.target(record,context)
 if record.backend=='ssh-command' then return nil,'unsupported_capability' end
 local cfg=record.mailbox
 if not Capabilities.validate(record) then return nil,'unsupported_capability' end
 local os=context.host_os
 local shell=context.host_shell
 local kind=Backend.shell_kind(os,shell)
 if not kind or not absolute(cfg.permitted_root,os=='windows') or not absolute(cfg.helper_path,os=='windows') or type(cfg.worker_identity)~='string' or cfg.worker_identity=='' or #cfg.worker_identity>256 or cfg.worker_identity:find('[%z\r\n]') then return nil,'unsupported_capability' end
 if os=='windows' and record.user and record.user~='' then return nil,'unsupported_capability' end
 local target={root=cfg.permitted_root,helper=cfg.helper_path,producer_helper=cfg.producer_helper_path,worker_identity=cfg.worker_identity,os=os,shell=shell,kind=kind,backend=record.backend,host=record.host,user=record.user,key_path=record.key_path,host_os=context.host_os,host_shell=context.host_shell}
 if not M.validate_target(target) then return nil,'unsupported_capability' end
 return target,nil
end
local function process_argv(op,mode,path)
 local t=op.target
 local executable=if t.kind=='powershell' then 'powershell.exe' else 'sh'
 local producer=mode=='retire_producer'
 local helper=if producer then t.producer_helper else t.helper
 local values,names
 if producer then
  local binding={}
  for _,key in ipairs({'logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token','mailbox_handle'}) do binding[key]=op.binding[key] end
  local expected=tern.json.encode(binding)
  if #expected>2048 then return nil,'oversize' end
  values={t.root,op.handle,op.binding.enrolment_token,'retire-authorized',string.format('%.0f',op.report_floor),string.format('%.0f',op.reply_floor),op.request.report_chain_sha256,tern.base64.encode(expected)}
  names={'Root','Handle','Owner','Mode','ReportFloor','ReplyFloor','ReceiptChain','ExpectedBinding'}
 else
  values={t.root,op.handle,mode,path or '-',op.id,t.worker_identity,string.format('%.0f',op.report_floor or 0),string.format('%.0f',op.reply_floor or 0),t.producer_helper}
  names={'Root','Handle','Mode','Selected','Operation','Identity','ReportFloor','ReplyFloor','ProducerHelper'}
 end
 local args={helper}
 if t.kind=='powershell' then
  args={'-NoLogo','-NoProfile','-NonInteractive','-File',helper}
  -- Colon-ended names preserve literal hyphens and avoid boolean coercion.
  for index,value in ipairs(values) do table.insert(args,'-'..names[index]..':');table.insert(args,value) end
 elseif producer then
  args={helper,t.root,op.handle,op.binding.enrolment_token,'retire-authorized','','5','30',values[5],values[6],values[7],values[8]}
 else
  for _,value in ipairs(values) do table.insert(args,value) end
 end
 if t.backend=='ssh-command' then
  local remote,why=Backend.serialize(executable,args,t.root,t.os,t.shell,t.kind=='powershell')
  if not remote then return nil,why end
  local ssh,err=Backend.ssh_arguments(t,remote,false)
  if not ssh then return nil,err end
  for index,value in ipairs({'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes'}) do table.insert(ssh,index,value) end
  table.insert(ssh,1,'ssh')
  local total=0; for _,v in ipairs(ssh) do total+=#v+1 end
  if total>(if t.host_os=='windows' then 7000 else 32768) then return nil,'oversize' end
  return ssh,nil
 end
 local argv={executable}; for _,v in ipairs(args) do table.insert(argv,v) end
 if t.user and t.user~='' then
  local sudo={'sudo','-n','-u',t.user,'--'}; for _,v in ipairs(argv) do table.insert(sudo,v) end; argv=sudo
 end
 local total=0; for _,v in ipairs(argv) do total+=#v+1 end
 if total>(if t.os=='windows' then 7000 else 32768) then return nil,'oversize' end
 return argv,nil
end
-- One overall deadline, including up to 32 chunk reads before a manifest. The
-- target helper never emits more than one bounded object; stderr is not exposed.
-- The deadline measures awake progress: a watchdog ticks every WATCH_MS and a gap far
-- beyond that between observations (host sleep, App Nap, a paused hook) counts as one
-- nominal tick. A child spanning a suspension is therefore not declared uncertain because
-- wall time passed; a child that process.run itself timed out stays uncertain.
local DEADLINE_MS=30000
local WATCH_MS=1000
local SUSPENSION_GAP_MS=5000
function M.execute(op,callback)
 -- SSH support below exists only to inspect retained generations, not orchestrate.
 if op.target.backend=='ssh-command' and op.mode~='read' and not op.reconcile then
  callback({status='rejected',error={code='unsupported_capability',message='SSH-managed writes are held; run ORCH+ on target host and settle existing effects with the original build before cutover'}});return
 end
 if active[op.handle] then callback({status='full',resource='generation_executor',current=1,limit=1});return end
 if running>=4 then callback({status='full',resource='executor',current=running,limit=4});return end
 active[op.handle]=op.id; running+=1
 local awake,last=0,tern.now()
 local finished=false
 local reservation=0
 local retirement_started=false
 local deadline
 local function progress()
  local now=tern.now(); local gap=now-last; last=now
  if gap>SUSPENSION_GAP_MS then awake+=WATCH_MS elseif gap>0 then awake+=gap end
 end
 local function done(result)
  if finished then return end
  finished=true; active[op.handle]=nil; running-=1
  assembly_reserved-=reservation; reservation=0
  if deadline then deadline:cancel() end
  callback(result)
 end
 local function watch()
  deadline=tern.timer(WATCH_MS,function()
   deadline=nil
   if finished then return end
   progress()
   if awake>=DEADLINE_MS then done({status='uncertain'}) else watch() end
  end)
 end
 watch()
 local function invoke(mode,path,bytes,receive)
  if finished then return end
  progress()
  local remaining=DEADLINE_MS-math.floor(awake)
  if remaining<=0 then done({status='uncertain'}); return end
  local argv,why=process_argv(op,mode,path)
  if not argv then done(rejected(if why=='oversize' then why else 'unsupported_capability')); return end
  local ok=pcall(function()
   tern.process.run(argv,{stdin=if bytes then tern.base64.encode(bytes)..'\n' else '',timeout_ms=remaining},function(result)
    if finished then return end
    if result.timed_out or result.status~=0 or type(result.stdout)~='string' or #result.stdout>6000 then done({status='uncertain'}); return end
    local status,payload=result.stdout:match('^([a-z_]+)\n(.*)$')
    if not status then done({status='uncertain'}); return end
    if status=='missing' or status=='incomplete' then receive({status=status}); return end
    if status=='full' or status=='admission_full' then
     local resource,current_text,limit_text=payload:match('^([A-Za-z0-9_-]+)\n(%d+)\n(%d+)\n$')
     local current,limit=tonumber(current_text),tonumber(limit_text)
     if not resource or #resource>96 or not current or not limit or current<0 or limit<1 or current>9007199254740991 or limit>9007199254740991 or string.format('%.0f',current)~=current_text or string.format('%.0f',limit)~=limit_text then done({status='uncertain'});return end
     if status=='admission_full' then
      if retirement_started or resource~='capacity_admission' or current~=1 or limit~=1 or op.reconcile or op.mode=='provision' or (mode~='read' and mode~='publish' and mode~='compact' and mode~='retire') then receive({status='uncertain'});return end
      receive({status='full',resource=resource,current=current,limit=limit,admission_refused=true});return
     end
     receive({status='full',resource=resource,current=current,limit=limit});return
    end
    if status=='storage_error' then done({status='uncertain'}); return end
    if status=='content_conflict' or status=='binding_mismatch' or status=='journal_corrupt' then done(rejected(status)); return end
    if status=='object' then
     local selector
     if path=='watermarks' then
      local seq,rest=payload:match('^(%d+)\n(.*)$'); local n=tonumber(seq)
      if not n or n<1 or n>9007199254740991 or string.format('%.0f',n)~=seq then done(rejected('invalid_schema')); return end
      selector={stream='watermark',through_seq=n}; payload=rest
     end
     payload=payload:gsub('\n$','')
     if #payload>5464 or #payload%4~=0 or not payload:match('^[A-Za-z0-9+/]*=?=?$') then done(rejected('invalid_schema')); return end
     local decoded,raw=pcall(tern.base64.decode,payload)
     if not decoded or #raw>4096 or tern.base64.encode(raw)~=payload then done(rejected('invalid_schema')); return end
     receive({status='object',bytes=raw,selector=selector}); return
    end
    if mode=='retire_producer' then
     if status=='producer_retired' and payload=='' then receive({status=status}) else done({status='uncertain'}) end
     return
    end
    if payload~='' or (status~='published' and status~='already_published' and status~='provisioned' and status~='compacted' and status~='retired') then done({status='uncertain'}); return end
    receive({status=status})
   end)
  end)
  if not ok then done({status='uncertain'}) end
 end
 local function verify_manifest(manifest_bytes,manifest,after)
  -- Reserve slices plus the final contiguous logical string, not just retained
  -- pool bytes. Four small messages or fewer large ones fit the same ceiling.
  reservation=manifest.message_bytes*2
  if assembly_reserved+reservation>262144 then reservation=0; done({status='full',resource='reassembly_bytes',current=assembly_reserved,limit=262144}); return end
  assembly_reserved+=reservation
  local pool=Codec.new_reassembler()
  local begin,why=Codec.begin_assembly(pool,manifest_bytes,op.binding,Codec.sha256(manifest_bytes))
  if not begin then done(rejected(why.code)); return end
  local index=1
  local function step()
   invoke('read',(if manifest.direction=='reply' then 'replies/' else 'reports/')..string.format('%.0f',manifest.slot)..'/chunk-'..index..'.json',nil,function(result)
    if result.status~='object' then done(if result.admission_refused or result.status=='uncertain' then result else {status='incomplete'}); return end
    local value,problem=Codec.push_chunk(pool,result.bytes,op.binding,Codec.sha256(result.bytes))
    if not value then done(rejected(problem.code)); return end
    if value.complete then
     if op.kind=='mailbox_publish_reply' and (value.envelope.action_revision~=op.request.action_revision or value.envelope.message_id~=op.request.message_id) then done(rejected('binding_mismatch')); return end
     after(); return
    end
    index+=1; step()
   end)
  end
  step()
 end
 if op.mode=='read' then
  invoke('read',op.path,nil,function(result)
   if result.status~='object' then done(result); return end
   local selected=op.request.selector
   local object,why=Codec.decode_object(result.bytes)
   if not object then done(rejected(why.code)); return end
   local page=Codec.project_page(result.bytes,selected)
   if not page then done(rejected('binding_mismatch')); return end
   if selected.stream=='watermark' then
    local watermark=Codec.decode_watermark(result.bytes,op.binding)
    if not watermark or result.selector and watermark.through_seq~=result.selector.through_seq then done(rejected('binding_mismatch')); return end
   elseif selected.stream=='ack' then
    local expected=table.clone(op.binding)
    expected.seq=object.seq; expected.event_id=object.event_id; expected.event_sha256=object.event_sha256
    if not Codec.decode_ack(result.bytes,expected) or object.event_id~=Codec.sha256(op.handle..':report:'..string.format('%.0f',object.seq)) then done(rejected('binding_mismatch')); return end
   elseif selected.stream=='report' or selected.stream=='reply' then
    if object.mailbox_handle~=op.handle then done(rejected('binding_mismatch')); return end
   end
   local function returned() done({status='read',payload=tern.json.decode(page)}) end
   if object.type=='manifest' then verify_manifest(result.bytes,object,returned) else returned() end
  end)
 elseif op.mode=='publish' then
  local function publish()
   invoke(if op.reconcile then 'reconcile' else 'publish',op.path,op.bytes,function(result)
    -- Readback first. A proven-absent final object is republished with the exact same
    -- immutable bytes: the helper's no-clobber link returns already_published for equal
    -- bytes and a late earlier child can only publish those same bytes, so this cannot
    -- conflict or duplicate. Legacy SSH generations stay readback-only.
    if op.reconcile and result.status=='missing' and op.target.backend~='ssh-command' then invoke('publish',op.path,op.bytes,done)
    elseif op.reconcile and result.status=='missing' then done({status='uncertain'}) else done(result) end
   end)
  end
  if op.object and op.object.type=='manifest' then verify_manifest(op.bytes,op.object,publish) else publish() end
 elseif op.mode=='provision' then
  invoke(if op.reconcile then 'reconcile_provision' else 'provision',op.path,op.bytes,function(result)
   if op.reconcile and result.status=='missing' then done({status='uncertain'}) else done(result) end
  end)
 elseif op.mode=='retire' and op.retire_producer==true and not op.reconcile then
  -- This private flag is derived by dispatch from committed exact native stop,
  -- never from public request fields. One operation/deadline spans both children.
  retirement_started=true
  invoke('retire_producer','-',nil,function(result)
   if result.status~='producer_retired' then done({status='uncertain'});return end
   invoke('retire','-',nil,function(retired) done(retired) end)
  end)
 else
  invoke(if op.reconcile then 'reconcile_'..op.mode else op.mode,'-',nil,function(result)
   if op.reconcile and result.status~='compacted' and result.status~='retired' then done({status='uncertain'}) else done(result) end
  end)
 end
end
return M
