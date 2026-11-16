-- Native Tern Lua entrypoint: run.luau <package-directory> [behavior,setup_review,authority,backend,dispatch,dispatch_state,dispatch_migration,window_dispatch,window_journal,window_migration,mailbox,host_editor,retirement_adapter,managed_route,page_navigation,terminal_identity,setup_discovery] [section]
local root,selection,section=...
assert(type(root)=='string' and root~='','pass package directory')
assert(selection==nil or type(selection)=='string','groups must be comma-separated')
assert(section==nil or type(section)=='string' and (selection=='authority' or selection=='dispatch' or selection=='window_dispatch'),'section requires one authority, dispatch or window_dispatch group')
local groups={behavior=true,setup_review=true,authority=true,backend=true,dispatch=true,dispatch_state=true,dispatch_migration=true,window_dispatch=true,window_journal=true,window_migration=true,mailbox=true,host_editor=true,retirement_adapter=true,managed_route=true,page_navigation=true,terminal_identity=true,setup_discovery=true}
local authority_sections={'interleaving','stale_config','recovery','reply_capacity','observer_capacity','byte_capacity','review_conflict','transport_reset','empty_client','migration','invalid_authority','invalid_migration','backup_failure','execution_lifecycle','execution_approval','admission_expiry','clear_history','late_completion','legacy_job','forget_sessions','transient_reply','trim_history','auto_forget','sweep_restart','sweep_pane','sweep_legacy','obsolete_release','repeat_launch','retired_fields','managed_retirement','managed_coexistence','managed_rotation','managed_retention','managed_settlement_replay','managed_unbound_mailbox_retention','managed_import','managed_maintenance','managed_migration','setup_lifecycle','setup_migration','setup_commit','setup_readiness','setup_invalid','setup_probe','setup_default','setup_submission','setup_import_fences','setup_import_conflicts','setup_discard','setup_default_recovery'}
local results,seen={},{}
local function run(name,section)
 local chunk=assert(loadstring(tern.fs.read(root..'/tests/'..name..'.luau'),'tests/'..name))
 setfenv(chunk,setmetatable({},{__index=getfenv()}))
 local result=chunk(root,section)
 assert(type(result)=='string','test group must return summary')
 table.insert(results,result)
end
for name in string.gmatch(selection or 'behavior,setup_review,authority,backend,dispatch,dispatch_state,dispatch_migration,window_dispatch,window_journal,window_migration,mailbox,host_editor,retirement_adapter,managed_route,page_navigation,terminal_identity,setup_discovery','[^,]+') do
 assert(groups[name] and not seen[name],'unknown/duplicate group '..name);seen[name]=true
 if name=='authority' and not section then for _,part in ipairs(authority_sections) do run(name,part) end else run(name,section) end
end
assert(next(seen),'select at least one group')
return table.concat(results,'\n')
