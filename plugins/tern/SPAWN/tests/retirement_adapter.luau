-- Bounded private producer-cleanup/target-retirement choreography; no real children.
local root=...
assert(type(root)=='string','pass package directory')
local runtime,environment=tern,getfenv()
local checks=0
local function check(v,m)assert(v,m);checks+=1 end
local function copy(v)if type(v)~='table'then return v end local out={}for k,x in pairs(v)do out[k]=copy(x)end return out end
local calls,timers,answers={},{},{}
local pending
local clock=1000 -- Injected monotonic milliseconds; the adapter watchdog is driven explicitly.
local fake=setmetatable({now=function()return clock end,timer=function(_,fn)local t={fn=fn,cancel=function()end};table.insert(timers,t);return t end,process={run=function(argv,options,callback)
 table.insert(calls,{argv=copy(argv)})
 local answer=table.remove(answers,1)
 if answer==nil then pending=callback;return end
 callback(if type(answer)=='string' then {status=0,timed_out=false,stdout=answer,stderr=''} else answer)
end}},{__index=runtime})
local modules={}
local function load(name)
 name=name:gsub('^%./','');if modules[name]then return modules[name]end
 local fn=assert(loadstring(runtime.fs.read(root..'/'..name..'.luau'),name))
 setfenv(fn,setmetatable({tern=fake,require=load},{__index=environment}));modules[name]=fn();return modules[name]
end
local A=load('mailbox_adapter')
local binding={logical_session_id='session',worker_id='worker',worker_generation=2,launch_request_id='launch',work_id='work',enrolment_token='aaaaaaaaaaaaaaaa',mailbox_handle='mailbox'}
local op={id='retire-op',handle='mailbox',mode='retire',kind='mailbox_retire',retire_producer=true,binding=copy(binding),report_floor=7,reply_floor=3,request={report_chain_sha256=string.rep('a',64)},target={root='/mail',helper='/tools/target',producer_helper='/tools/worker',worker_identity='worker',kind='posix',os='linux',shell='/bin/sh',host_os='linux',host_shell='/bin/sh',backend='local-terminal'}}
local function run(operation,responses)
 calls={};answers=copy(responses);pending=nil
 local result;A.execute(operation,function(value)result=value end)
 return result
