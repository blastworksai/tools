-- Durable, pure report-files-v1 transport planning. Callers persist prepare/settle
-- results before exposing them. No WindowCx, KV write or filesystem effect here.
local Codec = require('./codec')
local Adapter = require('./mailbox_adapter')
local Capabilities = require('./mailbox_capabilities')
local M = {}
local MAX = 9007199254740991
local B = {'logical_session_id','worker_id','worker_generation','launch_request_id','work_id','enrolment_token'}
-- Every unretired generation reserves its full mailbox allowance, so the host allocation
-- (64 MiB/16,384 files over 4 MiB/1,024 files) admits exactly `generations` = 16 live ones.
M.LIMITS = {mailbox_bytes=4194304,mailbox_files=1024,host_bytes=67108864,host_files=16384,generations=16,registry_bytes=4194304,reserved_bytes=262144,deadline_ms=30000,concurrency=4}
assert(M.LIMITS.generations*M.LIMITS.mailbox_bytes<=M.LIMITS.host_bytes and M.LIMITS.generations*M.LIMITS.mailbox_files<=M.LIMITS.host_files,'live generations must fit the host allocation')
local function copy(v)
 if type(v) ~= 'table' then return v end
 local out = {}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local function equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local function err(code) return {status='rejected',error={code=code}} end
local function integer(v,zero) return type(v)=='number' and v%1==0 and v>=(if zero then 0 else 1) and v<=MAX end
local function id(v) return type(v)=='string' and #v>0 and #v<=96 and v:match('^[A-Za-z0-9_-]+$')~=nil end
local function record_id(v) return type(v)=='string' and #v>0 and #v<=256 and v:find('%S')~=nil and v:find('%z')==nil end
local function digest(v) return type(v)=='string' and #v==64 and v:match('^[0-9a-f]+$')~=nil end
local function bound(r,expected)
 for _,k in ipairs(B) do if r[k]~=expected[k] then return false end end
 return true
end
local function decode64(value,maximum)
 if type(value)~='string' or #value==0 or #value>math.ceil(maximum/3)*4 or #value%4~=0 or not value:match('^[A-Za-z0-9+/]*=?=?$') then return nil end
 local ok,raw=pcall(tern.base64.decode,value)
 if not ok or #raw>maximum or tern.base64.encode(raw)~=value then return nil end
 return raw
end
local function closed(value,fields)
 if type(value)~='table' then return false end
 for key in pairs(value) do if not fields[key] then return false end end
 return true
end
function M.selector(s)
 if type(s)~='table' then return nil end
 if s.stream=='report' or s.stream=='reply' then
  if not closed(s,{stream=true,slot=true,part=true,index=true}) or not integer(s.slot) then return nil end
  local directory=if s.stream=='reply' then 'replies/' else 'reports/'
  if s.part=='manifest' and s.index==nil then return directory..string.format('%.0f',s.slot)..'/manifest.json' end
  if s.part=='chunk' and integer(s.index) and s.index<=32 then return directory..string.format('%.0f',s.slot)..'/chunk-'..s.index..'.json' end
 elseif s.stream=='ack' and closed(s,{stream=true,slot=true}) and integer(s.slot) then return 'acks/'..string.format('%.0f',s.slot)..'.json'
 elseif s.stream=='watermark' and closed(s,{stream=true,through_seq=true}) then
  if s.through_seq==nil then return 'watermarks' end
  if integer(s.through_seq) then return 'watermarks/'..string.format('%.0f',s.through_seq)..'.json' end
 end
 return nil
