-- Forget-only durable evidence of outstanding helper children (SKILLS-205). A record is written BEFORE a helper child starts and
-- removed only by that child's own terminal completion or a verified failure to start; a watchdog expiry never removes it. After
-- a reload an uncleared record is an uncertain outstanding child: nothing proves it settled, and no other child's completion can
-- (helpers overlap). It stays a blocker until a manual reset. Records belong to a scope string (a mailbox generation handle, or
-- "session:<logical>" for terminal-observation helpers).
local KEY='spawn-children-v1'
local MAX=256
local M={}
local boot=string.format('children-%d-%08x-%08x',os.time(),math.random(1,2147483647),math.random(1,2147483647))
local serial=0
local function read()
 local ok,value=pcall(tern.kv.get,KEY)
 if not ok then return nil end
 if value==nil then return {} end
 if type(value)~='table' then return nil end
 return value
end
local function write(map)
 local ok=pcall(tern.kv.set,KEY,map)
 return ok
end
-- Returns a token, or nil when the record could not be made durable (the caller must then not start the child).
function M.begin(scope,kind)
 local map=read();if not map then return nil end
 local count=0;for _ in pairs(map) do count+=1 end
 if count>=MAX then return nil end
 serial+=1
 local token=boot..':'..tostring(serial)
 map[token]={scope=scope,kind=kind,boot=boot}
 if not write(map) then return nil end
 return token
end
function M.finish(token)
 if token==nil then return end
 local map=read();if not map then return end
 map[token]=nil
 write(map)
end
-- Outstanding children for any scope in the set; an unreadable ledger counts as one uncertain child.
function M.outstanding(scopes)
 local map=read()
 if not map then return 1 end
 local count=0
 for _,record in pairs(map) do if scopes[record.scope] then count+=1 end end
 return count
end
return M
