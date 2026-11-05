-- Pure public door for spawn.dispatch. Parsing is not authority admission.
local Codec=require('./codec')
local M={PREFIX='SPAWN_DISPATCH v1 ',NODE='spawn-dispatch-response',ROLE='spawn.dispatch.response',LIMIT=8192}
local MAX=9007199254740991
function M.integer(v,min) return type(v)=='number' and v>=min and v<=MAX and v%1==0 end
function M.id(v) return type(v)=='string' and #v>0 and #v<=96 and v:match('^[A-Za-z0-9_-]+$')~=nil end
function M.token(v) return M.id(v) and #v>=16 or type(v)=='string' and #v>=16 and #v<=128 and v:match('^[A-Za-z0-9_-]+$')~=nil end
function M.digest(v) return type(v)=='string' and #v==64 and v:match('^[0-9a-f]+$')~=nil end
function M.text(v,n,empty) return type(v)=='string' and #v<=n and (empty or #v>0) and not v:find('%z') and utf8.len(v)~=nil end
function M.fields(v,required,optional)
 if type(v)~='table' then return false end
 for k in pairs(v) do if not required[k] and not (optional and optional[k]) then return false end end
 for k,check in pairs(required) do if type(check)=='function' then if not check(v[k]) then return false end elseif v[k]==nil then return false end end
 for k,check in pairs(optional or {}) do if v[k]~=nil and type(check)=='function' and not check(v[k]) then return false end end
 return true
end
function M.clone(v) if type(v)~='table' then return v end local out={} for k,x in pairs(v) do out[k]=M.clone(x) end return out end
function M.equal(a,b) if type(a)~=type(b) then return false end if type(a)~='table' then return a==b end for k,v in pairs(a) do if not M.equal(v,b[k]) then return false end end for k in pairs(b) do if a[k]==nil then return false end end return true end
-- Internal semantic request fingerprint; wire-object hashes still use ORIGINAL bytes.
function M.fingerprint(value)
 local function canonical(v)
  if type(v)~='table' then return type(v)..':'..tern.json.encode(v) end
  local keys={};for k in pairs(v) do table.insert(keys,k) end
  table.sort(keys,function(a,b)return type(a)..tostring(a)<type(b)..tostring(b)end)
  local pieces={'{'}
  for _,k in ipairs(keys) do table.insert(pieces,canonical(k)..'='..canonical(v[k])..';') end
  table.insert(pieces,'}');return table.concat(pieces)
 end
 return Codec.sha256(canonical(value))
end
local positive=function(v)return M.integer(v,1)end
local revision=function(v)return M.integer(v,0)end
local opaque=function(v)return M.text(v,256,false)end
local record_id=function(v)return M.text(v,96,false) and v:find('%S')~=nil and not v:find('%c')end
local emptyopaque=function(v)return M.text(v,256,true)end
local decimal=function(v)return type(v)=='string' and #v<=32 and v:match('^%d+$')~=nil end
local B={logical_session_id=M.id,worker_id=M.id,worker_generation=positive,launch_request_id=M.id,work_id=M.id,enrolment_token=M.token}
function M.binding(v)
 return M.fields(v,{logical_session_id=M.id,owner_id=M.id,owner_generation=positive,host_pane_id=opaque,alias_nonce=opaque,window_key=emptyopaque,window_epoch=M.id,native_session_id=opaque,window_host_id=opaque})
end
function M.pane(v) return M.fields(v,{pane_id=decimal,window_epoch=M.id,window_key=emptyopaque,native_session_id=opaque,window_host_id=opaque}) end
local function enrolment(v)
 return M.fields(v,{worker_id=M.id,worker_generation=positive,enrolment_token=M.token,assignment_sha256=M.digest},{handover_id=M.id,handover_token=M.token,coordinator_owner_id=M.id,coordinator_generation=positive}) and ((v.handover_id==nil)==(v.handover_token==nil)) and ((v.coordinator_owner_id==nil)==(v.coordinator_generation==nil))
