-- Pure configured mailbox contract shared by catalog eligibility and provisioning.
-- Configured transport evidence is not provider readiness; target checks stay in the adapter.
local Backend=require('./backend')
local P=require('./bridge_protocol')
local M = {}
local allowed = {['report-files-v1']=true,['worker-poll-v1']=true,['native-ask-v1']=true,['argv-v1']=true,['coordinator-control-v1']=true,['check-runner-v1']=true,['release-manager-v1']=true,['project-start-v1']=true}
function M.valid_set(backend,wake,capabilities)
 if backend~='native-agent' and backend~='local-terminal' and backend~='ssh-command' then return false end
 if wake~='worker-poll-v1' and wake~='native-ask-v1' then return false end
 if wake=='native-ask-v1' and backend~='native-agent' then return false end
 if type(capabilities)~='table' then return false end
 local seen,count={},0
 for key,value in pairs(capabilities) do
  if type(key)~='number' or key%1~=0 or key<1 or key>8 or type(value)~='string' or not allowed[value] or seen[value] then return false end
  seen[value]=true;count+=1
 end
 for index=1,count do if capabilities[index]==nil then return false end end
 if not seen['report-files-v1'] or not seen[wake] then return false end
 if seen['project-start-v1'] and not seen['coordinator-control-v1'] then return false end
 local other=if wake=='worker-poll-v1' then 'native-ask-v1' else 'worker-poll-v1'
 if seen[other] then return false end
 return (seen['argv-v1']==true)==(backend~='native-agent')
end
function M.validate(record)
 local cfg=if type(record)=='table' then record.mailbox else nil
 if type(cfg)~='table' or cfg.verified~=true then return nil,'Configured producer/target evidence and reviewed transport/producer helpers required' end
 for _,key in ipairs({'permitted_root','helper_path','producer_helper_path','worker_identity','evidence_ref'}) do
  if type(cfg[key])~='string' or cfg[key]=='' then return nil,'Configured producer/target evidence and reviewed transport/producer helpers required' end
 end
 if type(cfg.producer)~='table' then return nil,'Existing worker journal/read/write/hash/poll route must be established' end
 for _,key in ipairs({'read','write','hash','journal'}) do
  if cfg.producer[key]~=true then return nil,'Existing worker journal/read/write/hash/poll route must be established' end
 end
 if cfg.wake=='worker-poll-v1' and cfg.producer.poll~=true then return nil,'Existing worker journal/read/write/hash/poll route must be established' end
 if not M.valid_set(record.backend,cfg.wake,cfg.capabilities) then return nil,'Mailbox capabilities must match report-files-v1, the configured wake route and backend argv-v1 input' end
 return table.clone(cfg.capabilities),nil
end
function M.eligibility(record,snapshot)
 local c=Backend.eligibility(record)
 local reasons={}
 if record.backend=='ssh-command' then table.insert(reasons,'SSH-hop workers are not managed here; run ORCH+ on target host with its same-host SPAWN records') end
 if not c.fresh or not c.input or not c.target then table.insert(reasons,'Explicit fresh launch, target shell and initial input contract required') end
 local caps,why=M.validate(record)
 if not caps then caps={};table.insert(reasons,why) end
 if not record.enabled or record.review_required then table.insert(reasons,'Record disabled or awaiting owner review') end
 if not P.text(record.cwd,2048,false) then table.insert(reasons,'Managed work requires an explicit configured cwd of at most 2048 UTF-8 bytes') end
 if snapshot then
  local shell=Backend.shell_kind(snapshot.host_os,snapshot.host_shell)
  if not shell or record.backend=='native-agent' and shell~='posix' then table.insert(reasons,'Native launch is unsupported on this execution-host shell') end
  if record.backend~='ssh-command' and record.user and shell~='posix' then table.insert(reasons,'OS-user isolation is unsupported on this execution host') end
  if record.backend~='ssh-command' and record.host and string.lower(record.host)~='local' and 'host:'..string.lower(record.host)~=snapshot.host_key then table.insert(reasons,'Configured execution host differs from canonical host authority') end
 end
 return #reasons==0,caps,reasons
end
return M
