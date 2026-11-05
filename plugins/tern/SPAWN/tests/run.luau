-- Native Tern Lua entrypoint: run.luau <package-directory> [behavior,authority,backend,dispatch,window_dispatch,mailbox,host_editor,retirement_adapter] [section]
local root,selection,section=...
assert(type(root)=='string' and root~='','pass package directory')
assert(selection==nil or type(selection)=='string','groups must be comma-separated')
assert(section==nil or type(section)=='string' and (selection=='authority' or selection=='dispatch' or selection=='window_dispatch'),'section requires one authority, dispatch or window_dispatch group')
local groups={behavior=true,authority=true,backend=true,dispatch=true,window_dispatch=true,mailbox=true,host_editor=true,retirement_adapter=true}
local authority_sections={'interleaving','stale_config','stale_resolution','recovery','reply_capacity','observer_capacity','byte_capacity','review_conflict','transport_reset','empty_client','migration','invalid_authority','invalid_migration','backup_failure','execution_lifecycle','execution_approval','admission_expiry','clear_history','late_completion','legacy_job','forget_sessions','transient_reply','trim_history','auto_forget','managed_retirement','managed_coexistence','managed_rotation','managed_retention','managed_settlement_replay','managed_unbound_mailbox_retention','managed_import','managed_maintenance','managed_migration'}
local results,seen={},{}
local function run(name,section)
 local chunk=assert(loadstring(tern.fs.read(root..'/tests/'..name..'.luau'),'tests/'..name))
 setfenv(chunk,setmetatable({},{__index=getfenv()}))
 local result=chunk(root,section)
 assert(type(result)=='string','test group must return summary')
 table.insert(results,result)
end
for name in string.gmatch(selection or 'behavior,authority,backend,dispatch,window_dispatch,mailbox,host_editor,retirement_adapter','[^,]+') do
 assert(groups[name] and not seen[name],'unknown/duplicate group '..name);seen[name]=true
 if name=='authority' and not section then for _,part in ipairs(authority_sections) do run(name,part) end else run(name,section) end
end
assert(next(seen),'select at least one group')
return table.concat(results,'\n')
