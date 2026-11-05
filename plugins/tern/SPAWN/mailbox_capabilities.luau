-- Pure configured mailbox contract shared by catalog eligibility and provisioning.
-- Operator attestation is not runtime proof; target path/shell checks stay in the adapter.
local M = {}
local allowed = {['report-files-v1']=true,['worker-poll-v1']=true,['native-ask-v1']=true,['argv-v1']=true,['coordinator-control-v1']=true}
function M.valid_set(backend,wake,capabilities)
 if backend~='native-agent' and backend~='local-terminal' and backend~='ssh-command' then return false end
 if wake~='worker-poll-v1' and wake~='native-ask-v1' then return false end
 if wake=='native-ask-v1' and backend~='native-agent' then return false end
 if type(capabilities)~='table' then return false end
 local seen,count={},0
 for key,value in pairs(capabilities) do
  if type(key)~='number' or key%1~=0 or key<1 or key>5 or type(value)~='string' or not allowed[value] or seen[value] then return false end
  seen[value]=true;count+=1
 end
 for index=1,count do if capabilities[index]==nil then return false end end
 if not seen['report-files-v1'] or not seen[wake] then return false end
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
return M