end
local result=run(op,{'producer_retired\n','retired\n'})
check(result.status=='retired' and #calls==2,'authorized retirement runs producer cleanup then target retirement')
for _,answer in ipairs({'producer_retired\nextra','incomplete\n',{status=1,timed_out=false,stdout='producer_retired\n',stderr='failure'}})do
 result=run(op,{answer})
 check(result.status=='uncertain' and #calls==1,'ambiguous producer result never starts target retirement')
end
result=run(op,{'producer_unsettled\n'})
check(result.status=='rejected' and result.error.code=='producer_unsettled' and #calls==1,'exact pre-effect unsettled-journal refusal is definite and never starts target retirement')
for _,answer in ipairs({'producer_unsettled\nextra',{status=1,timed_out=false,stdout='producer_unsettled\n',stderr=''},{status=0,timed_out=true,stdout='producer_unsettled\n',stderr=''}})do
 result=run(op,{answer})
 check(result.status=='uncertain' and #calls==1,'only the exact exit-0 producer_unsettled line is a definite refusal')
end
result=run(op,{'producer_retired\n','producer_unsettled\n'})
check(result.status=='uncertain' and #calls==2,'a target child can never claim producer refusal after cleanup')
result=run(op,{'producer_retired\n','admission_full\ncapacity_admission\n1\n1\n'})
check(result.status=='uncertain' and not result.admission_refused,'target contention after cleanup cannot claim operation-wide pre-effect refusal')
local ordinary=copy(op);ordinary.retire_producer=nil
result=run(ordinary,{'retired\n'})
check(result.status=='retired' and #calls==1 and calls[1].argv[5]=='retire','ordinary mailbox retirement cannot invoke private producer cleanup')
local compact=copy(op);compact.mode='compact'
result=run(compact,{'compacted\n'})
check(result.status=='compacted' and #calls==1 and calls[1].argv[5]=='compact','compaction never invokes producer cleanup')
local lostResult;calls={};answers={'producer_retired\n'}
A.execute(op,function(value)lostResult=value end)
check(#calls==2 and lostResult==nil,'lost target callback retains the in-flight whole retirement')
clock+=3600000;timers[#timers].fn()
check(lostResult==nil,'host suspension is not awake progress toward the shared deadline')
for _=1,29 do clock+=1000;timers[#timers].fn() end
check(lostResult.status=='uncertain','awake deadline after producer cleanup preserves uncertainty')
pending({status=0,timed_out=false,stdout='retired\n',stderr=''})
check(lostResult.status=='uncertain','late callback cannot overwrite ambiguous completion')
local spanned;calls={};answers={};pending=nil
A.execute(op,function(value)spanned=value end)
clock+=3600000;timers[#timers].fn()
pending({status=0,timed_out=false,stdout='producer_retired\n',stderr=''})
check(#calls==2 and spanned==nil,'producer cleanup spanning a suspension still proceeds to target retirement')
pending({status=0,timed_out=false,stdout='retired\n',stderr=''})
check(spanned.status=='retired','retirement spanning a host suspension settles conclusively, not uncertain')
local reconciliation=copy(op);reconciliation.reconcile=true
result=run(reconciliation,{'incomplete\n'})
check(result.status=='uncertain' and #calls==1 and calls[1].argv[5]=='reconcile_retire','reconciliation only reads target absence and never repeats producer cleanup')
result=run(reconciliation,{'retired\n'})
check(result.status=='retired' and #calls==1,'readback can confirm complete mailbox absence without another effect')
do
 local withdrawn=copy(op)
 withdrawn.request.withdrawn_starts={{reply_seq=4,message_id='closed-start',message_sha256=string.rep('b',64)}}
 local exact=runtime.base64.encode(runtime.json.encode(withdrawn.request.withdrawn_starts))
 result=run(withdrawn,{'producer_retired\n','retired\n'})
 check(result.status=='retired' and #calls==2 and #calls[1].argv==14 and #calls[2].argv==12
  and calls[1].argv[14]==exact and calls[2].argv[12]==exact,
  'POSIX producer and target receive the same exact withdrawal proof in the final optional argument')
 withdrawn.reconcile=true
 result=run(withdrawn,{'retired\n'})
 check(result.status=='retired' and #calls==1 and calls[1].argv[5]=='reconcile_retire' and calls[1].argv[12]==exact,
  'retirement readback retains the same withdrawal proof and never repeats producer destruction')
 withdrawn.reconcile=nil;withdrawn.target.kind='powershell';withdrawn.target.os='windows'
 result=run(withdrawn,{'producer_retired\n','retired\n'})
 check(result.status=='retired' and #calls==2,'Windows withdrawal keeps the same two-stage retirement')
 for _,call in ipairs(calls) do
  check(call.argv[#call.argv-1]=='-WithdrawnStarts:' and call.argv[#call.argv]==exact,
   'Windows producer and target receive the literal same named withdrawal proof')
 end
 withdrawn.target.kind='posix';withdrawn.target.os='linux';withdrawn.mode='compact'
 result=run(withdrawn,{'compacted\n'})
 check(result.status=='rejected' and #calls==0,'withdrawal cannot enter normal compaction or start any physical child')
end
local cancellation=copy(op);cancellation.cancel_enrolment=true;cancellation.report_floor=0;cancellation.reply_floor=0
cancellation.request.report_chain_sha256=load('wire/codec').sha256('report-files-v1\nmailbox\n')
result=run(cancellation,{'producer_absent\n','retired\n'})
check(result.status=='retired' and #calls==2,'verified unused pending enrollment still requires real target retirement after producer absence')
for _,change in ipairs({
 function(v)v.cancel_enrolment=nil end,
 function(v)v.report_floor=1 end,
 function(v)v.reply_floor=1 end,
 function(v)v.request.report_chain_sha256=string.rep('0',64) end,
}) do
 local refused=copy(cancellation);change(refused)
 result=run(refused,{'producer_absent\n'})
 check(result.status=='uncertain' and #calls==1,'producer absence cannot weaken ordinary or consumed-worker retirement')
end
result=run(cancellation,{'producer_absent\n','incomplete\n'})
check(result.status=='incomplete' and #calls==2,'producer winning the inter-child race never yields positive retirement')
result=run(cancellation,{'producer_unsettled\n'})
check(result.status=='rejected' and result.error.code=='producer_unsettled' and #calls==1,'token consumed before cancellation remains a definite held journal, not an unused capability')
do
 local function inventory(target,response)
  calls={};answers={response};pending=nil
  local value,why
  A.inventory(target,'mailbox',1800000,function(v,problem)value=v;why=problem end)
  return value,why
 end
 local value,why=inventory(op.target,'{"observed_at_ms":1700000000000,"open_files":7,"stale_files":2}')
 check(value and value.open_files==7 and value.stale_files==2 and why==nil and #calls==1,'read-only inventory preserves actual bounded observation counts')
 for _,bytes in ipairs({'{"observed_at_ms":1,"open_files":2,"stale_files":3}','{"observed_at_ms":1,"open_files":1000001,"stale_files":0}','{"observed_at_ms":1,"open_files":0,"stale_files":0,"root":"/private"}','missing\n'}) do
  value,why=inventory(op.target,bytes)
  check(value==nil and type(why)=='string','malformed, missing or unbounded inventory never becomes zero')
 end
 local foreign=copy(op.target);foreign.user='another-user'
 value,why=inventory(foreign,'{}')
 check(value==nil and #calls==0,'inventory cannot acquire a sudo/cross-user route')
 foreign=copy(op.target);foreign.backend='ssh-command';foreign.host='remote';foreign.user=nil
 value,why=inventory(foreign,'{}')
 check(value==nil and #calls==0,'inventory cannot invent an SSH execution route')
end
return 'PASS retirement_adapter '..tostring(checks)
