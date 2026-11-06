-- Pure host-callback suite; caller supplies the staged package root. No target IO.
local root=...
assert(type(root)=='string','pass the package directory')
local runtime,environment=tern,getfenv()
local modules={}
local fake=table.clone(runtime)
local clock=0 -- Injected monotonic milliseconds; the adapter watchdog is driven explicitly.
fake.now=function() return clock end
local files,calls,timers={}, {}, {}
local pending
local response_override
local response_status,response_timeout=0,false
fake.timer=function(ms,fn)
 local timer={ms=ms,fn=fn,cancelled=false}
 function timer:cancel() self.cancelled=true end
 table.insert(timers,timer); return timer
end
fake.process={run=function(argv,options,callback)
 table.insert(calls,{argv=argv,options=options})
 if pending then pending.callback=callback; return end
 if response_override then callback({status=response_status,timed_out=response_timeout,stdout=response_override,stderr=''});return end
 local mode,path=argv[5],argv[6]
 local status=''
 if mode=='read' then
  local bytes=files[path]
  status=if bytes then 'object\n'..runtime.base64.encode(bytes)..'\n' else 'missing\n'
  if path=='watermarks' and files['watermarks/1.json'] then status='object\n1\n'..runtime.base64.encode(files['watermarks/1.json'])..'\n' end
 elseif mode=='publish' then
  local raw=runtime.base64.decode(options.stdin:gsub('\n$',''))
  if files[path] and files[path]~=raw then status='content_conflict\n'
  elseif files[path] then status='already_published\n'
  else files[path]=raw; status='published\n' end
 elseif mode=='reconcile' then
  local raw=runtime.base64.decode(options.stdin:gsub('\n$',''))
  status=if files[path]==raw then 'already_published\n' elseif files[path] then 'content_conflict\n' else 'missing\n'
 elseif mode=='provision' then status='provisioned\n'
 else status='storage_error\n' end
 callback({status=0,timed_out=false,stdout=status,stderr=''})
end}
local function load(name)
 name=name:gsub('^%./','')
 if modules[name] then return modules[name] end
 local chunk=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
 setfenv(chunk,setmetatable({require=load,tern=fake},{__index=environment}))
 modules[name]=chunk(); return modules[name]
end
local M,C=load('mailbox'),load('codec')
local Capabilities=load('mailbox_capabilities')
local checks=0
local function check(value,message) assert(value,message); checks+=1 end
local function clone(value)
 if type(value)~='table' then return value end
 local out={}; for k,v in pairs(value) do out[k]=clone(v) end; return out
end
local binding={logical_session_id='session',worker_id='worker',worker_generation=1,launch_request_id='launch',work_id='work',enrolment_token=string.rep('t',16)}
local record={id='record',backend='local-terminal',mailbox={permitted_root='/private/mailboxes',helper_path='/private/tools/mailbox_target.sh',producer_helper_path='/private/tools/mailbox_worker.sh',worker_identity='worker',verified=true,evidence_ref='fixture-only',wake='worker-poll-v1',producer={read=true,write=true,hash=true,journal=true,poll=true},capabilities={'report-files-v1','worker-poll-v1','argv-v1'}}}
local context={operation_id='operation',handle='handle',host_os='linux',host_shell='sh'}
local function request(op)
 local r=clone(binding); r.schema=1; r.origin='orchplus'; r.request_id='request'; r.action_id='action'; r.op=op
 if op=='mailbox_provision' then r.record_id='record'; r.record_revision=1; r.capability='report-files-v1'
 else r.handle='handle'; r.expected_generation=1 end
 return r
end
local empty=M.empty()
check(M.validate(empty)~=nil,'empty registry valid')
check(M.validate({})==nil,'missing registry never initializes')
for _,s in ipairs({{}, {stream='report',slot=0,part='manifest'}, {stream='report',slot=1,part='manifest',index=1}, {stream='ack',slot=1,path='/tmp'}, {stream='watermark',through_seq=0}, {stream='report',slot=1,part='chunk',index=33}}) do check(M.selector(s)==nil,'closed bounded selector') end
check(M.selector({stream='watermark'})=='watermarks','bounded discovery selector')
check(M.selector({stream='reply',slot=9007199254740991,part='chunk',index=32})=='replies/9007199254740991/chunk-32.json','exact decimal max slot')
check(M.selector({stream='reply',slot=1,part='manifest'})=='replies/1/manifest.json','reply stream maps to fixed replies directory')
check(M.selector({stream='report',slot=9007199254740991,part='manifest'})=='reports/9007199254740991/manifest.json','report maximum slot retains exact decimal')
check(M.selector({stream='ack',slot=9007199254740991})=='acks/9007199254740991.json','ACK maximum slot retains exact decimal')
check(M.selector({stream='watermark',through_seq=9007199254740991})=='watermarks/9007199254740991.json','watermark maximum sequence retains exact decimal')
local provision=request('mailbox_provision')
local configured=assert(Capabilities.validate(record))
check(table.concat(configured,',')==table.concat(record.mailbox.capabilities,','),'helper preserves complete terminal capability set')
configured[1]='changed'
check(record.mailbox.capabilities[1]=='report-files-v1','helper returns an independent capability list')
for _,value in ipairs({false,{}, {mailbox={}}, {mailbox=false}}) do
 local ok,caps,reason=pcall(Capabilities.validate,value)
 check(ok and caps==nil and type(reason)=='string','missing mailbox metadata is ineligible without throwing')
end
local ok,caps,reason=pcall(Capabilities.validate,nil)
check(ok and caps==nil and type(reason)=='string','absent record is ineligible without throwing')
local function ineligible(candidate,message)
 local valid,result,why=pcall(Capabilities.validate,candidate)
 check(valid and result==nil and type(why)=='string',message..' helper rejects without throwing')
 local prepared,registry,rejection=M.prepare(empty,provision,candidate,context)
 check(prepared==nil and registry==nil and rejection.error.code=='unsupported_capability',message..' provisioning rejects before effects')
end
for _,key in ipairs({'permitted_root','helper_path','producer_helper_path','worker_identity','evidence_ref','verified','producer','capabilities','wake'}) do
 local partial=clone(record);partial.mailbox[key]=nil
 ineligible(partial,'missing '..key)
end
for _,value in ipairs({false,'producer',{}, {read=true,write=true,hash=true,journal='true',poll=true}}) do
 local partial=clone(record);partial.mailbox.producer=value
 ineligible(partial,'malformed or incomplete producer')
end
for _,key in ipairs({'read','write','hash','journal','poll'}) do
 local partial=clone(record);partial.mailbox.producer[key]=nil
 ineligible(partial,'partial producer '..key)
end
for _,values in ipairs({
 {},false,'report-files-v1',
 {'worker-poll-v1','argv-v1'},
 {'report-files-v1','argv-v1'},
 {'report-files-v1','worker-poll-v1'},
 {'report-files-v1','native-ask-v1','argv-v1'},
 {'report-files-v1','worker-poll-v1','native-ask-v1','argv-v1'},
 {'report-files-v1','worker-poll-v1','argv-v1','argv-v1'},
 {'report-files-v1','worker-poll-v1','argv-v1','unknown'},
 {[1]='report-files-v1',[3]='worker-poll-v1',[4]='argv-v1'},
 {['report-files-v1']=true,['worker-poll-v1']=true,['argv-v1']=true},
}) do
 local partial=clone(record);partial.mailbox.capabilities=values
 ineligible(partial,'invalid configured capability set')
