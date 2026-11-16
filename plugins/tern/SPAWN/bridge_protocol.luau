-- Pure public door for spawn.dispatch. Parsing is not authority admission.
local Codec=require('./wire/codec')
local M={PREFIX=Codec.DISPATCH.prefix,NODE=Codec.DISPATCH.node,ROLE=Codec.DISPATCH.role,LIMIT=Codec.DISPATCH.limit}
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
function M.bootstrap_creation(v)
 return M.fields(v,{request_id=M.id,orch_session_id=M.id,owner_id=M.id,
  generation=function(n)return M.integer(n,1)end,authority_namespace=function(s)return M.text(s,128,false)end,source_nonce=M.id})
end
function M.clone(v)
 if type(v)~='table' then return v end
 local length,count=#v,0
 local array=length>0
 for k in pairs(v) do
  count+=1
  if type(k)~='number' or k%1~=0 or k<1 or k>length then array=false end
 end
 if count==0 then array=tern.json.encode(v)=='[]' else array=array and count==length end
 -- Native JSON arrays have a protected metatable; table.clone cannot copy them.
 local out=if array then tern.json.array() else {}
 for k,x in pairs(v) do out[k]=M.clone(x) end
 return out
end
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
M.binding=Codec.validate_dispatch_origin
M.setup_origin=Codec.validate_dispatch_setup_origin
M.pane=Codec.validate_dispatch_pane
M.decode=Codec.decode_dispatch_request
M.encode=Codec.encode_dispatch_response
M.unframe=Codec.decode_dispatch_response
local receiver=nil
function M.observe(root) receiver=root end
function M.body(r,status,payload,error_value,category)
 local body={schema=2,op=r.op,request_id=r.request_id,action_id=r.action_id,category=category or 'current_result',status=status,payload=payload,error=error_value}
 if r.setup_origin then body.setup_origin=M.clone(r.setup_origin);return body end
 body.authority_namespace=r.authority_namespace
 body.logical_session_id=r.logical_session_id
 body.admission_seq=r.admission_seq
 body.spawn_namespace=if receiver then receiver.namespace else 'unavailable'
 local session=receiver and receiver.sessions and receiver.sessions[r.logical_session_id]
 body.authority_revision=if session then session.control.last_authority_revision else r.authority_revision or 0
 if r.control_origin then body.control_origin=M.clone(r.control_origin);body.close_id=r.close_id
 else body.origin_binding=M.clone(r.origin_binding);body.controller_generation=r.controller_generation;body.request_serial=r.request_serial end
 return body
end
function M.reject(r,code,message)
 local category=if not r.setup_origin and table.find(Codec.DISPATCH_CATEGORIES,code) then code else 'current_result'
 if (r.control_origin or r.op=='owner_status') and category=='current_result' then
  message=code..': '..tostring(message)
  category=if code=='binding_mismatch' or code=='content_conflict' then 'stale_binding' else 'migration_blocked'
  code=category
 end
 return M.body(r,if code=='claim_mismatch' then 'uncertain' else 'rejected',nil,{code=code,message=tostring(message):sub(1,512)},category)
end
-- The independent roster-import door is not an ORCH managed dispatch request.
-- Its existing response framing remains readable without accepting v1 managed mutation.
function M.encode_import(body)
 if not M.fields(body,{schema=function(v)return v==1 end,op=function(v)return v=='import_config'end,request_id=M.id,status=true},{source_sha256=M.digest,payload=true,error=true}) then return nil end
 local bytes=tern.json.encode(body)
 local frame='SPAWN_DISPATCH v1 '..tern.json.encode({schema=1,op='import_config',request_id=body.request_id,complete=true,body_bytes=#bytes,body_sha256=Codec.sha256(bytes),body_json=bytes})
 return if #frame<=M.LIMIT then frame else nil
end
return M