end
local function binding_digest(g)
 local parts={'report-files-v1:policy:1'}
 local function add(v)
  local text=if type(v)=='number' then string.format('%.0f',v) else v or ''
  table.insert(parts,tostring(#text)..':'..text)
 end
 for _,key in ipairs(B) do add(g.binding[key]) end
 add(g.binding.mailbox_handle); add(g.record_id); add(g.record_revision); add(g.wake)
 add(g.backend)
 for _,capability in ipairs(g.capabilities) do add(capability) end
 for _,key in ipairs({'root','helper','producer_helper','worker_identity','os','shell','kind','backend','host','user','key_path','host_os','host_shell'}) do add(g.target[key]) end
 return Codec.sha256(table.concat(parts,''))
end
local function valid_write(g,key,w)
 if not closed(w,{status=true,request=true,bytes=true,reply_seq=true,logical_bytes=true,result=true}) or type(w.request)~='table' or not bound(w.request,g.binding) then return false end
 local r=w.request
 if not id(r.request_id) or not id(r.action_id) or r.schema~=1 or r.origin~='orchplus' then return false end
 local fields={schema=true,origin=true,op=true,request_id=true,action_id=true,origin_binding=true,controller_pane=true,controller_generation=true}
 for _,name in ipairs(B) do fields[name]=true end
 local specific={
  mailbox_provision={'record_id','record_revision','capability'},
  mailbox_publish_ack={'handle','expected_generation','receipt_revision','ack_b64','ack_sha256'},
  mailbox_publish_reply={'handle','expected_generation','message_id','reply_seq','action_revision','reply_sha256','part','index','object_b64','object_sha256'},
  mailbox_retire={'handle','expected_generation','mode','settlement_revision','report_floor','report_chain_sha256','reply_floor','grant_id'},
 }
 if not specific[r.op] then return false end
 for _,name in ipairs(specific[r.op]) do fields[name]=true end
 if not closed(r,fields) then return false end
 if r.op=='mailbox_provision' then
  local object=Codec.strict_decode(w.bytes,2048)
  return key=='provision' and r.capability=='report-files-v1' and r.record_id==g.record_id and r.record_revision==g.record_revision and w.reply_seq==nil and w.logical_bytes==nil and equal(object,{version=1,handle=g.binding.mailbox_handle,binding_digest=g.binding_digest,binding=g.binding})
 end
 if r.handle~=g.binding.mailbox_handle or r.expected_generation~=g.binding.worker_generation then return false end
 if r.op=='mailbox_publish_ack' then
  if not integer(r.receipt_revision) or not digest(r.ack_sha256) or decode64(r.ack_b64,2048)~=w.bytes or type(w.bytes)~='string' or Codec.sha256(w.bytes)~=r.ack_sha256 then return false end
  local raw=Codec.strict_decode(w.bytes,2048)
  if type(raw)~='table' then return false end
  local expected=copy(g.binding); expected.seq=raw.seq; expected.event_id=raw.event_id; expected.event_sha256=raw.event_sha256; expected.committed_revision=r.receipt_revision
  local ack=Codec.decode_ack(w.bytes,expected)
  return ack~=nil and key==M.selector({stream='ack',slot=ack.seq}) and ack.event_id==Codec.sha256(r.handle..':report:'..string.format('%.0f',ack.seq)) and w.reply_seq==nil and w.logical_bytes==nil
 elseif r.op=='mailbox_publish_reply' then
  if not id(r.message_id) or not integer(r.reply_seq) or not integer(r.action_revision) or not digest(r.reply_sha256) or not digest(r.object_sha256) or decode64(r.object_b64,4096)~=w.bytes or type(w.bytes)~='string' or Codec.sha256(w.bytes)~=r.object_sha256 then return false end
  local object=Codec.decode_object(w.bytes)
  return object~=nil and object.direction=='reply' and object.mailbox_handle==r.handle and object.slot==r.reply_seq and object.message_id==r.message_id and object.message_sha256==r.reply_sha256 and object.type==r.part and object.index==r.index and key==M.selector({stream='reply',slot=r.reply_seq,part=r.part,index=r.index}) and w.reply_seq==r.reply_seq and w.logical_bytes==(if object.type=='manifest' then object.message_bytes else nil)
 elseif r.op=='mailbox_retire' then
  return key=='grant:'..tostring(r.grant_id) and id(r.grant_id) and (r.mode=='compact' or r.mode=='retire') and integer(r.settlement_revision) and integer(r.report_floor,true) and integer(r.reply_floor,true) and digest(r.report_chain_sha256) and w.bytes==nil and w.reply_seq==nil and w.logical_bytes==nil
 end
 return false
end
function M.empty() return {version=1,generations={}} end
function M.location(registry,handle)
 local g=registry.generations[handle]
 if not g or g.status~='provisioned' then return nil end
 return {root=g.target.root,helper=g.target.helper,producer_helper=g.target.producer_helper,handle=handle,binding=copy(g.binding),wake=g.wake}
end
function M.get(registry,handle)
 local g=registry.generations[handle]
 if not g then return nil end
 local binding={}; for _,key in ipairs(B) do binding[key]=g.binding[key] end
 return {binding=binding,record_id=g.record_id,record_revision=g.record_revision,backend=g.backend,phase=g.status,location=M.location(registry,handle),capabilities=copy(g.capabilities)}
end
function M.validate(registry)
 if not closed(registry,{version=true,generations=true}) or registry.version~=1 or type(registry.generations)~='table' then return nil,err('journal_corrupt') end
 local live,active=0,0
 for handle,g in pairs(registry.generations) do
  if not id(handle) or type(g)~='table' or type(g.binding)~='table' or g.binding.mailbox_handle~=handle or type(g.writes)~='table' or not record_id(g.record_id) or not integer(g.record_revision,true) or not digest(g.binding_digest) or not integer(g.report_floor,true) or not integer(g.reply_floor,true) or not integer(g.settlement_revision,true) then return nil,err('journal_corrupt') end
  if not closed(g,{binding=true,record_id=true,record_revision=true,target=true,backend=true,capabilities=true,wake=true,status=true,writes=true,report_floor=true,reply_floor=true,settlement_revision=true,binding_digest=true,active=true,report_chain_sha256=true,frozen=true}) or not closed(g.binding,{logical_session_id=true,worker_id=true,worker_generation=true,launch_request_id=true,work_id=true,enrolment_token=true,mailbox_handle=true}) or not Capabilities.valid_set(g.backend,g.wake,g.capabilities) or (g.report_chain_sha256~=nil and not digest(g.report_chain_sha256)) or (g.frozen~=nil and type(g.frozen)~='boolean') then return nil,err('journal_corrupt') end
  for _,key in ipairs(B) do
   local value=g.binding[key]
   if key=='worker_generation' then if not integer(value) then return nil,err('journal_corrupt') end
   elseif key=='enrolment_token' then if type(value)~='string' or #value<16 or #value>128 or not value:match('^[A-Za-z0-9_-]+$') then return nil,err('journal_corrupt') end
   elseif not id(value) then return nil,err('journal_corrupt') end
  end
  if g.status~='intent' and g.status~='provisioned' and g.status~='retired' then return nil,err('journal_corrupt') end
  if g.status~='retired' then
   live+=1
   if not Adapter.validate_target(g.target) or g.backend~=g.target.backend or binding_digest(g)~=g.binding_digest then return nil,err('journal_corrupt') end
  end
  if g.status=='retired' and (g.target~=nil or g.active~=nil or next(g.writes)~=nil) then return nil,err('journal_corrupt') end
  if g.active and (not closed(g.active,{id=true,key=true,generation=true}) or not id(g.active.id) or type(g.active.key)~='string' or g.active.generation~=g.binding.worker_generation or g.active.key~='read' and not g.writes[g.active.key]) then return nil,err('journal_corrupt') end
  if g.active then active+=1 end
  for key,w in pairs(g.writes) do
   if type(key)~='string' or type(w)~='table' or type(w.request)~='table' or (w.status~='active' and w.status~='uncertain' and w.status~='settled' and w.status~='prepared') or w.status=='settled' and type(w.result)~='table' then return nil,err('journal_corrupt') end
   if not valid_write(g,key,w) or w.status=='active' and (not g.active or g.active.key~=key) or g.active and g.active.key==key and w.status~='active' then return nil,err('journal_corrupt') end
   if w.result~=nil and type(w.result)~='table' then return nil,err('journal_corrupt') end
   if w.result then
    local status=w.result.status
    if status~='published' and status~='already_published' and status~='provisioned' and status~='compacted' and status~='retired' and status~='uncertain' and status~='rejected' and status~='missing' and status~='incomplete' and status~='full' then return nil,err('journal_corrupt') end
    if status=='provisioned' and (w.request.op~='mailbox_provision' or type(w.result.payload)~='table' or w.result.payload.handle~=handle or w.result.payload.binding_digest~=g.binding_digest or not equal(w.result.payload.capabilities,g.capabilities)) then return nil,err('journal_corrupt') end
    if (status=='compacted' or status=='retired') and (w.request.op~='mailbox_retire' or status~= (if w.request.mode=='compact' then 'compacted' else 'retired')) then return nil,err('journal_corrupt') end
   end
  end
  if g.status=='provisioned' and (not g.writes.provision or g.writes.provision.status~='settled' or not g.writes.provision.result or g.writes.provision.result.status~='provisioned') then return nil,err('journal_corrupt') end
 end
 if live>M.LIMITS.generations or active>4 or #tern.json.encode(registry)>4194304 then return nil,err('journal_corrupt') end
 return registry,nil
end
function M.prepare(registry,request,record,context)
 local function reject(code) return nil,nil,err(code) end
 if type(registry)~='table' or registry.version~=1 or type(registry.generations)~='table' then return reject('journal_corrupt') end
 if type(request)~='table' or type(context)~='table' or not id(context.operation_id) or not id(request.request_id) then return reject('invalid_schema') end
 if #tern.json.encode(request)>8192 then return reject('oversize') end
 local fields={schema=true,origin=true,op=true,request_id=true,action_id=true,origin_binding=true,controller_pane=true,controller_generation=true}
 for _,k in ipairs(B) do fields[k]=true end
 local specific={
  mailbox_provision={'record_id','record_revision','capability'},
  mailbox_read={'handle','expected_generation','selector'},
  mailbox_publish_ack={'handle','expected_generation','receipt_revision','ack_b64','ack_sha256'},
  mailbox_publish_reply={'handle','expected_generation','message_id','reply_seq','action_revision','reply_sha256','part','index','object_b64','object_sha256'},
  mailbox_retire={'handle','expected_generation','mode','settlement_revision','report_floor','report_chain_sha256','reply_floor','grant_id'},
 }
 if not specific[request.op] then return reject('invalid_schema') end
 for _,k in ipairs(specific[request.op]) do fields[k]=true end
 if not closed(request,fields) then return reject('invalid_schema') end
 local next=copy(registry)
 local handle=request.handle
 local g
 if request.op=='mailbox_provision' then
  if request.capability~='report-files-v1' or not id(context.handle) or not record_id(request.record_id) or not integer(request.record_revision,true) then return reject('invalid_schema') end
  for _,k in ipairs(B) do
   local v=request[k]
   if k=='worker_generation' then if not integer(v) then return reject('invalid_schema') end
   elseif k=='enrolment_token' then if type(v)~='string' or #v<16 or #v>128 or not v:match('^[A-Za-z0-9_-]+$') then return reject('invalid_schema') end
   elseif not id(v) then return reject('invalid_schema') end
  end
  for h,existing in pairs(next.generations) do
   if existing.binding.launch_request_id==request.launch_request_id and existing.binding.logical_session_id==request.logical_session_id then handle=h; g=existing; break end
  end
  if g then
   if not bound(request,g.binding) or g.record_id~=request.record_id or g.record_revision~=request.record_revision then return reject('content_conflict') end
  else
   handle=context.handle
   if next.generations[handle] then return reject('content_conflict') end
   local live=0; for _,v in pairs(next.generations) do if v.status~='retired' then live+=1 end end
   if live>=M.LIMITS.generations then return nil,nil,{status='full',resource='mailbox_allocation',current=live*M.LIMITS.mailbox_bytes,limit=M.LIMITS.host_bytes} end
   if not record or record.id~=request.record_id then return reject('binding_mismatch') end
   local capabilities=Capabilities.validate(record)
   if not capabilities then return reject('unsupported_capability') end
   local target,why=Adapter.target(record,context)
   if not target then return reject(why) end
   local binding={mailbox_handle=handle}; for _,k in ipairs(B) do binding[k]=request[k] end
   g={binding=binding,record_id=request.record_id,record_revision=request.record_revision,target=target,backend=record.backend,capabilities=capabilities,wake=record.mailbox.wake,status='intent',writes={},report_floor=0,reply_floor=0,settlement_revision=0}
   g.binding_digest=binding_digest(g)
   next.generations[handle]=g
  end
 else
  if not id(handle) or not integer(request.expected_generation) then return reject('invalid_schema') end
  g=next.generations[handle]
  if not g or not bound(request,g.binding) or request.expected_generation~=g.binding.worker_generation then return reject('binding_mismatch') end
 end
 if g.status=='retired' then return reject('generation_retired') end
 if g.frozen then return reject('content_conflict') end
 local op={id=context.operation_id,request_id=request.request_id,handle=handle,generation=g.binding.worker_generation,target=copy(g.target),binding=copy(g.binding),kind=request.op,request=copy(request)}
 local key,raw,object
 if request.op=='mailbox_provision' then
  key='provision'; op.mode='provision'; op.bytes=tern.json.encode({version=1,handle=handle,binding_digest=g.binding_digest,binding=g.binding}); op.path='provision.json'
 elseif g.status~='provisioned' then return reject('unsupported_capability')
 elseif request.op=='mailbox_read' then
  op.path=M.selector(request.selector); if not op.path then return reject('invalid_schema') end
  if (request.selector.stream=='report' or request.selector.stream=='ack') and request.selector.slot<=g.report_floor or request.selector.stream=='reply' and request.selector.slot<=g.reply_floor then return nil,nil,{status='compacted'} end
  op.mode='read'; key='read'
 elseif request.op=='mailbox_publish_ack' then
  if not integer(request.receipt_revision) or not digest(request.ack_sha256) then return reject('invalid_schema') end
  raw=decode64(request.ack_b64,2048)
  if not raw or Codec.sha256(raw)~=request.ack_sha256 then return reject('content_conflict') end
  local parsed=Codec.strict_decode(raw,2048)
  if type(parsed)~='table' then return reject('invalid_schema') end
  local expected=copy(g.binding); expected.seq=parsed.seq; expected.event_sha256=parsed.event_sha256; expected.event_id=parsed.event_id; expected.committed_revision=request.receipt_revision
  object=Codec.decode_ack(raw,expected)
  if not object or object.event_id~=Codec.sha256(handle..':report:'..string.format('%.0f',object.seq)) then return reject('binding_mismatch') end
  if object.seq<=g.report_floor then return nil,nil,{status='already_compacted'} end
  op.path='acks/'..string.format('%.0f',object.seq)..'.json'; key=op.path; op.mode='publish'; op.bytes=raw
 elseif request.op=='mailbox_publish_reply' then
  if not id(request.message_id) or not integer(request.reply_seq) or not integer(request.action_revision) or not digest(request.reply_sha256) or not digest(request.object_sha256) then return reject('invalid_schema') end
  if request.reply_seq<=g.reply_floor then return nil,nil,{status='already_compacted'} end
  op.path=M.selector({stream='reply',slot=request.reply_seq,part=request.part,index=request.index})
  if not op.path then return reject('invalid_schema') end
  raw=decode64(request.object_b64,if request.part=='chunk' then 4096 else 2048)
  if not raw or Codec.sha256(raw)~=request.object_sha256 then return reject('content_conflict') end
  object=Codec.decode_object(raw)
  if not object or object.mailbox_handle~=handle or object.direction~='reply' or object.slot~=request.reply_seq or object.message_id~=request.message_id or object.message_sha256~=request.reply_sha256 or object.type~=request.part or object.index~=request.index then return reject('binding_mismatch') end
  local slots={}; local bytes=0
  for path,w in pairs(g.writes) do
   if w.reply_seq then
    slots[w.reply_seq]=true
    if w.logical_bytes and path~=op.path then bytes+=w.logical_bytes end
    if w.reply_seq==request.reply_seq then
     for _,field in ipairs({'message_id','action_revision','reply_sha256'}) do if w.request[field]~=request[field] then return reject('content_conflict') end end
    end
   end
  end
  local count=0; for _ in pairs(slots) do count+=1 end
  if not slots[request.reply_seq] and count>=8 then return nil,nil,{status='full',resource='replies',current=count,limit=8} end
  if object.type=='manifest' and bytes+object.message_bytes>524288 then return nil,nil,{status='full',resource='reply_admission_bytes',current=bytes+object.message_bytes,limit=524288} end
  op.mode='publish'; op.bytes=raw; op.object=object; key=op.path
 elseif request.op=='mailbox_retire' then
  if (request.mode~='compact' and request.mode~='retire') or not integer(request.settlement_revision) or not integer(request.report_floor,true) or not integer(request.reply_floor,true) or not digest(request.report_chain_sha256) or not id(request.grant_id) then return reject('invalid_schema') end
  local grant=context.settlement
  if type(grant)~='table' then return reject('binding_mismatch') end
  for _,k in ipairs({'handle','expected_generation','mode','settlement_revision','report_floor','report_chain_sha256','reply_floor','grant_id'}) do if grant[k]~=request[k] then return reject('binding_mismatch') end end
  if request.mode=='retire' and grant.settled~=true then return reject('binding_mismatch') end
  if request.report_floor<g.report_floor or request.reply_floor<g.reply_floor or request.settlement_revision<g.settlement_revision then return reject('binding_mismatch') end
  for k,w in pairs(g.writes) do if (w.status=='uncertain' or w.status=='active') and k~='grant:'..request.grant_id then return nil,nil,{status='uncertain'} end end
  op.mode=request.mode; op.report_floor=request.report_floor; op.reply_floor=request.reply_floor; key='grant:'..request.grant_id
 else return reject('invalid_schema') end
 op.key=key
 local old=g.writes[key]
 if old then
  if not equal(old.request,request) then
   -- Publication identity, not request ID, owns exact bytes.
   if not op.bytes or old.bytes~=op.bytes then return reject('content_conflict') end
  end
  if old.status=='settled' then return nil,nil,copy(old.result) end
  if old.status=='uncertain' then op.reconcile=true end
 end
 -- Legacy SSH generations retain exact outcomes and readback, never new writes.
 if g.backend=='ssh-command' and op.mode~='read' and not op.reconcile then
  return nil,nil,{status='rejected',error={code='unsupported_capability',message='SSH-managed writes are held; run ORCH+ on target host and settle existing effects with the original build before cutover'}}
 end
 if g.active then return nil,nil,{status='full',resource='generation_operations',current=1,limit=1} end
 local active=0; for _,v in pairs(next.generations) do if v.active then active+=1 end end
 if active>=4 then return nil,nil,{status='full',resource='host_operations',current=active,limit=4} end
 -- An unresolved child fences every different operation, even after VM reload.
 for k,w in pairs(g.writes) do if w.status=='uncertain' and k~=key then return nil,nil,{status='uncertain'} end end
 g.active={id=op.id,key=key,generation=op.generation}
 if key~='read' then g.writes[key]={status='active',request=copy(request),bytes=op.bytes,reply_seq=request.reply_seq,logical_bytes=if object and object.type=='manifest' then object.message_bytes else nil} end
 local limit=if request.op=='mailbox_publish_ack' or request.op=='mailbox_retire' then 4194304 else 3932160
 if #tern.json.encode(next)>limit then return nil,nil,{status='full',resource='registry_bytes',current=#tern.json.encode(next),limit=limit} end
 return op,next,nil
end
function M.settle(registry,op,result)
 local g=registry.generations[op.handle]
 if not g or not g.active or g.active.id~=op.id or g.active.key~=op.key or g.active.generation~=op.generation or g.binding.worker_generation~=op.generation then return nil,err('binding_mismatch') end
 local next=copy(registry); g=next.generations[op.handle]; g.active=nil
 -- Only the reviewed helper's failed INITIAL admission gate proves that this
 -- fresh child performed no effect. It cannot erase an earlier uncertain child.
 local admission=result.status=='full' and result.admission_refused==true and result.resource=='capacity_admission' and result.current==1 and result.limit==1 and not op.reconcile and op.mode~='provision'
 if result.admission_refused~=nil then
  result=if admission then {status='full',payload={resource=result.resource,current=result.current,limit=result.limit,retryable=true,effect_started=false}} else {status='uncertain'}
 end
 if op.key~='read' then
  -- A failed readback cannot disprove an earlier child's publication.
  if not admission and (op.reconcile or op.mode=='provision' or op.mode=='compact' or op.mode=='retire') and (result.status=='full' or result.status=='incomplete' or result.status=='missing') then result={status='uncertain'} end
  local w=g.writes[op.key]; w.result=copy(result)
  w.status=if result.status=='uncertain' then 'uncertain' elseif result.status=='incomplete' or result.status=='missing' or result.status=='full' then 'prepared' else 'settled'
 end
 if result.status=='provisioned' then
  g.status='provisioned'
  result={status='provisioned',payload={handle=op.handle,binding_digest=g.binding_digest,limits=copy(M.LIMITS),capabilities=copy(g.capabilities),identity={worker=g.target.worker_identity}}}
  g.writes[op.key].result=copy(result)
 elseif result.status=='compacted' or result.status=='retired' then
  g.report_floor=op.report_floor; g.reply_floor=op.reply_floor; g.report_chain_sha256=op.request.report_chain_sha256; g.settlement_revision=op.request.settlement_revision
  for key,w in pairs(g.writes) do
   if w.request.op=='mailbox_publish_ack' then
    local ack=Codec.strict_decode(w.bytes,2048); if ack and ack.seq<=g.report_floor then g.writes[key]=nil end
   elseif w.reply_seq and w.reply_seq<=g.reply_floor or w.request.op=='mailbox_retire' and key~=op.key then g.writes[key]=nil end
  end
  if result.status=='retired' then g.status='retired'; g.writes={}; g.target=nil end
 elseif result.error and result.error.code=='content_conflict' then
  g.frozen=true
 end
 if #tern.json.encode(next)>4194304 then return nil,err('oversize') end
 return next,result
end
function M.recover(registry)
 local next=copy(registry)
 for _,g in pairs(next.generations) do
  if g.active then
   local w=g.writes[g.active.key]; if w then w.status='uncertain'; w.result={status='uncertain'} end
   g.active=nil
  end
 end
 return next
end
function M.execute(operation,callback) return Adapter.execute(operation,callback) end
return M