end
local native=clone(record);native.backend='native-agent';native.mailbox.wake='native-ask-v1'
native.mailbox.capabilities={'report-files-v1','native-ask-v1'};native.mailbox.producer.poll=false
check(Capabilities.validate(native)~=nil,'native ask requires no polling capability')
local nativeOp,nativeIntent=M.prepare(empty,provision,native,context)
check(nativeOp and nativeIntent,'native ask provisioning accepts matching backend capabilities')
local nativeRegistry,nativeResponse=M.settle(nativeIntent,nativeOp,{status='provisioned'})
check(M.validate(nativeRegistry) and #nativeResponse.payload.capabilities==2,'native provisioning retains only configured native capabilities')
local mismatch=clone(native);table.insert(mismatch.mailbox.capabilities,'argv-v1')
ineligible(mismatch,'native backend cannot advertise terminal argv input')
mismatch=clone(record);mismatch.mailbox.wake='native-ask-v1';mismatch.mailbox.capabilities={'report-files-v1','native-ask-v1','argv-v1'}
ineligible(mismatch,'terminal cannot advertise native ask wake')
local pollingNative=clone(record);pollingNative.backend='native-agent';pollingNative.mailbox.capabilities={'report-files-v1','worker-poll-v1'}
check(Capabilities.validate(pollingNative)~=nil,'native backend preserves existing explicit worker polling route')
local ssh=clone(record);ssh.backend='ssh-command'
check(Capabilities.validate(ssh)~=nil,'SSH terminal requires the same argv input contract')
table.remove(ssh.mailbox.capabilities,3)
check(Capabilities.validate(ssh)==nil,'SSH terminal without argv input is ineligible')
local op,intent,problem=M.prepare(empty,provision,record,context)
check(op and intent and not problem,'provision creates intent')
check(next(empty.generations)==nil,'prepare does not mutate source')
check(#calls==0,'prepare performs no IO')
check(M.get(intent,'handle').phase=='intent','handle remains intent before callback persistence')
check(M.location(intent,'handle')==nil,'incomplete provisioning cannot launch')
check(M.validate(intent)~=nil,'active intent validates')
local reg,response=M.settle(intent,op,{status='provisioned'})
check(reg and response.status=='provisioned','provision settlement')
check(response.payload.handle=='handle' and response.payload.root==nil,'public result only opaque handle')
check(table.concat(response.payload.capabilities,',')==table.concat(record.mailbox.capabilities,','),'provision response preserves argv-v1 with report and exact wake')
check(table.concat(intent.generations.handle.capabilities,',')==table.concat(record.mailbox.capabilities,','),'intent persists the validated configured capability set')
check(reg.generations.handle.backend=='local-terminal','registry retains backend after target retirement')
local projection=M.get(reg,'handle')
check(table.concat(projection.capabilities,',')==table.concat(response.payload.capabilities,','),'read identity preserves the provisioned capability set')
projection.capabilities[1]='changed'
check(reg.generations.handle.capabilities[1]=='report-files-v1','read identity capability list cannot mutate registry')
response.payload.capabilities[1]='changed'
check(reg.generations.handle.writes.provision.result.payload.capabilities[1]=='report-files-v1','retained response has its own capability list')
check(M.location(reg,'handle').root=='/private/mailboxes','private target retained')
check(M.location(reg,'handle').producer_helper=='/private/tools/mailbox_worker.sh','producer path is explicit and private')
check(M.get(reg,'handle').binding.mailbox_handle==nil,'launch binding is exact BE only')
local corruptTarget=clone(reg); corruptTarget.generations.handle.target.helper='/private/altered'
check(M.validate(corruptTarget)==nil,'changed persisted target digest fails closed')
local corruptWrite=clone(reg); corruptWrite.generations.handle.writes.provision.request.work_id='other'
check(M.validate(corruptWrite)==nil,'changed persisted write binding fails closed')
check(M.validate(runtime.json.decode(runtime.json.encode(reg)))~=nil,'registry target digest survives serialization order')
local corruptOutcome=clone(reg); corruptOutcome.generations.handle.writes.provision.result='lost'
check(M.validate(corruptOutcome)==nil,'malformed retained outcome is corrupt authority')
-- Live generations: the advertised limit is exactly what provisioning admits within the host allocation.
do
 local limit=response.payload.limits.generations
 check(limit==M.LIMITS.generations and limit*M.LIMITS.mailbox_bytes<=M.LIMITS.host_bytes and limit*M.LIMITS.mailbox_files<=M.LIMITS.host_files,'advertised live-generation limit fits the 64 MiB/16,384-file host allocation')
 local live=M.empty()
 for i=1,limit do
  local p=clone(provision);p.request_id='request-'..i;p.launch_request_id='launch-'..i
  local c=clone(context);c.handle='handle-'..i;c.operation_id='operation-'..i
  local liveOp,liveIntent,liveProblem=M.prepare(live,p,record,c)
  assert(liveOp and liveIntent and not liveProblem,'live generation '..i..' is admitted')
  live=assert(M.settle(liveIntent,liveOp,{status='provisioned'}))
 end
 check(M.validate(live)~=nil,'a registry at the live-generation limit validates')
 local p=clone(provision);p.request_id='request-over';p.launch_request_id='launch-over'
 local c=clone(context);c.handle='handle-over';c.operation_id='operation-over'
 local overOp,overIntent,full=M.prepare(live,p,record,c)
 check(overOp==nil and overIntent==nil and full.status=='full' and full.resource=='mailbox_allocation' and full.current==limit*M.LIMITS.mailbox_bytes and full.limit==M.LIMITS.host_bytes,
  'the provision past the advertised limit is refused full at the host allocation')
end
local corruptCaps=clone(reg);table.remove(corruptCaps.generations.handle.capabilities,3)
check(M.validate(corruptCaps)==nil,'persisted terminal generation cannot lose argv-v1')
corruptCaps=clone(reg);corruptCaps.generations.handle.capabilities=nil
check(M.validate(corruptCaps)==nil,'registry never invents missing capabilities')
corruptCaps=clone(reg);corruptCaps.generations.handle.backend='native-agent'
check(M.validate(corruptCaps)==nil,'persisted backend cannot disagree with capabilities or target')
corruptCaps=clone(reg);table.remove(corruptCaps.generations.handle.writes.provision.result.payload.capabilities,3)
check(M.validate(corruptCaps)==nil,'retained provision capabilities must match generation identity')
corruptCaps=clone(reg);corruptCaps.generations.handle.capabilities={'argv-v1','report-files-v1','worker-poll-v1'}
check(M.validate(corruptCaps)==nil,'persisted exact capability list is digest-bound')
-- Rollover successor: the issued handover ID and pair digest (never the token) are provisioned,
-- bound into the binding digest and written into provision.json for the producer to verify.
do
 local token=string.rep('29f79cde',7)..'b5851668'
 local successor=clone(provision); successor.handover_id='handover-540'; successor.handover_sha256=C.sha256('handover-540:'..token)
 local handoverOp,handoverIntent=M.prepare(empty,successor,record,context)
 check(handoverOp and handoverIntent and M.validate(handoverIntent)~=nil,'paired handover digest provisions a valid intent')
 local g=handoverIntent.generations.handle
 check(g.handover.handover_id=='handover-540' and g.handover.handover_sha256==successor.handover_sha256 and g.binding_digest~=intent.generations.handle.binding_digest,'handover digest is retained and bound into the binding digest')
 local written=runtime.json.decode(handoverOp.bytes)
 check(written.handover.handover_id=='handover-540' and written.handover.handover_sha256==successor.handover_sha256 and not handoverOp.bytes:find(token,1,true),'provision.json carries the ID and digest, never the raw token')
 check(runtime.json.decode(op.bytes).handover==nil,'an ordinary provision.json carries no handover')
 local settled=assert(M.settle(handoverIntent,handoverOp,{status='provisioned'}))
 check(M.get(settled,'handle').handover.handover_sha256==successor.handover_sha256,'launch inspection exposes the provisioned handover digest')
 check(M.validate(runtime.json.decode(runtime.json.encode(settled)))~=nil,'provisioned handover survives serialization')
 local altered=clone(settled); altered.generations.handle.handover.handover_sha256=string.rep('0',64)
 check(M.validate(altered)==nil,'a changed persisted handover digest fails closed')
 local changedPair=clone(successor); changedPair.handover_sha256=C.sha256('handover-540:'..token..'x')
 check(select(3,M.prepare(settled,changedPair,record,context)).error.code=='content_conflict','a different handover digest cannot replay the provision')
 local unpaired=clone(successor); unpaired.handover_sha256=nil
 check(select(3,M.prepare(empty,unpaired,record,context)).error.code=='invalid_schema','handover ID and digest are paired')
end
-- Assignment manifest (Contract G): the exact bytes are hashed into the binding digest after the
-- handover part, named by manifest_sha256 in provision.json and passed to the target helper.
do
 local function digestOf(g,manifest)
  local parts={'report-files-v1:policy:1'}
  local function add(value)
   local text=if type(value)=='number' then string.format('%.0f',value) else value or ''
   table.insert(parts,tostring(#text)..':'..text)
  end
  for _,key in ipairs({'logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token'}) do add(g.binding[key]) end
  add(g.binding.mailbox_handle);add(g.record_id);add(g.record_revision);add(g.wake);add(g.backend)
  for _,capability in ipairs(g.capabilities) do add(capability) end
  for _,key in ipairs({'root','helper','producer_helper','worker_identity','os','shell','kind','backend','host','user','key_path','host_os','host_shell'}) do add(g.target[key]) end
  if manifest then add('manifest');add(manifest) end
  return C.sha256(table.concat(parts,''))
 end
 local manifestBytes='{"base_ref":"main","checks":[{"argv":["make","test"],"check_id":"t1-c1"}],"files":["src/a.luau"],"scope":{"paths":["src"],"systems":["spawn"]}}'
 local plain=runtime.json.decode(op.bytes)
 check(intent.generations.handle.binding_digest==digestOf(intent.generations.handle) and intent.generations.handle.manifest_sha256==nil,'a provision without a manifest keeps the 0.3.0 binding digest')
 check(op.manifest==nil and plain.manifest_sha256==nil and plain.capabilities==nil,'an ordinary provision.json carries no manifest digest or capability list')
 local before=#calls
 local plainOutcome;M.execute(clone(op),function(value)plainOutcome=value end)
 check(plainOutcome.status=='provisioned' and #calls==before+1 and calls[#calls].options.stdin==runtime.base64.encode(op.bytes)..'\n','a provision without a manifest sends the target helper one Base64 line')
 local withManifest=clone(provision);withManifest.manifest=manifestBytes
 local mOp,mIntent,mProblem=M.prepare(empty,withManifest,record,context)
 check(mOp and mIntent and not mProblem and M.validate(mIntent)~=nil,'a bounded closed manifest provisions a valid intent')
 local g=mIntent.generations.handle
 check(g.manifest_sha256==C.sha256(manifestBytes) and g.binding_digest==digestOf(g,C.sha256(manifestBytes)) and g.binding_digest~=intent.generations.handle.binding_digest,'the manifest digest joins the binding after the handover part')
 local written=runtime.json.decode(mOp.bytes)
 check(written.manifest_sha256==g.manifest_sha256 and written.binding_digest==g.binding_digest and written.capabilities==nil and #mOp.bytes<=2048,'provision.json names the exact manifest digest within its 2048-byte bound')
 check(mOp.manifest==manifestBytes,'the exact manifest bytes travel with the provision operation')
 before=#calls
 local outcome;M.execute(mOp,function(value)outcome=value end)
 check(outcome.status=='provisioned' and #calls==before+1 and calls[#calls].options.stdin==runtime.base64.encode(mOp.bytes)..'\n'..runtime.base64.encode(manifestBytes)..'\n','the target helper receives provision.json, then the exact manifest, one Base64 line each')
 local settled=assert(M.settle(mIntent,mOp,outcome))
 check(M.validate(runtime.json.decode(runtime.json.encode(settled)))~=nil,'a provisioned manifest survives serialization')
 local replayed=select(3,M.prepare(settled,withManifest,record,context))
 check(replayed.status=='provisioned' and replayed.payload.binding_digest==g.binding_digest,'an exact manifest provision replay returns the retained result')
 check(replayed.payload.manifest_sha256==g.manifest_sha256,'the provision result names the bound manifest digest for the ORCH+ cross-check')
 local dropped=clone(settled);dropped.generations.handle.writes.provision.result.payload.manifest_sha256=nil
 check(M.validate(dropped)==nil,'a retained provision result that drops its manifest digest fails closed')
 local tampered=clone(settled);tampered.generations.handle.manifest_sha256=C.sha256(manifestBytes..' ')
 check(M.validate(tampered)==nil,'a changed persisted manifest digest fails closed')
 tampered=clone(settled);tampered.generations.handle.writes.provision.request.manifest=(manifestBytes:gsub('"test"','"deploy"'))
 check(M.validate(tampered)==nil,'tampered retained manifest bytes fail closed')
 tampered=clone(settled);tampered.generations.handle.writes.provision.request.manifest=nil
 check(M.validate(tampered)==nil,'a retained provision cannot drop its manifest')
 local other=clone(withManifest);other.manifest=(manifestBytes:gsub('"test"','"deploy"'))
 check(select(3,M.prepare(settled,other,record,context)).error.code=='content_conflict','a tampered manifest cannot replay the provision')
 check(select(3,M.prepare(settled,provision,record,context)).error.code=='content_conflict','a manifest provision cannot be replayed without its manifest')
 check(select(3,M.prepare(reg,withManifest,record,context)).error.code=='content_conflict','a manifest cannot be added to a provisioned generation')
 local recoveredManifest=M.recover(mIntent)
 local reconcile=M.prepare(recoveredManifest,withManifest,record,context)
 before=#calls
 M.execute(reconcile,function(value)outcome=value end)
 check(reconcile.reconcile and calls[#calls].argv[5]=='reconcile_provision' and calls[#calls].options.stdin==runtime.base64.encode(mOp.bytes)..'\n'..runtime.base64.encode(manifestBytes)..'\n','manifest readback receives the same two exact lines')
 -- Exactly 4096 canonical bytes are admitted; one more is manifest_too_large.
 local function sized(total)
  local head,tail='{"checks":[],"files":[','],"scope":{"paths":[],"systems":[]}}'
  local entries,size={},#head+#tail
  while true do
   local comma=if #entries>0 then 1 else 0
   local room=total-size-comma-2
   if room<=256 then table.insert(entries,'"'..string.rep('f',room)..'"'); break end
   table.insert(entries,'"'..string.rep('f',200)..'"'); size+=202+comma
  end
  return head..table.concat(entries,',')..tail
 end
 local bound=clone(provision);bound.manifest=sized(4096)
 local boundOp=M.prepare(empty,bound,record,context)
 check(#bound.manifest==4096 and boundOp and boundOp.manifest==bound.manifest,'a manifest of exactly 4096 bytes is admitted')
 local over=clone(provision);over.manifest=sized(4097)
 local overOp,overIntent,overProblem=M.prepare(empty,over,record,context)
 check(#over.manifest==4097 and overOp==nil and overIntent==nil and overProblem.error.code=='manifest_too_large','a manifest over 4096 bytes is refused manifest_too_large')
 for _,bytes in ipairs({
  '{"checks":[],"files":[],"scope":{"paths":[],"systems":[]},"extra":true}',
  '{"checks":[],"files":[]}',
  '{"checks":[{"check_id":"a","argv":["x"]},{"check_id":"a","argv":["y"]}],"files":[],"scope":{"paths":[],"systems":[]}}',
  '{"checks":[{"check_id":"a","argv":[]}],"files":[],"scope":{"paths":[],"systems":[]}}',
  '{"checks":[{"check_id":"a/b","argv":["x"]}],"files":[],"scope":{"paths":[],"systems":[]}}',
  '{"base_ref":"","checks":[],"files":[],"scope":{"paths":[],"systems":[]}}',
  '{"base_ref":null,"checks":[],"files":[],"scope":{"paths":[],"systems":[]}}',
  '{"checks":[],"files":[],"scope":{"paths":[],"systems":[],"extra":[]}}',
  '[]','not json',
 }) do
  local bad=clone(provision);bad.manifest=bytes
  check(select(3,M.prepare(empty,bad,record,context)).error.code=='invalid_schema','a malformed or open manifest is refused before effects')
 end
 local blank=clone(provision);blank.manifest=''
 check(select(3,M.prepare(empty,blank,record,context)).error.code=='invalid_schema','an empty manifest is refused')
 -- A generation holding a 0.4.0 capability names its capability set in provision.json (sixth capability).
 local runner=clone(record);runner.mailbox.capabilities={'report-files-v1','worker-poll-v1','argv-v1','coordinator-control-v1','check-runner-v1','release-manager-v1'}
 check(Capabilities.validate(runner)~=nil,'a six-capability set with check-runner-v1 and release-manager-v1 is eligible')
 local runnerOp,runnerIntent=M.prepare(empty,provision,runner,context)
 local runnerWritten=runtime.json.decode(runnerOp.bytes)
 check(runnerIntent and M.validate(runnerIntent)~=nil and table.concat(runnerWritten.capabilities,',')==table.concat(runner.mailbox.capabilities,',') and runnerWritten.manifest_sha256==nil,'provision.json carries the gated capability set independent of any manifest')
 check(runnerIntent.generations.handle.binding_digest==digestOf(runnerIntent.generations.handle),'capabilities stay bound through the unchanged digest construction')
 local seven=clone(runner);seven.mailbox.capabilities={'report-files-v1','worker-poll-v1','native-ask-v1','argv-v1','coordinator-control-v1','check-runner-v1','release-manager-v1'}
 check(Capabilities.validate(seven)==nil,'a seventh entry still cannot combine both wake routes')
 local eight=clone(runner);table.insert(eight.mailbox.capabilities,'check-runner-v1');table.insert(eight.mailbox.capabilities,'argv-v1')
 check(Capabilities.validate(eight)==nil,'an eighth capability entry is refused')
 local Config=load('config')
 local function configured(capabilities) return Config.validate_record({id='worker',provider='custom',backend='local-terminal',command='worker',arguments={},mailbox={capabilities=capabilities}}) end
 local list={'report-files-v1','native-ask-v1','worker-poll-v1','argv-v1','coordinator-control-v1','check-runner-v1'}
 check(configured(list)~=nil,'Config accepts a sixth capability')
 table.insert(list,'release-manager-v1')
 check(configured(list)~=nil,'Config accepts a seventh capability')
 table.insert(list,'report-files-v1')
 check(configured(list)==nil,'Config refuses an eighth capability')
end
local zeroRevision=clone(provision); zeroRevision.record_revision=0
local _,zeroIntent=M.prepare(empty,zeroRevision,record,context)
check(zeroIntent and M.validate(zeroIntent)~=nil,'canonical initial record revision zero retained')
local legacyRecord=clone(record); legacyRecord.id='legacy record name'
local legacyProvision=clone(provision); legacyProvision.record_id=legacyRecord.id
check(M.prepare(empty,legacyProvision,legacyRecord,context)~=nil,'legacy display record IDs never become paths')
check(M.get(reg,'handle').binding.enrolment_token==binding.enrolment_token,'launch binding preserved')
local no,nothing,replay=M.prepare(reg,provision,record,context)
check(no==nil and nothing==nil and replay.status=='provisioned','exact provision replay returns retained result')
check(table.concat(replay.payload.capabilities,',')==table.concat(record.mailbox.capabilities,','),'provision replay retains terminal argv-v1')
local changed=clone(provision); changed.record_revision=2
check(select(3,M.prepare(reg,changed,record,context)).error.code=='content_conflict','record change conflicts')
changed=clone(provision); changed.extra='path'
check(select(3,M.prepare(empty,changed,record,context)).error.code=='invalid_schema','unknown request fields rejected')
local unsupported=clone(record); unsupported.mailbox.verified=false
check(select(3,M.prepare(empty,provision,unsupported,context)).error.code=='unsupported_capability','unverified producer never advertises capability')
local recovered=M.recover(intent)
check(recovered.generations.handle.writes.provision.status=='uncertain','reload retains possibly effected intent')
check(recovered.generations.handle.active==nil,'reload clears old VM ownership')
check(table.concat(M.get(recovered,'handle').capabilities,',')==table.concat(record.mailbox.capabilities,','),'reload recovery preserves capability identity')
check(M.settle(recovered,op,{status='provisioned'})==nil,'late callback fenced after reload')
local retry,retryRegistry=M.prepare(recovered,provision,record,context)
check(retry.reconcile==true and retryRegistry~=nil,'uncertain provision can only reconcile')
local read=request('mailbox_read'); read.selector={stream='report',slot=1,part='manifest'}
local readOp,readClaim=M.prepare(reg,read,nil,context)
check(readOp and readClaim.generations.handle.active.key=='read','read claimed by generation')
check(select(3,M.prepare(readClaim,read,nil,context)).status=='full','one operation per generation')
local readDone=M.settle(readClaim,readOp,{status='missing'})
check(table.concat(M.get(readDone,'handle').capabilities,',')==table.concat(record.mailbox.capabilities,','),'read settlement preserves capability identity')
check(readDone.generations.handle.writes.read==nil,'read responses do not append durable history')
local stale=clone(read); stale.expected_generation=2
check(select(3,M.prepare(reg,stale,nil,context)).error.code=='binding_mismatch','stale generation blocked')
local ack={version=1,event_id=C.sha256('handle:report:1'),seq=1,event_sha256=C.sha256('event'),committed_revision=2,disposition='accepted',receipt_chain_sha256=C.sha256('chain')}
for _,k in ipairs({'logical_session_id','worker_id','worker_generation','launch_request_id','work_id'}) do ack[k]=binding[k] end
local ackBytes=runtime.json.encode(ack)
local ackRequest=request('mailbox_publish_ack'); ackRequest.receipt_revision=2; ackRequest.ack_b64=runtime.base64.encode(ackBytes); ackRequest.ack_sha256=C.sha256(ackBytes)
local ackOp,ackClaim=M.prepare(reg,ackRequest,nil,context)
check(ackOp and ackClaim,'exact ACK publication claim')
local ackResult
M.execute(ackOp,function(value) ackResult=value end)
check(ackResult.status=='published' and files['acks/1.json']==ackBytes,'adapter publishes exact bytes')
check(calls[#calls].options.timeout_ms<=30000,'process deadline bounded')
local withAck=M.settle(ackClaim,ackOp,ackResult)
check(select(3,M.prepare(withAck,ackRequest,nil,context)).status=='published','ACK outcome retained')
local different=clone(ackRequest); different.ack_sha256=C.sha256('different')
check(select(3,M.prepare(withAck,different,nil,context)).error.code=='content_conflict','changed ACK digest conflicts')
local ambiguous=M.settle(ackClaim,ackOp,{status='uncertain'})
check(select(3,M.prepare(ambiguous,read,nil,context)).status=='uncertain','uncertain writes fence unrelated reads/effects')
local reconcile,reconcileClaim=M.prepare(ambiguous,ackRequest,nil,context)
local reconcileResult; M.execute(reconcile,function(value) reconcileResult=value end)
check(reconcileResult.status=='already_published','exact readback reconciles uncertain publication')
check(calls[#calls].argv[5]=='reconcile','reconciliation is read-only helper mode')
local missingAck=clone(ackOp); missingAck.reconcile=true; files['acks/1.json']=nil
local before=#calls
M.execute(missingAck,function(value) reconcileResult=value end)
check(reconcileResult.status=='published' and #calls==before+2 and calls[before+1].argv[5]=='reconcile' and calls[before+2].argv[5]=='publish' and files['acks/1.json']==ackBytes,
 'proven-absent publication is read back, then republished once with the exact same immutable bytes')
local lateChild=clone(ackOp); lateChild.reconcile=true; files['acks/1.json']=nil
local raced=fake.process.run; fake.process.run=function(argv,options,callback)
 if argv[5]=='publish' then files['acks/1.json']=ackBytes end -- An earlier child finishes between readback and republish.
 return raced(argv,options,callback)
end
M.execute(lateChild,function(value) reconcileResult=value end); fake.process.run=raced
check(reconcileResult.status=='already_published' and files['acks/1.json']==ackBytes,'a late earlier child can only have published the same bytes; republish never conflicts or duplicates')
local reconciledAck=M.settle(reconcileClaim,reconcile,{status='published'})
check(reconciledAck.generations.handle.writes['acks/1.json'].status=='settled','republished readback settles the retained uncertain write')
files['acks/1.json']=nil
local reply={version=1,message_id='message',reply_seq=1,action_id='command',action_revision=1,kind='report_request',payload={request_id='reportRequest',requested_kind='HEARTBEAT',reason='state'}}
for _,k in ipairs({'logical_session_id','worker_id','worker_generation','launch_request_id','work_id'}) do reply[k]=binding[k] end
local expected=clone(binding); expected.mailbox_handle='handle'
local frame=assert(C.frame(runtime.json.encode(reply),'reply',expected))
local publish=request('mailbox_publish_reply'); publish.message_id='message'; publish.reply_seq=1; publish.action_revision=1; publish.reply_sha256=frame.message_sha256; publish.part='manifest'; publish.object_b64=runtime.base64.encode(frame.manifest); publish.object_sha256=C.sha256(frame.manifest)
local manifestOp,manifestClaim=M.prepare(reg,publish,nil,context)
local manifestResult; M.execute(manifestOp,function(value) manifestResult=value end)
check(manifestResult.status=='incomplete' and files['replies/1/manifest.json']==nil,'manifest cannot precede verified chunks')
local incomplete=M.settle(manifestClaim,manifestOp,manifestResult)
check(incomplete.generations.handle.writes['replies/1/manifest.json'].status=='prepared','missing chunks permit only same immutable manifest retry')
for i,bytes in ipairs(frame.chunks) do files['replies/1/chunk-'..i..'.json']=bytes end
M.execute(manifestOp,function(value) manifestResult=value end)
check(manifestResult.status=='published','whole reply validates before manifest publication')
check(files['replies/1/manifest.json']==frame.manifest,'manifest exact-byte publication')
local corrupt=C.strict_decode(frame.chunks[1]); corrupt.message_id='other'; files['replies/1/chunk-1.json']=runtime.json.encode(corrupt)
M.execute(manifestOp,function(value) manifestResult=value end)
check(manifestResult.error.code=='content_conflict','mixed framing identity rejected')
files['replies/1/chunk-1.json']=frame.chunks[1]
local grant=request('mailbox_retire'); grant.mode='compact'; grant.settlement_revision=3; grant.report_floor=1; grant.report_chain_sha256=ack.receipt_chain_sha256; grant.reply_floor=0; grant.grant_id='grant'
check(select(3,M.prepare(withAck,grant,nil,context)).error.code=='binding_mismatch','public compaction request is not authority')
local granted=clone(context); granted.settlement=clone(grant)
local compactOp,compactClaim=M.prepare(withAck,grant,nil,granted)
check(compactOp~=nil,'trusted exact prefix grant admitted')
local compacted=M.settle(compactClaim,compactOp,{status='compacted'})
check(compacted.generations.handle.report_floor==1 and compacted.generations.handle.writes['acks/1.json']==nil,'prefix compacts receipt metadata not fences')
check(select(3,M.prepare(compacted,ackRequest,nil,context)).status=='already_compacted','old ACK cannot recreate deleted prefix')
check(select(3,M.prepare(compacted,read,nil,context)).status=='compacted','old report read classified compacted')
local retirement=clone(grant); retirement.mode='retire'; retirement.grant_id='retire'
local retirementContext=clone(context); retirementContext.settlement=clone(retirement)
check(select(3,M.prepare(compacted,retirement,nil,retirementContext)).error.code=='binding_mismatch','retirement requires complete settlement authority')
retirementContext.settlement.settled=true
local retireOp,retireClaim=M.prepare(compacted,retirement,nil,retirementContext)
local retired=M.settle(retireClaim,retireOp,{status='retired'})
check(retired.generations.handle.status=='retired' and retired.generations.handle.target==nil,'retirement leaves small tombstone')
check(select(3,M.prepare(retired,read,nil,context)).error.code=='generation_retired','retired generation never reused')
check(M.validate(retired)~=nil,'tombstones survive persisted validation')
check(table.concat(M.get(retired,'handle').capabilities,',')==table.concat(record.mailbox.capabilities,','),'retired identity preserves original capability contract')
for _,publication in ipairs({
 {request=ackRequest,operation=ackOp,claim=ackClaim,other=publish},
 {request=publish,operation=manifestOp,claim=manifestClaim,other=ackRequest},
}) do
 local uncertain=M.recover(publication.claim)
 local key=publication.operation.key
 for _,status in ipairs({'full','incomplete','missing','full','incomplete','missing'}) do
  local retryOp,retryClaim=M.prepare(uncertain,publication.request,nil,context)
  check(retryOp and retryOp.reconcile==true,'every unresolved publication retry remains readback-only')
  local outcome
  uncertain,outcome=M.settle(retryClaim,retryOp,{status=status})
  check(outcome.status=='uncertain','failed readback preserves original publication uncertainty')
  check(uncertain.generations.handle.writes[key].status=='uncertain','failed readback never demotes publication to prepared')
  check(uncertain.generations.handle.active==nil,'failed readback releases only the current operation claim')
  uncertain=M.recover(assert(M.validate(runtime.json.decode(runtime.json.encode(uncertain)))))
  check(select(3,M.prepare(uncertain,read,nil,context)).status=='uncertain','unresolved child fences reads after repeated failed readback and reload')
  check(select(3,M.prepare(uncertain,publication.other,nil,context)).status=='uncertain','unresolved child fences different publications after repeated failed readback')
  check(select(3,M.prepare(uncertain,grant,nil,granted)).status=='uncertain','unresolved child fences compaction after repeated failed readback')
  check(select(3,M.prepare(uncertain,retirement,nil,retirementContext)).status=='uncertain','unresolved child fences retirement after repeated failed readback')
 end
 local exactOp,exactClaim=M.prepare(uncertain,publication.request,nil,context)
 files[exactOp.path]=exactOp.bytes
 local exactResult
 M.execute(exactOp,function(value) exactResult=value end)
 check(exactResult.status=='already_published','exact publication readback conclusively resolves original uncertainty')
 local settled=M.settle(exactClaim,exactOp,exactResult)
 check(settled.generations.handle.writes[key].status=='settled','conclusive readback settles the original publication')
 check(M.prepare(settled,read,nil,context)~=nil,'conclusive readback releases the unresolved child fence')
end
local watermark=clone(binding); watermark.version=1; watermark.type='receipt_watermark'; watermark.mailbox_handle='handle'; watermark.through_seq=1; watermark.receipt_chain_sha256=ack.receipt_chain_sha256
files['watermarks/1.json']=runtime.json.encode(watermark)
local discovery=request('mailbox_read'); discovery.selector={stream='watermark'}
local discoveryOp=M.prepare(reg,discovery,nil,context)
local page
M.execute(discoveryOp,function(value) page=value end)
check(page.status=='read' and page.payload.selector.through_seq==nil,'watermark discovery echoes exact request selector')
check(C.decode_page(runtime.json.encode(page.payload),discovery.selector)~=nil,'discovery page satisfies shared strict codec')
watermark.through_seq=2; files['watermarks/1.json']=runtime.json.encode(watermark)
M.execute(discoveryOp,function(value) page=value end)
check(page.error.code=='binding_mismatch','discovered filename and watermark contents must agree')
-- Coordinator rollover successor: dispatch binds every report read to the
-- issued launch contract (assignment, handover pair, capabilities). The exact ACCEPTED reads
-- back; one mistyped handover-token digit is refused with its precise codec diagnostic.
do
 local issued=clone(readOp.binding)
 issued.assignment_sha256=string.rep('9',64); issued.handover_id='handover-540'
 issued.handover_token=string.rep('29f79cde',7)..'b5851668'; issued.capabilities={'report-files-v1','native-ask-v1','coordinator-control-v1'}
 local function acceptance(token)
  local report={version=3,event_id=C.sha256('handle:report:1'),seq=1,kind='ACCEPTED',payload={assignment_sha256=issued.assignment_sha256},handover_id=issued.handover_id,handover_token=token}
  for _,k in ipairs({'logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token'}) do report[k]=binding[k] end
  local written=clone(issued); written.handover_token=token
  local framed=assert(C.frame(runtime.json.encode(report),'report',written))
  files['reports/1/manifest.json']=framed.manifest; files['reports/1/chunk-1.json']=framed.chunks[1]
  local successor=clone(readOp); successor.binding=clone(issued)
  local outcome; M.execute(successor,function(value) outcome=value end)
  files['reports/1/manifest.json']=nil; files['reports/1/chunk-1.json']=nil
  return outcome
 end
 local exact=acceptance(issued.handover_token)
 check(exact.status=='read' and exact.payload.selector.part=='manifest','coordinator successor ACCEPTED with the issued handover pair reads back')
 local typo=acceptance(string.rep('29f79cde',7)..'b585166a')
 check(typo.status=='rejected' and typo.error.code=='binding_mismatch' and typo.error.message=='Acceptance differs from the issued assignment or handover.',
  'a mistyped successor handover token is refused with its exact diagnostic, not a bare code: '..runtime.json.encode(typo))
end
-- Deadlines measure awake progress between watchdog ticks, not wall time across a suspension.
local function watchdog(ms) clock+=ms; timers[#timers].fn() end
pending={}
local timed
M.execute(readOp,function(value) timed=value end)
for _=1,29 do watchdog(1000) end
check(timed==nil,'awake time below the deadline keeps the child running')
watchdog(1000)
check(timed.status=='uncertain','overall awake deadline retains uncertainty')
pending.callback({status=0,timed_out=false,stdout='admission_full\ncapacity_admission\n1\n1\n',stderr=''})
check(timed.status=='uncertain','late callback cannot overwrite timeout outcome')
pending={}
local spanned
M.execute(manifestOp,function(value) spanned=value end)
local spanStart=#calls
check(calls[spanStart].options.timeout_ms==30000,'first child receives the whole awake budget')
watchdog(1000); watchdog(3600000); watchdog(1000)
check(spanned==nil,'host suspension while a child runs is not awake deadline progress')
pending.callback({status=0,timed_out=false,stdout='object\n'..runtime.base64.encode(frame.chunks[1])..'\n',stderr=''})
check(spanned==nil and #calls==spanStart+1 and calls[#calls].options.timeout_ms>=27000,'next child keeps the awake remaining budget after a suspension')
for index=2,#frame.chunks do
 pending.callback({status=0,timed_out=false,stdout='object\n'..runtime.base64.encode(frame.chunks[index])..'\n',stderr=''})
end
check(calls[#calls].argv[5]=='publish' and spanned==nil,'verified chunks proceed to the exact publication after the suspension')
pending.callback({status=0,timed_out=false,stdout='already_published\n',stderr=''})
check(spanned.status=='already_published','child spanning a host suspension settles with its conclusive outcome, not uncertainty')
pending={}
local killed
M.execute(readOp,function(value) killed=value end)
watchdog(3600000)
check(killed==nil,'suspension alone never declares the running child uncertain')
pending.callback({status=-1,timed_out=true,stdout='object\n',stderr=''})
check(killed.status=='uncertain','a child process.run already timed out stays uncertain')
pending=nil
response_override='full\nmailbox_bytes\n2097000\n2097152\n'
local capacityResult
M.execute(readOp,function(value)capacityResult=value end)
check(capacityResult.status=='full' and capacityResult.resource=='mailbox_bytes' and capacityResult.current==2097000 and capacityResult.limit==2097152,'adapter preserves truthful projected capacity accounting')
for _,wire in ipairs({'full\n','full\nmailbox bytes\n1\n2\n','full\nmailbox_bytes\n1\n0\n','full\nmailbox_bytes\n9007199254740992\n2\n','full\nmailbox_bytes\n01\n2\n'}) do
 response_override=wire
 M.execute(readOp,function(value)capacityResult=value end)
 check(capacityResult.status=='uncertain','malformed full accounting never invents retry evidence')
end
response_override=nil
response_override='admission_full\ncapacity_admission\n1\n1\n'
M.execute(readOp,function(value)capacityResult=value end)
check(capacityResult.admission_refused==true,'complete successful initial gate refusal is distinct private evidence')
response_status=1
M.execute(readOp,function(value)capacityResult=value end)
check(capacityResult.status=='uncertain' and not capacityResult.admission_refused,'failed child with matching-looking output grants no retry proof')
response_status=-1;response_timeout=true
M.execute(readOp,function(value)capacityResult=value end)
check(capacityResult.status=='uncertain' and not capacityResult.admission_refused,'timed-out child with admission output grants no retry proof')
response_status=0;response_timeout=false
response_override='admission_full\ncapacity_admission\n1\n1\nextra'
M.execute(readOp,function(value)capacityResult=value end)
check(capacityResult.status=='uncertain','admission prefix without exact complete output grants no proof')
response_override=nil
local windowsCompact=clone(compactOp)
windowsCompact.handle='-handle';windowsCompact.id='-operation'
windowsCompact.target={root='C:\\private\\mailboxes',helper='C:\\private\\tools\\mailbox_target.ps1',producer_helper='C:\\private\\tools\\mailbox_worker.ps1',worker_identity='HOST\\worker',os='windows',shell='powershell.exe',kind='powershell',backend='local-terminal',host_os='windows',host_shell='powershell.exe'}
response_override='compacted\n'
local windowsResult
M.execute(windowsCompact,function(value)windowsResult=value end)
check(windowsResult.status=='compacted','Windows compaction retains the existing helper result')
local expectedWindows={'powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-File',windowsCompact.target.helper,'-Root:',windowsCompact.target.root,'-Handle:','-handle','-Mode:','compact','-Selected:','-','-Operation:','-operation','-Identity:','HOST\\worker','-ReportFloor:',string.format('%.0f',windowsCompact.report_floor or 0),'-ReplyFloor:',string.format('%.0f',windowsCompact.reply_floor or 0),'-ProducerHelper:',windowsCompact.target.producer_helper}
local windowsArgv=calls[#calls].argv
check(#windowsArgv==#expectedWindows,'Windows helper invocation has no implicit positional arguments')
for index,value in ipairs(expectedWindows) do check(windowsArgv[index]==value,'Windows named-colon argument preserves exact literal value at '..index) end
response_override=nil
local many=M.empty()
for i=1,4 do
 local r=clone(provision); r.launch_request_id='launch'..i; r.worker_id='worker'..i
 local c=clone(context); c.handle='handle'..i; c.operation_id='op'..i
 local _,nextRegistry=M.prepare(many,r,record,c); check(nextRegistry~=nil,'host slot admitted'); many=nextRegistry
end
local fifth=clone(provision); fifth.launch_request_id='launch5'; fifth.worker_id='worker5'
local fifthContext=clone(context); fifthContext.handle='handle5'; fifthContext.operation_id='op5'
check(select(3,M.prepare(many,fifth,record,fifthContext)).resource=='host_operations','fifth concurrent host operation rejected')
local uncertainCompact=M.settle(compactClaim,compactOp,{status='uncertain'})
local compactRetry=M.prepare(uncertainCompact,grant,nil,granted)
local cleanupResult
M.execute(compactRetry,function(value) cleanupResult=value end)
check(calls[#calls].argv[5]=='reconcile_compact','uncertain cleanup is read-only reconciliation')
check(cleanupResult.status=='uncertain','unproven cleanup remains uncertain')
local refusal={status='full',resource='capacity_admission',current=1,limit=1,admission_refused=true}
for _,sample in ipairs({{request=ackRequest,op=ackOp,registry=ackClaim,context=context},{request=publish,op=manifestOp,registry=manifestClaim,context=context},{request=grant,op=compactOp,registry=compactClaim,context=granted}})do
 local released,proof=M.settle(sample.registry,sample.op,refusal)
 check(proof.status=='full' and proof.payload.retryable and proof.payload.effect_started==false and released.generations.handle.active==nil,'fresh target admission refusal conclusively releases generation claim')
 local retry=M.prepare(released,sample.request,nil,sample.context)
 check(retry and not retry.reconcile,'same immutable publication or compaction may re-enter after initial lock refusal')
 local unknown=M.settle(sample.registry,sample.op,{status='uncertain'})
 local reconcile,reconcileRegistry=M.prepare(unknown,sample.request,nil,sample.context)
 local retained,result=M.settle(reconcileRegistry,reconcile,refusal)
 check(result.status=='uncertain' and retained.generations.handle.writes[reconcile.key].status=='uncertain','matching admission refusal cannot demote an older uncertain effect')
end
local retainedProvision,provisionRefusal=M.settle(intent,op,refusal)
check(provisionRefusal.status=='uncertain' and retainedProvision.generations.handle.writes[op.key].status=='uncertain','provisioning cannot claim no effects after creating its directory')
-- Small coordinator fixtures exercise the real closed codecs and original-byte framing.
do
 local expected=clone(binding);expected.mailbox_handle='handle'
 expected.capabilities={'report-files-v1','coordinator-control-v1'}
 local ownerToken=string.rep('ab',32)
 local eventId=C.sha256('handle:report:1')
 local common='"logical_session_id":"session","worker_id":"worker","worker_generation":1,"launch_request_id":"launch","work_id":"work",'
 local owner='"owner_id":"owner","owner_generation":1,"activation_token":"'..ownerToken..'",'
 local fixtures={
  {direction='reply',bytes='{ '..common..'"version":1,"message_id":"activate","reply_seq":1,"action_id":"activation","action_revision":2,"kind":"coordinator_activation","payload":{'..owner..'"instructions":"Finish\\nthen release \\u2713"}}\n',field='instructions',maximum=C.LIMITS.payload_string},
  {direction='reply',bytes='{\n'..common..'"version":1,"message_id":"retire","reply_seq":2,"action_id":"retirement","action_revision":3,"kind":"coordinator_retirement","payload":{'..owner..'"reason":"Owner requested retirement"}} ',field='reason',maximum=1024},
  {direction='report',bytes='{ '..common..'"enrolment_token":"'..binding.enrolment_token..'","version":3,"event_id":"'..eventId..'","seq":1,"action_id":"activation","action_revision":2,"kind":"COORDINATOR_RELEASE","payload":{'..owner..'"quiescent":true}}\n'},
 }
 local ordinary=clone(binding);ordinary.version=3;ordinary.event_id=eventId;ordinary.seq=1;ordinary.kind='REGISTER'
 ordinary.payload={capabilities={'report-files-v1','native-ask-v1','worker-poll-v1','argv-v1','coordinator-control-v1','check-runner-v1'}}
 local allCapabilities=clone(expected);allCapabilities.capabilities=clone(ordinary.payload.capabilities)
 check(C.decode_report(runtime.json.encode(ordinary),allCapabilities)~=nil,'REGISTER accepts a sixth explicit capability')
 table.insert(ordinary.payload.capabilities,'release-manager-v1');allCapabilities.capabilities=clone(ordinary.payload.capabilities)
 check(C.decode_report(runtime.json.encode(ordinary),allCapabilities)~=nil,'REGISTER accepts a seventh explicit capability')
 table.insert(ordinary.payload.capabilities,'coordinator-control-v1')
 check(C.decode_report(runtime.json.encode(ordinary),allCapabilities)==nil,'REGISTER rejects an eighth capability')
 table.remove(ordinary.payload.capabilities)
 ordinary.payload.capabilities[4]='coordinator-control-v1'
 check(C.decode_report(runtime.json.encode(ordinary),allCapabilities)==nil,'REGISTER rejects duplicate control capability')
 ordinary.payload.capabilities={'report-files-v1','check-runner-v1'}
 check(select(2,C.decode_report(runtime.json.encode(ordinary),expected)).code=='binding_mismatch','REGISTER cannot claim an unprovisioned check-runner-v1')
 local legacy=clone(expected);legacy.capabilities=nil
 ordinary.payload.capabilities={'report-files-v1'}
 check(C.decode_report(runtime.json.encode(ordinary),legacy)~=nil,'ordinary legacy registration remains usable without control capability')
 ordinary.kind='HEARTBEAT';ordinary.payload={state='working'}
 check(C.decode_report(runtime.json.encode(ordinary),legacy)~=nil,'ordinary legacy reports remain usable without control capability')
for _,pct in ipairs({0,100}) do
 ordinary.kind='READY';ordinary.payload={state='idle',context_used_pct=pct}
 check(C.decode_report(runtime.json.encode(ordinary),legacy)~=nil,'READY accepts context_used_pct '..pct)
 ordinary.kind='HEARTBEAT';ordinary.payload={state='working',context_used_pct=pct}
 check(C.decode_report(runtime.json.encode(ordinary),legacy)~=nil,'HEARTBEAT accepts context_used_pct '..pct)
end
for _,bad in ipairs({-1,101,42.5,'42',true}) do
 ordinary.kind='READY';ordinary.payload={state='idle',context_used_pct=bad}
 check(C.decode_report(runtime.json.encode(ordinary),legacy)==nil,'READY rejects context_used_pct '..tostring(bad))
 ordinary.kind='HEARTBEAT';ordinary.payload={state='working',context_used_pct=bad}
 check(C.decode_report(runtime.json.encode(ordinary),legacy)==nil,'HEARTBEAT rejects context_used_pct '..tostring(bad))
end
ordinary.kind='WAITING';ordinary.payload={reason='wait',context_used_pct=10}
check(C.decode_report(runtime.json.encode(ordinary),legacy)==nil,'context_used_pct is rejected outside READY and HEARTBEAT')
ordinary.kind='READY';ordinary.payload={state='idle'}
check(C.decode_report(runtime.json.encode(ordinary),legacy)~=nil,'READY without context_used_pct remains valid')
 local ordinaryReply=assert(C.strict_decode(fixtures[1].bytes))
 ordinaryReply.kind='report_request';ordinaryReply.payload={request_id='request',requested_kind='HEARTBEAT',reason='progress'}
 check(C.decode_reply(runtime.json.encode(ordinaryReply),legacy)~=nil,'ordinary legacy replies remain usable without control capability')
 -- Landing request/result/grant schemas stay exactly in step with ORCH+ transport.
 ordinary.kind='LANDING_REQUEST';ordinary.payload={checkpoint_id='cp',project_id='project',repo_ref='repo',target_ref='main',target_revision='base',source_ref='work',source_revision='rev'}
 check(C.decode_report(runtime.json.encode(ordinary),legacy)~=nil,'LANDING_REQUEST accepts the exact artifact and target')
 ordinary.action_id='action';ordinary.action_revision=1
 check(C.decode_report(runtime.json.encode(ordinary),legacy)==nil,'LANDING_REQUEST rejects action correlation')
 ordinary.action_id=nil;ordinary.action_revision=nil;ordinary.payload.source_ref=nil
 check(C.decode_report(runtime.json.encode(ordinary),legacy)==nil,'LANDING_REQUEST requires its exact source ref')
 local function landingResult(fields,correlated)
  local payload={landing_id='landing',grant_id='grant',project_id='project',repo_ref='repo',target_ref='main',target_revision='base',source_revision='rev',evidence=runtime.json.array()}
  for key,value in pairs(fields) do payload[key]=value end
  ordinary.kind='LANDING_RESULT';ordinary.payload=payload
  if correlated~=false then ordinary.action_id='action';ordinary.action_revision=1 end
  local decoded=C.decode_report(runtime.json.encode(ordinary),legacy)
  ordinary.action_id=nil;ordinary.action_revision=nil
  return decoded
 end
 for _,fields in ipairs({{outcome='landed',result_revision='head'},{outcome='rejected',reason='conflict'},{outcome='stale_target',observed_target_revision='moved'},{outcome='uncertain',reason='timeout'}}) do
  check(landingResult(fields)~=nil,'LANDING_RESULT accepts exact '..fields.outcome..' fields')
 end
 for _,fields in ipairs({{outcome='landed'},{outcome='landed',result_revision='head',reason='extra'},{outcome='rejected'},{outcome='rejected',reason='x',result_revision='head'},
  {outcome='stale_target'},{outcome='stale_target',observed_target_revision='base'},{outcome='uncertain'},{outcome='failed',reason='legacy'}}) do
  check(landingResult(fields)==nil,'LANDING_RESULT rejects '..fields.outcome..' with mismatched outcome fields')
 end
 check(landingResult({outcome='landed',result_revision='head'},false)==nil,'LANDING_RESULT requires its exact grant action correlation')
 local landingReply=clone(ordinaryReply);landingReply.kind='landing_grant'
 landingReply.payload={landing_id='landing',grant_id='grant',project_id='project',checkpoint_id='cp',repo_ref='repo',target_ref='main',target_revision='base',source_ref='work',source_revision='rev',
  builder_work_id='builder-work',review_id='review',reviewer_family='openai',proof={mode='cross_family_review',artifact_revision='rev',review_id='review',check_refs=runtime.json.array()}}
 local releaseManager=clone(legacy);releaseManager.capabilities={'report-files-v1','release-manager-v1'}
 check(C.decode_reply(runtime.json.encode(landingReply),releaseManager)~=nil,'landing_grant names the exact landing, target head, source, builder, review and proof')
 check(select(2,C.decode_reply(runtime.json.encode(landingReply),legacy)).code=='binding_mismatch','landing_grant requires provisioned release-manager-v1')
 check(select(2,C.decode_reply(runtime.json.encode(landingReply),expected)).code=='binding_mismatch','coordinator control does not imply release-manager-v1')
 landingReply.payload.proof.mode='worker-attested'
 check(C.decode_reply(runtime.json.encode(landingReply),releaseManager)==nil,'landing_grant proof mode is a closed enum')
 landingReply.payload.proof.mode='helper_checks';landingReply.payload.proof.check_refs={'check-1'}
 check(C.decode_reply(runtime.json.encode(landingReply),releaseManager)~=nil,'landing_grant carries helper-check proof references')
 landingReply.payload.reviewer_family='OpenAI'
 check(C.decode_reply(runtime.json.encode(landingReply),releaseManager)==nil,'reviewer family uses the declared family grammar')
 landingReply.payload.reviewer_family='openai';landingReply.payload.builder_work_id=nil
 check(C.decode_reply(runtime.json.encode(landingReply),releaseManager)==nil,'landing_grant requires the builder work ID')
 landingReply.payload={landing_id='landing',grant_id='grant',project_id='project',checkpoint_id='cp',repo_ref='repo',target_ref='main',target_revision='base',source_ref='work',source_revision='rev'}
 check(C.decode_reply(runtime.json.encode(landingReply),releaseManager)==nil,'a 0.3.0 landing_grant without review binding and proof is refused')
 local refreshReply=clone(ordinaryReply);refreshReply.kind='landing_refresh'
 refreshReply.payload={landing_id='landing',project_id='project',repo_ref='repo',target_ref='main',expected_revision='base',current_revision='moved',reason='Target moved; refresh against current_revision.'}
 check(C.decode_reply(runtime.json.encode(refreshReply),legacy)~=nil,'landing_refresh names the exact landing, expected head and current head')
 refreshReply.payload.current_revision=nil
 check(C.decode_reply(runtime.json.encode(refreshReply),legacy)==nil,'landing_refresh rejects a missing current head')
 refreshReply.payload.current_revision='moved';refreshReply.payload.grant_id='grant'
 check(C.decode_reply(runtime.json.encode(refreshReply),legacy)==nil,'landing_refresh is closed and carries no grant')
 for _,fixture in ipairs(fixtures) do
  local decode=if fixture.direction=='report' then C.decode_report else C.decode_reply
  for _,capabilities in ipairs({false,{}, {'report-files-v1'}}) do
   local unprovisioned=clone(expected);unprovisioned.capabilities=capabilities
   local result,diagnostic=decode(fixture.bytes,unprovisioned)
   check(result==nil and diagnostic.code=='binding_mismatch','coordinator control requires explicitly provisioned capability')
  end
  local result,diagnostic=decode(fixture.bytes,legacy)
  check(result==nil and diagnostic.code=='binding_mismatch','legacy binding cannot silently acquire coordinator control')
  local envelope=assert(decode(fixture.bytes,expected))
  check(envelope.payload.activation_token==ownerToken and envelope.payload.owner_id=='owner' and envelope.payload.owner_generation==1,'typed coordinator identity retained')
  local frame=assert(C.frame(fixture.bytes,fixture.direction,expected))
  check(#frame.chunks==1 and #frame.manifest<=C.LIMITS.control and #frame.chunks[1]<=C.LIMITS.chunk,'small coordinator fixture stays within original framing bounds')
  local pool=C.new_reassembler()
  assert(C.begin_assembly(pool,frame.manifest,expected,C.sha256(frame.manifest)))
  local assembled=assert(C.push_chunk(pool,frame.chunks[1],expected,C.sha256(frame.chunks[1])))
  check(assembled.complete and assembled.bytes==fixture.bytes and assembled.sha256==frame.message_sha256,'coordinator framing preserves exact whitespace and escaped bytes')
  check(pool.active==0 and pool.bytes==0,'coordinator completion releases bounded assembly')
  local function reject(candidate,message,code)
   local result,diagnostic=decode(runtime.json.encode(candidate),expected)
   check(result==nil and diagnostic.code==(code or 'invalid_schema'),message)
  end
  for key in pairs(envelope.payload) do
   local bad=clone(envelope);bad.payload[key]=nil
   reject(bad,'coordinator payload requires '..key)
  end
  for _,payload in ipairs({{},runtime.json.array(),false,'free text'}) do
   local bad=clone(envelope);bad.payload=payload
   reject(bad,'coordinator payload is an exact object')
  end
  for _,key in ipairs({'extra','action_id','action_revision'}) do
   local bad=clone(envelope);bad.payload[key]='unissued'
   reject(bad,'coordinator payload cannot carry extra or nested action fields')
  end
  for _,value in ipairs({'',string.rep('a',63),string.rep('a',65),string.rep('A',64),string.rep('g',64),false}) do
   local bad=clone(envelope);bad.payload.activation_token=value
   reject(bad,'activation token is exactly 64 lowercase hex bytes')
  end
  for _,value in ipairs({'', 'owner/path',string.rep('o',97),false}) do
   local bad=clone(envelope);bad.payload.owner_id=value
   reject(bad,'owner identity uses existing bounded ID grammar')
  end
  for _,value in ipairs({0,-1,1.5,'1',9007199254740992}) do
   local bad=clone(envelope);bad.payload.owner_generation=value
   reject(bad,'owner generation is a positive safe integer')
  end
  for _,key in ipairs({'action_id','action_revision'}) do
   local bad=clone(envelope);bad[key]=nil
   reject(bad,'coordinator requires both action correlation fields')
  end
  local bad=clone(envelope);bad.action_id=nil;bad.action_revision=nil
  reject(bad,'coordinator cannot omit action correlation')
  for _,value in ipairs({0,-1,1.5,'2',9007199254740992}) do
   bad=clone(envelope);bad.action_revision=value
   reject(bad,'coordinator action revision is a positive safe integer')
  end
  bad=clone(envelope);bad.action_id='invalid/action'
  reject(bad,'coordinator action identity uses existing ID grammar')
  bad=clone(envelope);bad.extra=true
  reject(bad,'coordinator envelope remains closed')
  bad=clone(envelope);bad.worker_generation=2
  reject(bad,'coordinator binding rejects another worker generation','binding_mismatch')
  if fixture.field then
   for _,value in ipairs({'',false,string.rep('x',fixture.maximum+1)}) do
    bad=clone(envelope);bad.payload[fixture.field]=value
    reject(bad,'coordinator text obeys its existing nonempty byte bound')
   end
   local bounded=clone(envelope);bounded.payload[fixture.field]=string.rep('x',fixture.maximum)
   check(decode(runtime.json.encode(bounded),expected)~=nil,'coordinator text accepts its unchanged exact byte bound')
   bad=clone(envelope);bad.gate_id='gate';bad.gate_revision=1
   reject(bad,'coordinator grants cannot smuggle owner decision gate fields')
  else
   for _,value in ipairs({false,'true',1}) do
    bad=clone(envelope);bad.payload.quiescent=value
    reject(bad,'release requires literal true cooperative quiescence')
   end
   bad=clone(envelope);bad.handover_id='handover';bad.handover_token=binding.enrolment_token
   reject(bad,'release cannot smuggle acceptance handover fields')
   local retirementRelease=clone(envelope);retirementRelease.action_id='retirement';retirementRelease.action_revision=3
   check(decode(runtime.json.encode(retirementRelease),expected)~=nil,'release can correlate an activation or retirement action; authority validates the issued grant')
  end
  for _,bytes in ipairs({
   (fixture.bytes:gsub('"owner_generation":1','"owner_generation":null')),
   (fixture.bytes:gsub('"owner_generation":1','"owner_generation":1,"owner_generation":1')),
  }) do
   local result,diagnostic=decode(bytes,expected)
   check(result==nil and diagnostic.code=='invalid_schema','coordinator exact JSON rejects null and duplicate payload keys')
  end
 end
end
-- 0.4.0 report and reply kinds (Contracts C/D): exact round trips through the closed codecs and
-- original-byte framing, closed payloads, action correlation and capability gates.
do
 -- Payload copies must keep empty JSON arrays distinct from empty objects.
 local function clone(value)
  if type(value)~='table' then return value end
  if next(value)==nil then return if runtime.json.encode(value)=='[]' then runtime.json.array() else {} end
  local out={}; for k,v in pairs(value) do out[k]=clone(v) end; return out
 end
 local function same(a,b)
  if type(a)~=type(b) then return false end
  if type(a)~='table' then return a==b end
  for k,v in pairs(a) do if not same(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
 end
 local full=clone(binding);full.mailbox_handle='handle'
 full.capabilities={'report-files-v1','worker-poll-v1','argv-v1','check-runner-v1','release-manager-v1'}
 local plain=clone(full);plain.capabilities={'report-files-v1','worker-poll-v1','argv-v1'}
 local head=string.rep('a',40)
 local function report(kind,payload,action)
  local r=clone(binding);r.version=3;r.event_id=C.sha256('handle:report:1');r.seq=1;r.kind=kind;r.payload=clone(payload)
  if action then r.action_id='action';r.action_revision=1 end
  return r
 end
 local function reply(kind,payload)
  local r=clone(binding);r.enrolment_token=nil;r.version=1;r.message_id='message';r.reply_seq=1;r.action_id='action';r.action_revision=1;r.kind=kind;r.payload=clone(payload)
  return r
 end
 local function decoder(value) return if value.message_id then C.decode_reply else C.decode_report end
 local function accepted(value,expected,message)
  local bytes=runtime.json.encode(value)
  local decoded=decoder(value)(bytes,expected)
  check(decoded~=nil and same(decoded,value),message)
  return bytes
 end
 local function roundtrip(value,expected,message)
  local bytes=accepted(value,expected,message..' round-trips exactly')
  local direction=if value.message_id then 'reply' else 'report'
  local frame=assert(C.frame(bytes,direction,expected))
  local pool=C.new_reassembler()
  assert(C.begin_assembly(pool,frame.manifest,expected,C.sha256(frame.manifest)))
  local assembled
  for _,chunk in ipairs(frame.chunks) do assembled=assert(C.push_chunk(pool,chunk,expected,C.sha256(chunk))) end
  check(assembled.complete and assembled.bytes==bytes and same(assembled.envelope,value),message..' survives original-byte framing')
 end
 local function refused(value,expected,message,code)
  local decoded,diagnostic=decoder(value)(runtime.json.encode(value),expected)
  check(decoded==nil and diagnostic.code==(code or 'invalid_schema'),message)
 end
 local function closed(make,payload,expected,name,optional)
  for key in pairs(payload) do
   if not (optional and optional[key]) then
    local bad=clone(payload);bad[key]=nil
    refused(make(bad),expected,name..' requires '..key)
   end
  end
  local bad=clone(payload);bad.extra='unissued'
  refused(make(bad),expected,name..' payload is closed')
 end
 -- CHECK_RESULT: helper-only, check-runner-v1, never action-correlated.
 local checkResult={check_id='t1-c1',argv_sha256=string.rep('b',64),exit_code=0,output_sha256=string.rep('c',64),head=head,ran_at_ms=1730000000000}
 local function checkReport(p) return report('CHECK_RESULT',p) end
 roundtrip(checkReport(checkResult),full,'CHECK_RESULT')
 refused(checkReport(checkResult),plain,'CHECK_RESULT requires provisioned check-runner-v1','binding_mismatch')
 refused(report('CHECK_RESULT',checkResult,true),full,'CHECK_RESULT carries no action correlation')
 closed(checkReport,checkResult,full,'CHECK_RESULT')
 for _,code in ipairs({1,255,-1,-2147483648,4294967295}) do
  local p=clone(checkResult);p.exit_code=code
  accepted(checkReport(p),full,'CHECK_RESULT accepts POSIX and Windows exit code '..code)
 end
 for _,code in ipairs({4294967296,-2147483649,1.5,'0',true}) do
  local p=clone(checkResult);p.exit_code=code
  refused(checkReport(p),full,'CHECK_RESULT rejects exit code '..tostring(code))
 end
 local sha256Head=clone(checkResult);sha256Head.head=string.rep('e',64)
 accepted(checkReport(sha256Head),full,'CHECK_RESULT accepts a SHA-256 repository head')
 for _,value in ipairs({string.rep('A',40),string.rep('a',39),string.rep('a',41),string.rep('a',63),'HEAD'}) do
  local p=clone(checkResult);p.head=value
  refused(checkReport(p),full,'CHECK_RESULT head is a lowercase 40/64-hex object name')
 end
 for _,key in ipairs({'argv_sha256','output_sha256'}) do
  local p=clone(checkResult);p[key]=string.rep('B',64)
  refused(checkReport(p),full,'CHECK_RESULT '..key..' is lowercase hex SHA-256')
 end
 -- CHECKOUT: helper-only checkout facts, check-runner-v1.
 local checkout={worktree_path='/work/tree',common_dir='/work/repo/.git',branch='feature',head=head,base=string.rep('d',40),
  changed_files={'src/a.luau','src/b.luau'},changed_overflow=false,changed_total=2,dirty=true}
 local function checkoutReport(p) return report('CHECKOUT',p) end
 roundtrip(checkoutReport(checkout),full,'CHECKOUT')
 refused(checkoutReport(checkout),plain,'CHECKOUT requires provisioned check-runner-v1','binding_mismatch')
 refused(report('CHECKOUT',checkout,true),full,'CHECKOUT carries no action correlation')
 closed(checkoutReport,checkout,full,'CHECKOUT',{base=true})
 local noBase=clone(checkout);noBase.base=nil
 accepted(checkoutReport(noBase),full,'CHECKOUT base is optional')
 for _,path in ipairs({'C:/work/tree','C:\\work\\tree','\\\\server\\share\\tree'}) do
  local p=clone(checkout);p.worktree_path=path;p.common_dir=path
  accepted(checkoutReport(p),full,'CHECKOUT accepts canonical Windows path '..path)
 end
 for _,path in ipairs({'work/tree','','./tree',string.rep('/',4097)}) do
  local p=clone(checkout);p.worktree_path=path
  refused(checkoutReport(p),full,'CHECKOUT worktree_path is a bounded absolute path')
 end
 local clean=clone(checkout);clean.changed_files=runtime.json.array();clean.changed_total=0;clean.dirty=false
 accepted(checkoutReport(clean),full,'CHECKOUT accepts a clean checkout')
 for _,counts in ipairs({{3,false},{2,true},{1,false}}) do
  local p=clone(checkout);p.changed_total=counts[1];p.changed_overflow=counts[2]
  refused(checkoutReport(p),full,'CHECKOUT overflow flag must agree with changed_total')
 end
 local overflow=clone(checkout);overflow.changed_total=900;overflow.changed_overflow=true
 accepted(checkoutReport(overflow),full,'CHECKOUT reports a truncated sorted prefix with overflow')
 local duplicate=clone(checkout);duplicate.changed_files={'src/a.luau','src/a.luau'}
 refused(checkoutReport(duplicate),full,'CHECKOUT changed paths are unique')
 local many={};for i=1,512 do many[i]=string.format('f%03d',i) end
 local maximum=clone(checkout);maximum.changed_files=many;maximum.changed_total=512
 roundtrip(checkoutReport(maximum),full,'CHECKOUT with exactly 512 changed paths')
 local beyond=clone(maximum);table.insert(beyond.changed_files,'f513');beyond.changed_total=513
 refused(checkoutReport(beyond),full,'CHECKOUT refuses a 513th changed path')
 -- LABEL: labeller worker, correlated to one label_request.
 local label={work_ref='work',class='bugfix',reason='Touches parser tests.'}
 local function labelReport(p) return report('LABEL',p,true) end
 roundtrip(labelReport(label),plain,'LABEL')
 refused(report('LABEL',label),plain,'LABEL requires its label_request correlation')
 closed(labelReport,label,plain,'LABEL',{reason=true})
 for _,value in ipairs({'Bugfix','1fix','bug_fix',string.rep('a',33)}) do
  local p=clone(label);p.class=value
  refused(labelReport(p),plain,'LABEL class uses the route class grammar')
 end
 -- DEPLOY_RESULT: release manager, release-manager-v1, correlated to one deploy_grant.
 local deploy={deploy_id='deploy',attempt_id='attempt-1',landing_id='landing',outcome='deployed',revision=head,evidence={'ci/run/1'}}
 local function deployReport(p) return report('DEPLOY_RESULT',p,true) end
 roundtrip(deployReport(deploy),full,'DEPLOY_RESULT')
 refused(deployReport(deploy),plain,'DEPLOY_RESULT requires provisioned release-manager-v1','binding_mismatch')
 refused(report('DEPLOY_RESULT',deploy),full,'DEPLOY_RESULT requires its deploy_grant correlation')
 closed(deployReport,deploy,full,'DEPLOY_RESULT',{reason=true})
 for _,outcome in ipairs({'held','not_applicable','failed'}) do
  local p=clone(deploy);p.outcome=outcome;p.reason='Owner hold.'
  accepted(deployReport(p),full,'DEPLOY_RESULT accepts outcome '..outcome)
 end
 local landed=clone(deploy);landed.outcome='landed'
 refused(deployReport(landed),full,'DEPLOY_RESULT outcome is a closed enum')
 local evidence=clone(deploy);evidence.evidence={};for i=1,17 do evidence.evidence[i]='e'..i end
 refused(deployReport(evidence),full,'DEPLOY_RESULT evidence is bounded at 16')
 -- REVIEW_RESULT (clean cutover): reviewer findings tied to file and line.
 local finding={finding_id='f1',path='src/a.luau',line=12,summary='Off by one.'}
 local review={review_id='review',round=1,artifact_revision='rev',outcome='changes_required',findings={finding},summary='One issue.'}
 local function reviewReport(p) return report('REVIEW_RESULT',p,true) end
 roundtrip(reviewReport(review),plain,'REVIEW_RESULT')
 refused(report('REVIEW_RESULT',review),plain,'REVIEW_RESULT requires its review_request correlation')
 closed(reviewReport,review,plain,'REVIEW_RESULT',{summary=true})
 local approved={review_id='review',round=2,artifact_revision='rev',outcome='approved',findings=runtime.json.array()}
 accepted(reviewReport(approved),plain,'REVIEW_RESULT approves with no findings')
 refused(reviewReport({artifact_revision='rev',outcome='approved',evidence=runtime.json.array()}),plain,'the 0.3.0 REVIEW_RESULT payload is refused')
 local lineless=clone(review);lineless.findings={{finding_id='f1',path='src/a.luau',summary='File-level.'}}
 accepted(reviewReport(lineless),plain,'a finding line is optional')
 for _,mutate in ipairs({
  function(p) p.findings={finding,clone(finding)} end,
  function(p) p.findings[1].line=0 end,
  function(p) p.findings[1].summary=string.rep('s',401) end,
  function(p) p.findings[1].extra=true end,
  function(p) p.round=0 end,
  function(p) p.outcome='rejected' end,
  function(p) p.findings={};for i=1,33 do p.findings[i]={finding_id='f'..i,path='a',summary='s'} end end,
 }) do
  local p=clone(review);mutate(p)
  refused(reviewReport(p),plain,'REVIEW_RESULT findings and round are closed and bounded')
 end
 local bounded=clone(review);bounded.findings[1].summary=string.rep('s',400)
 accepted(reviewReport(bounded),plain,'a finding summary accepts exactly 400 bytes')
 -- DONE gains an optional relative output_ref.
 local done={checkpoint_id='cp',artifact_revision='rev',summary='done',output_ref='out/report.md'}
 roundtrip(report('DONE',done),plain,'DONE with output_ref')
 for _,value in ipairs({'/abs/report.md','../report.md','out/../../x','C:report.md','out\\report.md','',string.rep('a',257)}) do
  local p=clone(done);p.output_ref=value
  refused(report('DONE',p),plain,'DONE output_ref is a bounded relative path')
 end
 -- review_request: the fixed judge question to a reviewer.
 local request={review_id='review',round=1,question_id='implements_task_v1',builder_work_id='builder-work',task_ref='plan.md#t1',
  source_ref='feature',artifact_revision='rev',scope_paths={'src'},findings_prev=runtime.json.array()}
 local function reviewRequest(p) return reply('review_request',p) end
 roundtrip(reviewRequest(request),plain,'review_request')
 closed(reviewRequest,request,plain,'review_request')
 local planned=clone(request);planned.plan_ref='plans/x.md';planned.plan_revision=string.rep('f',64);planned.findings_prev={finding}
 accepted(reviewRequest(planned),plain,'review_request carries a paired plan reference and prior findings')
 planned.plan_revision=nil
 refused(reviewRequest(planned),plain,'review_request plan reference and revision are paired')
 local question=clone(request);question.question_id='find_problems'
 refused(reviewRequest(question),plain,'review_request asks only the fixed judge question')
 local gated=reviewRequest(request);gated.gate_id='gate';gated.gate_revision=1
 refused(gated,plain,'review_request cannot carry owner decision gate fields')
 -- rework: failed checks and findings back to the builder.
 local rework={review_id='review',round=2,artifact_revision='rev',failed_checks={{check_id='t1-c1',exit_code=1}},findings={finding}}
 local function reworkReply(p) return reply('rework',p) end
 roundtrip(reworkReply(rework),plain,'rework')
 closed(reworkReply,rework,plain,'rework',{review_id=true})
 local checksOnly=clone(rework);checksOnly.review_id=nil;checksOnly.findings=runtime.json.array()
 accepted(reworkReply(checksOnly),plain,'helper-check rework needs no review')
 local tooMany=clone(rework);tooMany.failed_checks={};for i=1,17 do tooMany.failed_checks[i]={check_id='c'..i,exit_code=1} end
 refused(reworkReply(tooMany),plain,'rework failed checks are bounded at 16')
 -- deploy_grant: exactly one deploy attempt for exactly one revision, release-manager-v1.
 local grant={deploy_id='deploy',attempt_id='attempt-1',landing_id='landing',revision=head,target_ref='production'}
 local function deployGrant(p) return reply('deploy_grant',p) end
 roundtrip(deployGrant(grant),full,'deploy_grant')
 refused(deployGrant(grant),plain,'deploy_grant requires provisioned release-manager-v1','binding_mismatch')
 closed(deployGrant,grant,full,'deploy_grant')
 -- label_request: the labeller's closed class choice.
 local labelRequest={work_ref='work',classes={'bugfix','docs'},text='Fix the parser.'}
 local function labelReply(p) return reply('label_request',p) end
 roundtrip(labelReply(labelRequest),plain,'label_request')
 closed(labelReply,labelRequest,plain,'label_request')
 for _,classes in ipairs({runtime.json.array(),{'bugfix','bugfix'},{'Bugfix'}}) do
  local p=clone(labelRequest);p.classes=classes
  refused(labelReply(p),plain,'label_request classes are 1..32 unique class names')
 end
end
do
 local Adapter=load('mailbox_adapter')
 local sshRecord=clone(record);sshRecord.backend='ssh-command';sshRecord.host='target';sshRecord.target_os='linux';sshRecord.target_shell='sh'
 local before=#calls
 local target,why=Adapter.target(sshRecord,context)
 check(target==nil and why=='unsupported_capability','direct target construction refuses a new SSH-managed mailbox')
 local blocked,registry,result=M.prepare(empty,provision,sshRecord,context)
 check(not blocked and not registry and result.error.code=='unsupported_capability' and #calls==before,'new SSH-managed provisioning has no transport effects')
 for _,backend in ipairs({'native-agent','local-terminal'})do
  local candidate=if backend=='native-agent' then clone(native) else clone(record)
  candidate.host='attached-target';candidate.target_os='windows';candidate.target_shell='cmd.exe'
  local hostContext=clone(context);hostContext.os='windows';hostContext.shell='cmd.exe'
  local planned,prepared=M.prepare(empty,provision,candidate,hostContext)
  check(planned and prepared and planned.target.os=='linux' and planned.target.shell=='sh',backend..' uses attached execution-host OS rather than client or SSH target hints')
  local outcome;M.execute(planned,function(value)outcome=value end)
  check(outcome.status=='provisioned' and calls[#calls].argv[1]=='sh',backend..' executes helper on the same attached host without SSH')
 end
 local windowsRecord=clone(record)
 windowsRecord.mailbox.permitted_root='C:\\mail';windowsRecord.mailbox.helper_path='C:\\tools\\target.ps1';windowsRecord.mailbox.producer_helper_path='C:\\tools\\worker.ps1'
 local windowsContext=clone(context);windowsContext.host_os='windows';windowsContext.host_shell='powershell.exe';windowsContext.os='linux'
 local windowsOp=M.prepare(empty,provision,windowsRecord,windowsContext)
 check(windowsOp and windowsOp.target.kind=='powershell','same-host Windows mailbox uses execution-host shell')
 response_override='provisioned\n'
 M.execute(windowsOp,function(value)result=value end)
 check(result.status=='provisioned' and calls[#calls].argv[1]=='powershell.exe','same-host Windows helper never uses client POSIX hints')
 response_override=nil
 -- Construct a historical persisted generation using its existing digest format.
 local function legacy(source)
  local saved=clone(source);local g=saved.generations.handle
  g.backend='ssh-command';g.target.backend='ssh-command';g.target.host='target'
  local parts={'report-files-v1:policy:1'}
  local function add(value)
   local text=if type(value)=='number' then string.format('%.0f',value) else value or ''
   table.insert(parts,tostring(#text)..':'..text)
  end
  for _,key in ipairs({'logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token'})do add(g.binding[key])end
  add(g.binding.mailbox_handle);add(g.record_id);add(g.record_revision);add(g.wake);add(g.backend)
  for _,capability in ipairs(g.capabilities)do add(capability)end
  for _,key in ipairs({'root','helper','producer_helper','worker_identity','os','shell','kind','backend','host','user','key_path','host_os','host_shell'})do add(g.target[key])end
  g.binding_digest=C.sha256(table.concat(parts,''))
  local write=g.writes.provision
  write.bytes=runtime.json.encode({version=1,handle='handle',binding_digest=g.binding_digest,binding=g.binding})
  if write.result and write.result.payload then write.result.payload.binding_digest=g.binding_digest end
  check(M.validate(saved)~=nil,'historical SSH generation remains valid persisted authority')
  return saved
 end
 local saved=legacy(reg);local savedBytes=runtime.json.encode(saved)
 check(M.get(saved,'handle').backend=='ssh-command','launch inspection exposes retained SSH mailbox backend')
 check(select(3,M.prepare(saved,provision,sshRecord,context)).status=='provisioned','completed legacy provision returns its exact retained result')
 for _,mutation in ipairs({{ackRequest,context},{publish,context},{grant,granted},{retirement,retirementContext}})do
  local operation,nextRegistry,refusal=M.prepare(saved,mutation[1],nil,mutation[2])
  check(not operation and not nextRegistry and refusal.error.code=='unsupported_capability' and refusal.error.message:find('original build before cutover',1,true)~=nil,'legacy SSH generation holds new writes with actionable settlement guidance')
 end
 check(runtime.json.encode(saved)==savedBytes,'rejected SSH writes never erase or rewrite retained generations')
 for _,operation in ipairs({op,ackOp,manifestOp,compactOp,retireOp})do
  local bypass=clone(operation);bypass.target=clone(saved.generations.handle.target);bypass.retire_producer=true
  before=#calls;local timerCount=#timers
  M.execute(bypass,function(value)result=value end)
  check(result.error.code=='unsupported_capability' and #calls==before and #timers==timerCount,'bypassed SSH mutation is refused before subprocess or timer effects')
 end
 local inspection=M.prepare(saved,read,nil,context)
 response_override='missing\n'
 M.execute(inspection,function(value)result=value end)
 check(result.status=='missing' and calls[#calls].argv[1]=='ssh','retained SSH generation permits bounded read-only inspection')
 local unknown=legacy(ambiguous)
 local oldUnknown=runtime.json.encode(unknown)
 local reconciliation,claimed=M.prepare(unknown,ackRequest,nil,context)
 check(reconciliation and reconciliation.reconcile and runtime.json.encode(unknown)==oldUnknown,'unknown legacy ACK prepares readback without changing its retained effect')
 M.execute(reconciliation,function(value)result=value end)
 check(result.status=='uncertain','missing legacy ACK readback never permits a write retry')
 local stillUnknown=M.settle(claimed,reconciliation,result)
 check(stillUnknown.generations.handle.writes['acks/1.json'].status=='uncertain' and stillUnknown.generations.handle.target.backend=='ssh-command','missing readback preserves unknown occupancy and original target')
 response_override='already_published\n'
 M.execute(reconciliation,function(value)result=value end)
 check(result.status=='already_published','exact retained legacy ACK may reconcile proven publication without replay')
 local settled=M.settle(claimed,reconciliation,result)
 check(select(3,M.prepare(settled,ackRequest,nil,context)).status=='already_published','reconciled legacy ACK preserves its exact completed status')
 local pendingLegacy=legacy(recovered)
 local provisionReadback=M.prepare(pendingLegacy,provision,sshRecord,context)
 check(provisionReadback and provisionReadback.reconcile,'legacy uncertain provisioning can only read back its original intent')
 response_override='missing\n'
 M.execute(provisionReadback,function(value)result=value end)
 check(result.status=='uncertain','missing legacy provision readback never starts or replaces its generation')
 response_override=nil
end
return 'mailbox checks: '..checks
