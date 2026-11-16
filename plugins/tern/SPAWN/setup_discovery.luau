-- Read-only Tern devices and bounded selected-host installation discovery.
-- Discovery suggests an installation, never permission to enable integration.
local M={}
-- Window-side observations only; no SSH connection, session or account is created.
function M.devices(hosts,current)
 if type(hosts)~='table' or #hosts==0 or #hosts>64 or type(current)~='table' then return nil,'Tern device discovery is unavailable. Attach the execution machine in Tern, then find devices again.' end
 local devices,seen,selected={},{},nil
 for _,host in ipairs(hosts) do
  if type(host)~='table' or type(host.id)~='number' or host.id<0 or host.id%1~=0 or seen[host.id]
   or type(host.name)~='string' or host.name=='' or #host.name>256 or host.name:find('%c')
   or (host.kind~='local' and host.kind~='remote') or type(host.state)~='string'
   or type(host.sessions)~='table' or #host.sessions>1024 then return nil,'Tern returned incomplete or ambiguous device identity. Resolve the device connection in Tern before setup.' end
  seen[host.id]=true
  local sessions={}
  for _,id in ipairs(host.sessions) do
   if type(id)~='number' or id<0 or id%1~=0 then return nil,'Tern device session membership is unavailable; no execution machine was guessed.' end
   table.insert(sessions,id)
  end
  local device={id=host.id,name=host.name,kind=host.kind,address=host.address,state=host.state,sessions=sessions}
  table.insert(devices,device)
  if host.id==current.id and host.name==current.name and host.kind==current.kind and host.address==current.address then selected=host.id end
 end
 if selected==nil then return nil,'The current execution machine is missing from Tern discovery. Return to its session and find devices again.' end
 return {devices=devices,current=selected},nil
end
function M.primary(observation,selected,mode)
 if type(observation)~='table' or type(observation.devices)~='table' or (mode~='single' and mode~='multi') then return nil,'Choose Single or Multi Device Setup before finding execution machines.' end
 for _,device in ipairs(observation.devices) do
  if device.id==selected then
   if device.state~='connected' then return nil,'Connect '..device.name..' in Tern before choosing it for execution.' end
   if #device.sessions==0 then return nil,'Open a Tern session on '..device.name..' before setup. SPAWN will not create a transport terminal.' end
   return device,nil
  end
 end
 return nil,'The selected machine was not discovered by Tern. Find execution machines again.'
end
local function parent(path)
 local trimmed=path:gsub('[/\\]+$','')
 local value=trimmed:match('^(.*)[/\\][^/\\]+$')
 if value=='' then return '/' end
 return value
end
local function names(path)
 local ok,entries=pcall(tern.fs.list,path)
 if not ok or type(entries)~='table' then return nil end
 if #entries>4096 then return nil end
 local found={}
 for _,name in ipairs(entries) do if type(name)~='string' then return nil end;found[name:gsub('[/\\]+$','')]=true end
 return found
end
function M.glitch(cwd)
 local seen,roots,unavailable={},{},{}
 for _,start in ipairs({cwd,tern.plugin.dir}) do
  local path=start
  for depth=1,32 do
   if type(path)~='string' or path=='' or seen[path] then break end
   seen[path]=true
   local entries=names(path)
   if not entries then table.insert(unavailable,path)
   elseif entries['.claude'] then
    local config=names(path..'/.claude')
    if not config then table.insert(unavailable,path..'/.claude')
    elseif config.scripts then
     local scripts=names(path..'/.claude/scripts')
     if not scripts then table.insert(unavailable,path..'/.claude/scripts')
     elseif scripts['workspaces.py'] and scripts['plan_check.py'] then
      local workspace_ok=pcall(tern.fs.read,path..'/.claude/scripts/workspaces.py',262144)
      local gate_ok=pcall(tern.fs.read,path..'/.claude/scripts/plan_check.py',262144)
      if workspace_ok and gate_ok then table.insert(roots,path) else table.insert(unavailable,path..'/.claude/scripts') end
     end
    end
   end
   local next_path=parent(path)
   if not next_path or next_path==path then break end
   if depth==32 and not seen[next_path] then table.insert(unavailable,next_path);break end
   path=next_path
  end
 end
 if #unavailable>0 then return {state='unavailable',candidates=roots,inaccessible=unavailable,evidence='Known ancestor discovery was incomplete or exceeded its read bound; no installation choice or integration enablement was made'} end
 if #roots>1 then return {state='ambiguous',candidates=roots,evidence='Multiple verified installation candidates were found in the working-folder/plugin ancestors; no root was selected'} end
 if #roots==1 then return {state='detected',root=roots[1],evidence='Regular bounded Glitch workspace and plan-check scripts were observed on this execution host'} end
 return {state='not_detected_in_known_ancestors',evidence='All known ancestors were accessible; no installation was established and no integration was enabled'}
end
return M