end
local common={schema=function(v)return v==1 end,origin=function(v)return v=='orchplus'end,op=opaque,request_id=M.id,action_id=M.id,origin_binding=M.binding,controller_pane=decimal,controller_generation=positive}
local specs={
 catalog={required={},optional={cursor=function(v)return M.fields(v,{revision=revision,index=positive})end}},
 launch={required={record_id=record_id,record_revision=revision,work_id=M.id,prompt=function(v)return M.text(v,32768,false) and v:find('%S')~=nil end,cwd=function(v)return M.text(v,2048,false)end,placement=function(v)return v=='tab' or v=='split' or v=='replace_if_alone'end,fresh=function(v)return v==true end,mailbox_handle=M.id,enrolment=enrolment}},
 -- ORCH+ explicit verified attach: the same enrolment/preface as launch, delivered once by native
 -- ask to the exact owner-attested existing agent pane instead of starting a new agent.
 adopt={required={record_id=record_id,record_revision=revision,work_id=M.id,prompt=function(v)return M.text(v,32768,false) and v:find('%S')~=nil end,mailbox_handle=M.id,enrolment=enrolment,pane_binding=M.pane,attestation=function(v)return v=='operator_verified_exact_agent_pane'end}},
 status={required={target_request_id=M.id}},
 -- Read-only admission view for ORCH+'s guided reload recovery; reserves, fences and changes nothing.
 owner_status={required={}},
 accept={required={target_request_id=M.id,target_action_id=M.id,pane_binding=M.pane,worker_id=M.id,worker_generation=positive,enrolment_token=M.token,work_id=M.id,event_id=M.id,seq=positive,event_sha256=M.digest},optional={handover_id=M.id,handover_token=M.token}},
 stop={required={target_request_id=M.id,target_action_id=M.id,pane_binding=M.pane,worker_id=M.id,worker_generation=positive,enrolment_token=M.token,work_id=M.id}},
 native_wake={required={target_request_id=M.id,target_action_id=M.id}},
 attach_worker={required={target_request_id=M.id,target_action_id=M.id,previous_origin_binding=M.binding,previous_pane_binding=M.pane,pane_binding=M.pane,worker_id=M.id,worker_generation=positive,enrolment_token=M.token,work_id=M.id,attestation=function(v)return v=='old_executors_stopped_or_retired'end}},
 mailbox_provision={required={record_id=record_id,record_revision=revision,capability=function(v)return v=='report-files-v1'end},optional={handover_id=M.id,handover_sha256=M.digest}},
 mailbox_read={required={handle=M.id,expected_generation=positive,selector=function(v)return type(v)=='table'end}},
 mailbox_publish_ack={required={handle=M.id,expected_generation=positive,receipt_revision=positive,ack_b64=opaque,ack_sha256=M.digest}},
 mailbox_publish_reply={required={handle=M.id,expected_generation=positive,message_id=M.id,reply_seq=positive,action_revision=positive,reply_sha256=M.digest,part=function(v)return v=='chunk' or v=='manifest'end,object_b64=opaque,object_sha256=M.digest},optional={index=positive}},
 mailbox_retire={required={handle=M.id,expected_generation=positive,mode=function(v)return v=='compact' or v=='retire'end,settlement_revision=positive,report_floor=revision,report_chain_sha256=M.digest,reply_floor=revision,grant_id=M.id}},
}
-- Base64 object limits are enforced by the mailbox codec, not the opaque-ID bound.
specs.mailbox_publish_ack.required.ack_b64=function(v)return M.text(v,2732,false)end
specs.mailbox_publish_reply.required.object_b64=function(v)return M.text(v,5464,false)end
function M.decode(bytes)
 local r,e=Codec.strict_decode(bytes,M.LIMIT);if not r then return nil,e end
 local spec=type(r)=='table' and specs[r.op];if not spec then return nil,{code='invalid_schema',message='Unsupported dispatch operation'} end
 local required=table.clone(common);for k,v in pairs(spec.required) do required[k]=v end
 if r.op:sub(1,8)=='mailbox_' then for k,v in pairs(B) do required[k]=v end end
 if not M.fields(r,required,spec.optional) or r.controller_generation~=r.origin_binding.owner_generation then return nil,{code='invalid_schema',message='Invalid operation-specific dispatch request'} end
 if r.logical_session_id and r.logical_session_id~=r.origin_binding.logical_session_id then return nil,{code='binding_mismatch',message='Logical session differs'} end
 if (r.op=='accept' and ((r.handover_id==nil)~=(r.handover_token==nil))) or (r.op=='mailbox_provision' and ((r.handover_id==nil)~=(r.handover_sha256==nil))) then return nil,{code='invalid_schema',message='Handover fields must be paired'} end
 if r.op=='adopt' and (r.enrolment.handover_id~=nil or r.enrolment.coordinator_owner_id~=nil) then return nil,{code='invalid_schema',message='Adoption enrols an ordinary first generation only'} end
 return r
end
function M.body(r,status,payload,error_value)
 return {schema=1,op=r.op,request_id=r.request_id,action_id=r.action_id,origin_binding=M.clone(r.origin_binding),controller_generation=r.controller_generation,status=status,payload=payload,error=error_value}
end
function M.reject(r,code,message) return M.body(r,'rejected',nil,{code=code,message=tostring(message):sub(1,512)}) end
function M.encode(body)
 local bytes=tern.json.encode(body)
 local wire=M.PREFIX..tern.json.encode({schema=1,op=body.op,request_id=body.request_id,complete=true,body_bytes=#bytes,body_sha256=Codec.sha256(bytes),body_json=bytes})
 if #wire>M.LIMIT then return nil,'oversize' end
 return wire
end
function M.unframe(wire)
 if type(wire)~='string' or #wire>M.LIMIT or wire:sub(1,#M.PREFIX)~=M.PREFIX then return nil end
 local r=Codec.strict_decode(wire:sub(#M.PREFIX+1),M.LIMIT)
 if not M.fields(r,{schema=function(v)return v==1 end,op=opaque,request_id=M.id,complete=function(v)return v==true end,body_bytes=positive,body_sha256=M.digest,body_json=function(v)return M.text(v,M.LIMIT,false)end}) then return nil end
 if #r.body_json~=r.body_bytes or Codec.sha256(r.body_json)~=r.body_sha256 then return nil end
 local body=Codec.strict_decode(r.body_json,M.LIMIT)
 if type(body)~='table' or body.schema~=1 or body.op~=r.op or body.request_id~=r.request_id then return nil end
 return body
end
return M
