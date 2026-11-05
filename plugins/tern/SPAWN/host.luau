-- The execution host is the only durable writer. Config is saved records only.
local ui = tern.ui
local Config = require("./config")
local Authority = require("./authority")
local Native = require("./native_cli")
local Executor = require("./host_executor")
local Dispatch = require("./dispatch")
local MAX_WINDOWS = 16
local live_blocks = {}
local MAX_TEXT = 120000
local MAX_INSPECTIONS = 64 -- Active scan plus FIFO waiters, per visible panel.
local INSPECTION_DEADLINE_MS = 54000

local function text(value) return if type(value)=="string" then value else "" end
local function host_key(discovery)
	local host=if type(discovery)=="table" and type(discovery.host)=="table" then discovery.host else {}
	for _,key in ipairs({"name","address","id","kind"}) do
		local value=host[key]
		if (type(value)=="string" and value~="") or type(value)=="number" then return "host:"..string.lower(tostring(value)) end
	end
	return nil
end
local function decode(value)
	if type(value)~="string" or #value>MAX_TEXT then return nil,"JSON exceeds 120000 bytes" end
	local ok,result=pcall(tern.json.decode,value)
	return if ok then result else nil,if ok then nil else tostring(result)
end
local function inspect(window,callback,timeout_ms)
	local ok,err=pcall(Native.inspect,window,{timeout_ms=math.max(1,math.floor(timeout_ms or INSPECTION_DEADLINE_MS))},function(result,inspection_error)
		if inspection_error then callback(nil,inspection_error);return end
		if result.status~=0 or result.timed_out or #result.stdout>2000000 then callback(nil,"Host session inspection unavailable or over limit");return end
		local decoded,value=pcall(tern.json.decode,result.stdout)
		if not decoded or type(value)~="table" or type(value.sessions)~="table" then callback(nil,"Invalid host session inventory");return end
		callback(value,nil)
	end)
	if not ok then callback(nil,"Could not start host session inspection: "..tostring(err)) end
end
local function pane_sessions(inventory,pane)
	local found={}
	for _,session in ipairs(inventory.sessions) do
		if type(session.tabs)=="table" then
			for _,tab in ipairs(session.tabs) do
				if type(tab.blocks)=="table" then
					for _,block in ipairs(tab.blocks) do
						if block.id==pane then
							if type(session.id)~="number" or session.id<0 or session.id%1~=0 then return nil end
							found[tostring(session.id)]=session.id
						end
					end
				end
			end
		end
	end
	return found
end
local auto_forget
-- The captured native window is a routing hint, never session identity.
-- Verify this host pane in that exact native view twice to fence membership drift.
local function verify(state,cx,callback,deadline)
	if state.closed then return end
	deadline=deadline or (tern.now()+INSPECTION_DEADLINE_MS)
	state.inspect_queue=state.inspect_queue or {}
	if state.inspect_busy then
		if #state.inspect_queue>=MAX_INSPECTIONS-1 then
			local err="Host membership inspection queue is full; this action was not accepted. Refresh and review before submitting it again."
			state.queue_error=err;state.notice=err
			local ok,why=pcall(callback,nil,err)
			if not ok then state.transport_error="Host authority callback failed: "..tostring(why) end
			cx:render()
		else
			table.insert(state.inspect_queue,{cx=cx,callback=callback,deadline=deadline})
		end
		return
	end
	state.inspect_busy=true
	local function finish(session,err,inventory)
		if state.closed then state.inspect_busy=false;state.inspect_queue={};return end
		if session and tern.now()>deadline then session=nil;err="Host membership inspection deadline elapsed; this action was not processed" end
		if session and state.origin_session~=nil and session~=state.origin_session then session=nil;err="Authority moved from its original session. Reopen Config in the intended session; no state was rebound." end
		state.scope_error=err
		if session then state.inventory=inventory end
		local ok,why=pcall(callback,session,err)
		if not ok then state.transport_error="Host authority callback failed: "..tostring(why);state.notice=state.transport_error end
		if session then auto_forget(state) end
		cx:save();cx:render()
		state.inspect_busy=false
		local queued=table.remove(state.inspect_queue,1)
		if queued then verify(state,queued.cx,queued.callback,queued.deadline) end
	end
	local function inspect_step(window,done)
		local remaining=deadline-tern.now()
		if remaining<=0 then done(nil,"Host membership inspection deadline elapsed; this action was not processed");return end
		inspect(window,done,remaining)
	end
	local window=state.native_window
	if type(window)~="string" then finish(nil,"Config is missing its captured native window; reopen Config from SPAWN");return end
	local function read_membership()
	inspect_step(window,function(inventory,err)
		if not inventory then finish(nil,err);return end
		local found=pane_sessions(inventory,cx.pane)
		if not found then finish(nil,"Corrupt native session identity");return end
		local total,native=0,nil
		for _,id in pairs(found) do total+=1;native=id end
		-- New blocks can arrive before their tab is published in the native view.
		-- Wait only during first binding; moved/previously bound panes still fail.
		if total==0 and state.origin_session==nil and state.binding==nil and tern.now()<deadline then
			tern.timer(250,read_membership);return
		end
		if total~=1 then finish(nil,"Authority membership is missing or ambiguous. Keep this panel visible in its original session; parked membership is unknown.");return end
		inspect_step(window,function(final,why)
			if not final then finish(nil,why);return end
			local current=pane_sessions(final,cx.pane)
			local n=0;if current then for _ in pairs(current) do n+=1 end end
			if not current or n~=1 or current[tostring(native)]~=native then finish(nil,"Host membership changed during inspection; review and refresh");return end
			finish(native,nil,final)
		end)
	end)
	end
	read_membership()
end
-- Live native sessions from this host's own verified inspection (set by verify),
-- never from a window. Unavailable, failed or empty inventory yields nil.
local function live_sessions(state)
	if state.scope_error or type(state.inventory)~="table" or type(state.inventory.sessions)~="table" then return nil end
	local live=nil
	for _,session in ipairs(state.inventory.sessions) do
		if type(session.id)=="number" and session.id>=0 and session.id%1==0 then live=live or {};live[session.id]=true end
	end
	return live
end
local function reload(state)
	if not state.binding then return false end
	local snapshot,err=Authority.snapshot(state.binding)
	if not snapshot then state.notice=err;state.transport_error=err;state.reload_error=err;state.snapshot=nil;return false end
	if state.transport_error==state.reload_error then state.transport_error=nil end
	state.reload_error=nil;state.snapshot=snapshot;state.config={schema=2,agents=snapshot.records}
	return true
end
-- Each freshly verified inventory forgets ended sessions; the authority keeps
-- the bound session and absent sessions that still have active launches.
auto_forget=function(state)
	local live=live_sessions(state)
	if not state.binding or not live then return end
	local ok,result,why=pcall(Authority.forget_sessions,state.binding,live,true)
	if not ok or not result then state.notice="Automatic forgetting of ended sessions failed: "..tostring(if ok then why else result);return end
	state.forget=result
	if result.sessions>0 then reload(state) end
end
-- Refusals that admitted nothing reach the requester at once through the
-- rendered replies, without durable state. They never replace a durable reply,
-- stay scoped to the authority generation the request named, and are bounded.
local MAX_TRANSIENT=16
local function refuse(state,input,reason)
	if type(input)~="table" or type(input.request_id)~="string" or #input.request_id==0 or #input.request_id>512 or input.request_id:find("%c")
		or type(input.observer_id)~="string" or #input.observer_id==0 or #input.observer_id>256 or input.observer_id:find("%c")
		or type(input.authority_id)~="string" or type(input.request_sequence)~="number" or input.request_sequence<1 or input.request_sequence%1~=0 then return end
	if state.snapshot and state.snapshot.replies[input.request_id]~=nil then return end
	local list=state.transient or {}
	for index=#list,1,-1 do if list[index].reply.request_id==input.request_id then table.remove(list,index) end end
	if #list>=MAX_TRANSIENT then table.remove(list,1) end
	table.insert(list,{authority_id=input.authority_id,reply={request_id=input.request_id,observer_id=input.observer_id,request_sequence=input.request_sequence,ok=false,
		error=tostring(reason or "Request refused; nothing was admitted"):sub(1,4096),
		config_revision=if state.snapshot then state.snapshot.config_revision else 0,attempt_revision=if state.snapshot then state.snapshot.attempt_revision else 0}})
	state.transient=list
end
local function acknowledge_transient(state,input)
	if type(input)~="table" or type(input.acknowledged_requests)~="table" or not state.transient then return end
	for _,id in ipairs(input.acknowledged_requests) do
		for index=#state.transient,1,-1 do
			local reply=state.transient[index].reply
			if reply.request_id==id and reply.observer_id==input.observer_id then table.remove(state.transient,index) end
		end
	end
end
Executor.install(Authority,function(binding,err)
	for _,block in pairs(live_blocks) do
		local state,cx=block.state,block.cx
		if state.binding and (binding==nil or state.binding.session_key==binding.session_key) then
			reload(state)
			if err then state.notice=err end
			cx:render()
		end
	end
end)
tern.on("pane_exited",function(event)
	local block=live_blocks[event.pane]
	if block then block.state.closed=true;block.state.inspect_queue={};live_blocks[event.pane]=nil end
end)
local function mutate(state,cx,expected,op,data)
	local binding=state.binding
	verify(state,cx,function(session,err)
		if not session then state.notice=err;return end
		if state.binding~=binding then state.notice="stale-authority: review the refreshed settings and repeat your action";return end
		if not state.binding or not reload(state) then return end
		local ok,why=Authority.edit(state.binding,expected,op,data)
		reload(state);state.notice=if ok then "Saved. No agents were launched." else why
		state.editing=nil
	end)
end
local function action(state,name) return name.."@"..tostring(if state.snapshot then state.snapshot.config_revision else -1) end
local function switch_row(id,label,on,hint) return {id=id,label=label,hint=hint,control={k="switch",on=on}} end
local function text_row(id,label,value,hint,disabled) return {id=id,label=label,hint=hint,disabled=disabled,control={k="text",value=value,mono=true}} end
local function choice_row(id,label,value,options,hint) return {id=id,label=label,hint=hint,control={k="choice",value=value,options=options,style="menu"}} end
local function action_row(id,label,act,hint) return {id=id,label=label,hint=hint,control={k="action",act=act,label=label}} end
local function static_row(id,label,value,hint)
	return {id=id,label=label,hint=value.."\n"..hint,disabled="Read-only observation",control={k="action",act="noop",label="Read only"}}
end
local function record_by_id(state,id)
	for index,record in ipairs(state.config.agents) do if record.id==id then return record,index end end
	return nil,nil
end
local function record_row_id(state,id,field) return "agent:"..id..":"..field..":"..tostring(state.snapshot.config_revision) end
local function parse_record_row(item)
	if type(item)~="string" then return nil end
	local id,field,revision=item:match("^agent:(.+):([^:]+):(%d+)$")
	return id,field,tonumber(revision)
end
local function provider_options(state)
	local providers={};local seen={}
	for _,record in ipairs(state.config.agents) do
		local key=string.lower(record.provider)
		if not seen[key] then seen[key]=true;table.insert(providers,record.provider) end
	end
	table.sort(providers,function(a,b)return string.lower(a)<string.lower(b) end)
	local options={{value="",label="All providers"}}
	for _,provider in ipairs(providers) do table.insert(options,{value=provider,label=provider}) end
	return options
end
local function filtered_records(state)
	local matches={};local provider=string.lower(state.provider_filter);local label=string.lower(state.label_filter)
	for _,record in ipairs(state.config.agents) do
		if (provider=="" or string.lower(record.provider)==provider) and (label=="" or string.find(string.lower(record.account_label),label,1,true)) then table.insert(matches,record) end
	end
	table.sort(matches,function(a,b)
		local ap,bp=string.lower(a.provider),string.lower(b.provider)
		if ap~=bp then return ap<bp end
		local al,bl=string.lower(a.account_label),string.lower(b.account_label)
		if al~=bl then return al<bl end
		return a.id<b.id
	end)
	return matches
end
local function review_sections(state)
	local review=state.snapshot.migration;local rows={};local ids={}
	for _,source in ipairs(review.sources) do for _,record in ipairs(source.records) do ids[record.id]=true end end
	local sorted={};for id in pairs(ids) do table.insert(sorted,id) end;table.sort(sorted)
	for _,id in ipairs(sorted) do
		local options={{value="",label="Choose deliberately"},{value="0",label="Omit from saved roster (original preserved)"}}
		for index,source in ipairs(review.sources) do
			for _,record in ipairs(source.records) do
				if record.id==id then
					table.insert(options,{value=tostring(index),label=source.label})
					table.insert(rows,static_row("source-"..id.."-"..tostring(index),id.." · "..source.label,tern.json.encode(record),"Preserved candidate, including command, arguments, account routing and prompt. Choose one source below."))
				end
			end
		end
		table.insert(rows,choice_row("review:"..id..":"..tostring(state.snapshot.config_revision),id.." · source",if review.choices[id]~=nil then tostring(review.choices[id]) else "",options,"Every record needs an explicit choice. Originals remain preserved."))
	end
	table.insert(rows,action_row("review-confirm","Confirm selected migration",action(state,"review-confirm"),review.reason))
	return {{id="migration",page=state.page,title="Review saved sources",rows=rows}}
end
local function setup_sections(state)
	local rows={
		static_row("setup-host","Execution host",state.host_key or "Unknown","Settings belong to this host; labels do not isolate accounts."),
		action_row("setup-flow","Guided setup","setup","A verified OMP setup agent reviews providers, accounts and approved launch settings."),
		action_row("setup-add-local","Add local record manually",action(state,"add-local"),"Adds a disabled-by-review record; approve its command in Config."),
		action_row("setup-add-ssh","Add SSH record manually",action(state,"add-ssh"),"Review the SSH destination, command and account before launch."),
		text_row("manual-json","Paste setup JSON",state.import_text,"Paste the complete schema-2 JSON, including setup_run_id and confirmed when recovering Guided setup. Use its original host and session; nothing starts."),
		action_row("bridge-import","Allow roster import","bridge-import-open","Paste the complete migration preview JSON above. This opens an exact one-use host gate only; no import or launch."),
		action_row("bridge-import-cancel","Cancel pending roster import","bridge-import-cancel","Invalidates this Config panel's unconsumed migration gate."),
		static_row("bridge-import-gate","Migration gate",state.bridge_import_gate or "Closed","Only an explicit owner action opens this gate. Runtime reload invalidates an unused gate."),
		action_row("manual-review","Review pasted JSON",action(state,"manual-review"),"Validate every record, argument and existing ID before confirmation."),
		action_row("setup-reset",if state.armed=="reset-roster" then "Confirm delete saved roster" else "Delete saved roster",action(state,"reset-roster"),"Two deliberate clicks; installations, logins and launch history are unchanged."),
	}
	local preview,records=Dispatch.import_decode(state.import_text,true)
	if preview then
		table.insert(rows,static_row("bridge-import-source","Migration source",preview.source_client,"Source revision "..tostring(preview.source_revision).." · SHA256 "..preview.source_sha256))
		table.insert(rows,static_row("bridge-import-target","Migration target",preview.target_host,"Must match this Config host before the one-use gate can open."))
		for index,record in ipairs(records) do table.insert(rows,static_row("bridge-import-record-"..tostring(index),record.id,tern.json.encode(record),"Non-secret configuration snapshot; divergent existing IDs remain a conflict.")) end
	end
	if state.import_review then
		for _,record in ipairs(state.import_review.records) do table.insert(rows,static_row("import-"..record.id,record.id,tern.json.encode(record),"Review the exact settings; conflicting IDs are never renamed or overwritten.")) end
		table.insert(rows,action_row("manual-confirm","Confirm import", "manual-confirm@"..tostring(state.import_review.revision),"Uses the same validator and import operation as Guided setup."))
	end
	return {{id="setup-guide",page="setup",title="Agent setup",rows=rows}}
end
local function record_sections(state)
	local included=0;for _,record in ipairs(state.config.agents) do if record.include_all then included+=1 end end
	local sections={
		{id="agent-overview",page="agents",title="Overview",rows={static_row("agents-configured","Agents configured",tostring(#state.config.agents),"Saved provider records only."),static_row("agents-included","Included in Spawn all",tostring(included),"Enabled, reviewed settings are required before launch.")}},
		{id="agent-filters",page="agents",title="Agent details",rows={choice_row("agents-filter-provider","Filter by provider",state.provider_filter,provider_options(state),"Providers come only from saved records."),text_row("agents-filter-label","Filter by label",state.label_filter,"Matches saved account suffixes.")}},
	}
	local matches=filtered_records(state)
	if #matches==0 then table.insert(sections,{id="agent-empty",page="agents",title="Matching agents",rows={static_row("agents-empty","Matching agents","None","No saved records match these filters.")}}) end
	for _,record in ipairs(matches) do
		local prefix=function(field)return record_row_id(state,record.id,field) end
		local backends={{value="local-terminal",label="Terminal"},{value="ssh-command",label="SSH terminal"}}
		if string.lower(record.provider)=="omp" then table.insert(backends,1,{value="native-agent",label="Native OMP"}) end
		local rows={
			text_row(prefix("id"),"Stable id",record.id,"Duplicate and launch-history identity.","Stable ids are immutable"),
			text_row(prefix("provider"),"Provider",record.provider,"Changing away from OMP requires selecting Terminal or SSH terminal and reviewing its command first."),
			text_row(prefix("account_label"),"Account label suffix",record.account_label,"A distinguishing suffix, not an account-isolation mechanism."),
			choice_row(prefix("backend"),"Launch mode",record.backend,backends,"Settings only; this editor never launches a process."),
			text_row(prefix("command"),"Command",text(record.command),"Approved executable name or path."),
			text_row(prefix("arguments"),"Arguments",Config.render_arguments(record.arguments),"Shell-like editor syntax preserves quoted argument boundaries."),
			text_row(prefix("cwd"),"Working directory",text(record.cwd),"Used on the execution host."),
			choice_row(prefix("placement"),"Placement",record.placement,{{value="tab",label="New tab"},{value="split",label="Split"},{value="replace_if_alone",label="Replace if alone"}},"Saved placement: tab, split, or replace_if_alone."),
			choice_row(prefix("duplicate_policy"),"Duplicate policy",record.duplicate_policy,{{value="skip",label="Skip existing"},{value="allow",label="Allow duplicate"}},"Unresolved reservations block Skip existing until explicitly inspected and resolved."),
			switch_row(prefix("enabled"),"Enabled",record.enabled,"Disabled records cannot launch."),
			switch_row(prefix("include_all"),"Include in all",record.include_all,"Include this record in Spawn all."),
			text_row(prefix("user"),"Unix user",text(record.user),"Non-secret account routing; labels do not create users."),
			text_row(prefix("json"),"Full record JSON","","Activate to load this one record, including mailbox, fresh-launch and model/profile fields. Keep its stable ID. Saving changed JSON requires explicit settings approval before launch."),
		}
		if record.backend=="native-agent" or record.backend=="ssh-command" or record.host then table.insert(rows,text_row(prefix("host"),"Host",text(record.host),"Native host identity or explicit SSH destination.")) end
		if record.backend=="ssh-command" then table.insert(rows,text_row(prefix("key_path"),"Key path",text(record.key_path),"Path only; never paste private key contents.")) end
		if string.lower(record.provider)=="omp" then
			table.insert(rows,text_row(prefix("prompt"),"Approved startup prompt",text(record.prompt),"Delivered once per new Native OMP launch; never on reload. A custom nonempty prompt is preserved."))
		end
		if record.review_required then
			table.insert(rows,static_row("review-reason-"..record.id,"Needs settings review",text(record.review_reason),"Edit the launch settings, then explicitly approve them."))
			table.insert(rows,action_row("approve-"..record.id,"Approve reviewed command and settings",action(state,"approve:"..record.id),"Clears the review block only if the full canonical record validates."))
		end
		table.insert(sections,{id="record-"..record.id,page="agents",title=record.provider.." — "..record.account_label.." · "..record.id,rows=rows})
	end
	return sections
end
local function runtime_sections(state)
	local live={};local history={};local other={};local transport={}
	for _,a in ipairs(state.snapshot.attempts) do
		local target=if a.phase=="Exited" or a.phase=="Failed" or not a.unresolved then history else live
		local phase=if state.scope_error and a.unresolved then "Unknown (last observed "..a.phase..")" else a.phase
		local detail=phase.." · "..a.mode.." · observer "..a.observer_id.." · pane "..tostring(a.pane or "unbound")
		if a.exit_status~=nil then detail..=" · exit "..tostring(a.exit_status) end
		if a.error_category then detail..=" · "..a.error_category end
		if a.diagnostic then detail..=" · "..a.diagnostic end
		table.insert(target,static_row("attempt-"..a.id,a.record_id.." · "..a.id,detail,"Observation scope "..a.scope..". Liveness is observer-reported, not authentication or readiness."))
		if a.unresolved then table.insert(target,action_row("resolve-"..a.id,if state.armed=="resolve:"..a.id then "Confirm mark no longer running" else "Mark no longer running",action(state,"resolve:"..a.id),"Inspect the original pane first. This releases only its reservation; it never closes a pane.")) end
	end
	if #live==0 then table.insert(live,static_row("live-empty","SPAWN launches","None","No active or unresolved saved reservations in this native session.")) end
	if #history==0 then table.insert(history,static_row("history-empty","Failed/exited history","None","Failed terminal output stays in its original shell pane.")) end
	table.insert(history,action_row("clear-history",if state.armed=="clear-history" then "Confirm clear reviewed terminal history" else "Clear reviewed terminal history",action(state,"clear-history"),"Only resolved/terminal metadata is removed; panes and unresolved attempts remain."))
	if state.scope_error or not state.inventory then
		table.insert(other,static_row("other-unknown","Observation scope","Unknown",state.scope_error or "Refresh to inspect visible host sessions."))
	else
		local seen={}
		for _,session in ipairs(state.inventory.sessions) do
			if session.id~=state.origin_session and not seen[session.id] then seen[session.id]=true;table.insert(other,static_row("other-"..tostring(session.id),text(session.name),"Native session "..tostring(session.id),"Read-only visible host inventory; never imported as a configured account. Parked membership is unknown.")) end
		end
		if #other==0 then table.insert(other,static_row("other-empty","Other Tern sessions","None visible","Read-only scope: this authority's owning native window inventory. Other client views are available through Running agents.")) end
		local forget=state.forget
		local kept=if forget and forget.kept>0 then string.format(" %d absent sessions kept because they still have active launches.",forget.kept) else ""
		local last=if forget then string.format("last run: %d sessions / %d attempts",forget.sessions,forget.attempts) else "not run yet"
		table.insert(other,static_row("forget-status","Ended sessions","Forgotten automatically · "..last,"Sessions absent from this window's live inventory lose only their saved SPAWN history; this session is kept."..kept))
	end
	for id,reply in pairs(state.snapshot.replies) do
		table.insert(transport,static_row("reply-"..id,id,tern.json.encode(reply),"Retained until its observer acknowledges it or you explicitly review it below."))
		table.insert(transport,action_row("review-reply-"..id,if state.armed=="review-reply:"..id then "Confirm reviewed result" else "Mark result reviewed",action(state,"review-reply:"..id),"The observer may no longer receive this result; inspect its exact outcome before confirmation."))
	end
	table.insert(transport,action_row("reset-transport",if state.armed=="reset-transport" then "Confirm transport identity reset" else "Reset reviewed transport",action(state,"reset-transport"),"Requires no pending requests and every result acknowledged or reviewed. Preserves roster and attempts; old clients must reopen Config."))
	if state.binding then
		local owners,why=Dispatch.recovery_view(state.binding)
		if not owners then table.insert(transport,static_row("bridge-recovery-error","Managed dispatch",tostring(why),"Preserve the transport registry; no automatic reset."))
		else for _,owner in ipairs(owners) do
			local id=owner.logical_session_id
			table.insert(transport,static_row("bridge-owner-"..id,"Managed controller "..id,tern.json.encode(owner),"Inspect original controller and every launch executor, including unavailable/parked windows. Alias numbers are window-scoped."))
			table.insert(transport,action_row("bridge-recover-"..id,if owner.fenced then "I verified previous controller and pending launch executors stopped or retired" else "Fence managed controller for recovery","bridge-recover:"..id..":"..tostring(owner.revision)..":"..(if owner.fenced then "confirm" else "fence"),"Confirmation records operator attestation, not machine proof. Stop known-active executors first. It never starts a replacement or clears worker reservations."))
		end end
	end
	return {{id="running",page="runtime",title="SPAWN launches",rows=live},{id="history",page="runtime",title="Failed/exited history",rows=history},{id="other",page="runtime",title="Other Tern sessions",rows=other},{id="transport",page="runtime",title="Transport review",rows=transport}}
end
local function view(state)
	local snapshot=if state.snapshot then Authority.clone(state.snapshot) else {version=2,host_key=state.host_key or "unknown",authority_id="unavailable",session_key="unknown",config_revision=0,records={},attempt_revision=0,attempts={},jobs={},replies={},request_sequences={},host_os=tern.runtime.os,host_shell=tern.getenv("SHELL") or tern.getenv("ComSpec") or "unknown",ready=false}
	local replies=0;for _ in pairs(snapshot.replies) do replies+=1 end
	for _,entry in ipairs(state.transient or {}) do
		local id=entry.reply.request_id
		if entry.authority_id==snapshot.authority_id and snapshot.replies[id]==nil and replies<64 then snapshot.replies[id]=Authority.clone(entry.reply);replies+=1 end
	end
	if state.scope_error or not state.binding then snapshot.ready=false;snapshot.error=state.scope_error or state.notice or "Host membership pending" end
	local failure=state.reload_error or state.queue_error or state.transport_error
	if failure then snapshot.ready=false;snapshot.error=failure end
	local lead="One saved launch configuration per account. Runtime observations never create Config records."
	if state.notice then lead..=" "..state.notice end
	if snapshot.error then lead..=" "..snapshot.error end
	local sections={}
	if state.snapshot then
		if state.snapshot.migration then sections=review_sections(state)
		elseif state.page=="setup" then sections=setup_sections(state)
		elseif state.page=="runtime" then sections=runtime_sections(state)
		else sections=record_sections(state) end
	end
	table.insert(sections,{id="refresh",page=state.page,title="Authority",rows={action_row("refresh","Refresh saved settings and host membership","refresh","Refresh before editing an old panel. Stale forms never overwrite newer settings.")}})
	local payload="SPAWN_STATE_V2 "..tern.json.encode(snapshot)
	if #payload>120000 then
		payload="SPAWN_STATE_V2 "..tern.json.encode({version=2,host_key=snapshot.host_key,authority_id=snapshot.authority_id,session_key=snapshot.session_key,config_revision=snapshot.config_revision,records={},attempt_revision=snapshot.attempt_revision,attempts={},jobs={},replies={},request_sequences={},host_os=snapshot.host_os,host_shell=snapshot.host_shell,ready=false,error="Snapshot exceeds capacity; preserved state was not truncated or reset"})
	end
	local diagnostic=ui.text(payload);diagnostic.p=diagnostic.p or {};diagnostic.p.key="spawn-state"
	return {main=ui.col({ui.node("prefs",{title="SPAWN",lead=lead,pages={{id="setup",label="Setup",icon="sparkle"},{id="agents",label="Configured agents",icon="sparkle"},{id="runtime",label="Running agents",icon="sparkle"}},page=state.page,sections=sections,focus=state.focus,editing=state.editing}),diagnostic})}
end
local function update_record(state,cx,id,field,value,revision)
	local record,index=record_by_id(state,id);if not record then return end
	if field=="json" then
		if not state.snapshot or revision~=state.snapshot.config_revision then reload(state);state.notice="stale-config: review the refreshed settings and repeat your edit";return end
		local candidate,err=decode(value)
		if not candidate then state.notice=err or "Expected one complete record object";return end
		local canonical,why=Config.validate_record(candidate)
		if not canonical then state.notice=why;return end
		if canonical.id~=id then state.notice="Stable ids are immutable; full-record JSON must keep this record's ID";return end
		if Dispatch.protocol.equal(canonical,record) then state.notice="Record unchanged. No agents were launched.";return end
		canonical.review_required=true
		canonical.review_reason=record.review_reason or "Review all launch, mailbox and selector settings after editing this record's JSON"
		local next_records=Authority.clone(state.config.agents);next_records[index]=canonical
		mutate(state,cx,revision,"replace-records",{records=next_records});return
	end
	local allowed={provider=true,account_label=true,host=true,user=true,key_path=true,command=true,arguments=true,cwd=true,prompt=true,placement=true,backend=true,duplicate_policy=true,enabled=true,include_all=true}
	if not allowed[field] then return end
	local candidate=Authority.clone(record)
	if field=="arguments" then
		local args,err=Config.parse_arguments(value);if not args then state.notice=err;return end;value=args
	elseif field=="enabled" or field=="include_all" then
		if type(value)~="boolean" then state.notice="Expected a switch value";return end
	elseif type(value)~="string" or #value>32000 then state.notice="Invalid or oversized field";return end
	if field=="provider" and string.lower(value)~="omp" and record.backend=="native-agent" then state.notice="Select Terminal or SSH terminal and review an ordinary command before changing this provider away from OMP";return end
	candidate[field]=value
	if field=="backend" and value~=record.backend then candidate.review_required=true;candidate.review_reason="Review this account's launch command and routing after changing launch mode" end
	local canonical,err=Config.validate_record(candidate);if not canonical then state.notice=err;return end
	local next_records=Authority.clone(state.config.agents);next_records[index]=canonical
	mutate(state,cx,revision,"replace-records",{records=next_records})
end
local function utf8_width(byte)
	if byte<0x80 then return 1,1 end
	if byte>=0xC2 and byte<=0xDF then return 2,1 end
	if byte>=0xE0 and byte<=0xEF then return 3,1 end
	if byte>=0xF0 and byte<=0xF4 then return 4,2 end
	return 1,1
end
local function boundaries(value)
	local bytes={1};local units={0};local byte_index,utf16=1,0
	while byte_index<=#value do
		local width,n=utf8_width(string.byte(value,byte_index))
		if byte_index+width-1>#value then width,n=1,1 end
		byte_index+=width;utf16+=n;table.insert(bytes,byte_index);table.insert(units,utf16)
	end
	return bytes,units
end
local function utf16_length(value) local _,units=boundaries(value);return units[#units] end
local function cursor_index(value,cursor)
	local bytes,units=boundaries(value);local target=math.max(0,math.min(cursor,units[#units]))
	for index,unit in ipairs(units) do if unit>=target then return index,unit end end
	return #bytes,units[#units]
end
local function open(state,cx)
	verify(state,cx,function(session,err)
		if not session then state.notice=err;return end
		if state.binding then
			local snapshot,why=Authority.snapshot(state.binding)
			if not snapshot and type(why)=="string" and why:find("stale-authority",1,true) then
				state.binding=nil;state.snapshot=nil;state.import_review=nil;state.editing=nil;state.armed=nil
				state.notice="Authority generation changed. Review the refreshed settings and choose a new action; no previous request was replayed."
			end
		end
		if not state.binding then
			if not state.host_key then state.notice="Execution host metadata is missing; reopen Config from SPAWN on the intended host";return end
			local binding,why=Authority.open(state.host_key,session,state.client_config,state.origin_scope)
			if not binding then state.notice=why;state.transport_error=why;return end
			state.binding=binding;state.origin_session=session;state.origin_scope=binding.session_key;state.client_config=nil;state.host_key=binding.host_key
			Executor.attach(binding)
		end
		state.transport_error=nil;state.queue_error=nil;reload(state)
	end)
end
local definition={
	font="sans",
	init=function(cx,args,saved)
		local discovery=nil;if #args>0 then discovery=decode(args[1]) end
		local state={config={schema=2,agents={}},host_key=host_key(discovery),page="agents",provider_filter="",label_filter="",import_text="",notice=nil,editing=nil,focus=nil}
		if type(saved)=="table" then
			if saved.page=="setup" or saved.page=="agents" or saved.page=="runtime" then state.page=saved.page end
			if type(saved.origin_session)=="number" then state.origin_session=saved.origin_session end
			if type(saved.origin_scope)=="string" then state.origin_scope=saved.origin_scope end
			if not state.host_key and type(saved.host_key)=="string" then state.host_key=saved.host_key end
		end
		if type(discovery)=="table" then
			state.native_window=discovery.native_window
			state.client_config=discovery.client_config
			if discovery.page=="runtime" then state.page="runtime" end
		end
		live_blocks[cx.pane]={state=state,cx=cx}
		open(state,cx);return state
	end,
	view=function(state,_cx)return view(state) end,
	event=function(state,event,cx)
		local incoming=event
		if event.ev=="action" and event.id=="main" and event.act=="spawn.request" then
			local input,err=decode(event.value)
			if not input then state.transport_error=err;return end
			acknowledge_transient(state,input)
			verify(state,cx,function(session,why)
				if not session then state.transport_error=why;refuse(state,input,why);return end
				if not state.binding then state.transport_error="Authority not initialized";refuse(state,input,state.transport_error);return end
				local ok,reason=Authority.request(state.binding,input)
				if ok and (input.op=="launch_record" or input.op=="start_setup") then Executor.attach(state.binding) end
				state.transport_error=if ok then nil else reason;reload(state)
				if not ok then refuse(state,input,reason) end
			end)
			return
		end
		if event.ev=="change" then
			if incoming.item=="agents-filter-provider" then state.provider_filter=text(incoming.value);state.editing=nil
			elseif incoming.item=="manual-json" then state.import_text=text(incoming.value);state.import_review=nil
			else
				local rid,rev=nil,nil
				if type(incoming.item)=="string" then rid,rev=incoming.item:match("^review:(.+):(%d+)$") end
				if rid then mutate(state,cx,tonumber(rev),"review-choice",{id=rid,source=tonumber(incoming.value)})
				else local id,field,revision=parse_record_row(incoming.item);if id then update_record(state,cx,id,field,incoming.value,revision) end end
			end
		elseif event.ev=="activate" then
			local item=incoming.item;local draft=nil;local revision=nil
			if item=="agents-filter-provider" then state.focus=item;state.editing={row=item,option=state.provider_filter};return
			elseif item=="agents-filter-label" then draft=state.label_filter
			elseif item=="manual-json" then draft=state.import_text
			else
				local id,field,rev=parse_record_row(item);revision=rev
				if id then
					local record=record_by_id(state,id)
					if record and field=="json" then
						if not state.snapshot or rev~=state.snapshot.config_revision then reload(state);state.notice="stale-config: activate the refreshed record editor";return end
						draft=tern.json.encode(record)
					elseif record and type(record[field])~="boolean" then draft=if field=="arguments" then Config.render_arguments(record.arguments) else text(record[field]) end
				end
			end
			if draft then state.focus=item;state.editing={row=item,draft=draft,cursor=utf16_length(draft),revision=revision} end
		elseif event.ev=="action" then
			if event.act=="page" and (event.value=="setup" or event.value=="agents" or event.value=="runtime") then state.page=event.value;state.focus=nil;state.editing=nil;state.armed=nil;open(state,cx);return end
			if event.act=="refresh" then open(state,cx);return end
			local recovery_id,recovery_revision,recovery_mode=event.act:match("^bridge%-recover:([A-Za-z0-9_-]+):(%d+):(%a+)$")
			if recovery_id then
				verify(state,cx,function(session,why)
					if not session or not state.binding then state.notice=why or "Open original Config session";return end
					local ok,err=Dispatch.recover_owner(state.binding,recovery_id,tonumber(recovery_revision),recovery_mode=="confirm")
					state.notice=if ok then "Recovery recorded. No replacement launched; old worker reservations remain for separate inspection." else err
				end);return
			end
			if event.act=="bridge-import-open" then
				verify(state,cx,function(session,why)
					if not session or not state.binding then state.notice=why or "Open Config first";return end
					local gate,err=Dispatch.open_import(state.binding,state.import_text)
					state.bridge_import_gate=gate;state.notice=if gate then "Roster import gate opened: "..gate..". Nothing imported or launched." else err
				end);return
			end
			if event.act=="bridge-import-cancel" then
				local ok,why=Dispatch.cancel_import(state.bridge_import_gate)
				if ok then state.bridge_import_gate=nil end
				state.notice=if ok then "Import gate cancelled" else why;return
			end
			if event.act=="setup" then cx:action("plugin.spawn.spawn_setup");return end
			if event.act=="close" then if event.value==nil then state.closed=true;state.inspect_queue={};live_blocks[cx.pane]=nil;cx:exit(0) else state.editing=nil;state.focus=nil end;return end
			local op,rev=event.act:match("^(.*)@(%d+)$");local expected=tonumber(rev)
			if not op or not state.snapshot then return end
			if expected~=state.snapshot.config_revision then reload(state);state.notice="stale-config: review the refreshed settings and repeat your action";return end
			if op=="review-confirm" then mutate(state,cx,expected,"review-confirm",{});return end
			if op=="manual-review" then
				local payload,err=decode(state.import_text)
				if not payload or type(payload)~="table" or payload.schema~=2 or type(payload.agents)~="table" then state.notice=err or "Expected current-schema {schema:2,agents:[...]} JSON";return end
				for k in pairs(payload) do if k~="schema" and k~="agents" and k~="setup_run_id" and k~="confirmed" then state.notice="Unexpected setup JSON field: "..tostring(k);return end end
				if payload.setup_run_id~=nil or payload.confirmed~=nil then
					if type(payload.setup_run_id)~="string" or #payload.setup_run_id==0 or #payload.setup_run_id>256 or payload.setup_run_id:find("%c") or payload.confirmed~=true then state.notice="Guided setup recovery requires a valid setup_run_id and confirmed:true; otherwise paste a manual schema/agents object";return end
				end
				local records,why=Config.validate_records(payload.agents);if not records then state.notice=why;return end
				state.import_review={records=records,revision=expected,run=payload.setup_run_id};state.notice="Validated every record. Review the exact settings below on the original host/session, then Confirm import.";return
			elseif op=="manual-confirm" then
				local review=state.import_review;if not review then state.notice="Review pasted JSON first";return end
				local binding=state.binding
				verify(state,cx,function(session,err)
					if not session then state.notice=err;return end
					if state.binding~=binding or state.import_review~=review then state.notice="stale-authority: review the pasted JSON again before importing";return end
					if not reload(state) then return end
					local observer="config-"..tostring(cx.pane);local seq=(state.snapshot.request_sequences[observer] or 0)+1;local acks={}
					-- The persisted authority generation and observer watermark survive
					-- fresh runtimes; retain this run ID if confirmation is repeated.
					if not review.run then review.run=state.binding.authority_id.."/manual/"..observer.."/"..tostring(seq) end
					for id,reply in pairs(state.snapshot.replies) do if reply.observer_id==observer then table.insert(acks,id) end end
					local request={version=2,request_id=observer..":"..tostring(seq),authority_id=state.binding.authority_id,observer_id=observer,request_sequence=seq,acknowledged_requests=acks,expected_config_revision=review.revision,op="import_records",data={setup_run_id=review.run,records=review.records}}
					local ok,why=Authority.request(state.binding,request);reload(state)
					local reply=state.snapshot and state.snapshot.replies[request.request_id]
					if ok and reply and reply.ok then state.import_review=nil;state.import_text="";state.notice="Imported "..tostring(reply.result.imported).." records. No agents were launched." else state.notice=why or (reply and reply.error) or "Import was not acknowledged; refresh and review transport" end
					if reply then
						local consumed,consume_error=Authority.edit(state.binding,state.snapshot.config_revision,"review-reply",{id=request.request_id})
						reload(state)
						if not consumed then state.notice..=" Result acknowledgment failed: "..tostring(consume_error) end
					end
				end);return
			elseif op=="add-local" or op=="add-ssh" then
				local base=if op=="add-ssh" then "ssh-agent" else "local-agent";local id=base;local n=1
				while record_by_id(state,id) do n+=1;id=base.."-"..tostring(n) end
				local records=Authority.clone(state.config.agents)
				table.insert(records,{id=id,provider=if op=="add-ssh" then "SSH agent" else "Local agent",account_label="Default",backend=if op=="add-ssh" then "ssh-command" else "local-terminal",enabled=true,include_all=true,duplicate_policy="skip",placement="tab",arguments={},review_required=true,review_reason="Review this account's launch command and routing"})
				state.page="agents";mutate(state,cx,expected,"replace-records",{records=records});return
			end
			local approve_id=op:match("^approve:(.+)$")
			if approve_id then
				local record,index=record_by_id(state,approve_id);if not record then return end
				local candidate=Authority.clone(record)
				candidate.review_required=nil;candidate.review_reason=nil
				local validated,why=Config.validate_record(candidate);if not validated then state.notice=why;return end
				local records=Authority.clone(state.config.agents);records[index]=validated;mutate(state,cx,expected,"replace-records",{records=records});return
			end
			if op=="reset-roster" or op=="clear-history" or op=="reset-transport" or op:match("^resolve:") or op:match("^review%-reply:") then
				if state.armed~=op then state.armed=op;state.armed_attempt_revision=state.snapshot.attempt_revision;state.notice="Inspect the displayed state, then click the confirmation again.";return end
				state.armed=nil
				if op=="reset-roster" then mutate(state,cx,expected,"replace-records",{records={}})
				elseif op:match("^resolve:") then mutate(state,cx,expected,"resolve-attempt",{id=op:sub(9),attempt_revision=state.armed_attempt_revision})
				elseif op:match("^review%-reply:") then mutate(state,cx,expected,"review-reply",{id=op:sub(14)})
				else mutate(state,cx,expected,op,{attempt_revision=state.armed_attempt_revision}) end
			end
		end
	end,
	key=function(state,key,cx)
		local editing=state.editing;if type(editing)~="table" then return false end
		if key.name=="escape" then state.editing=nil;state.focus=nil;return true end
		if type(editing.draft)~="string" then return false end
		if key.name=="enter" then
			if editing.row=="agents-filter-label" then state.label_filter=editing.draft
			elseif editing.row=="manual-json" then state.import_text=editing.draft;state.import_review=nil
			else local id,field,rev=parse_record_row(editing.row);if id then update_record(state,cx,id,field,editing.draft,rev) end end
			state.editing=nil;state.focus=nil;return true
		end
		local draft=editing.draft;local index,cursor=cursor_index(draft,editing.cursor);local bytes,units=boundaries(draft)
		if key.name=="left" then if index>1 then editing.cursor=units[index-1];return true end;return false
		elseif key.name=="right" then if index<#bytes then editing.cursor=units[index+1];return true end;return false
		elseif key.name=="backspace" then if index==1 then return false end;draft=draft:sub(1,bytes[index-1]-1)..draft:sub(bytes[index]);editing.cursor=units[index-1]
		elseif key.name=="delete" then if index>=#bytes then return false end;draft=draft:sub(1,bytes[index]-1)..draft:sub(bytes[index+1]);editing.cursor=cursor
		elseif type(key.text)=="string" and key.text~="" and #draft+#key.text<=MAX_TEXT then draft=draft:sub(1,bytes[index]-1)..key.text..draft:sub(bytes[index]);editing.cursor=cursor+utf16_length(key.text)
		else return false end
		editing.draft=draft;return true
	end,
	save=function(state)return {page=state.page,host_key=state.host_key,origin_session=state.origin_session,origin_scope=state.origin_scope} end,
}
tern.block.define("spawner",definition)

-- Enumerate the owning daemon's native client keys. Window aliases and names are
-- never used as native session identity. A final membership read fences scan drift.
local function bridge_membership(state,cx,callback,deadline)
	deadline=deadline or (tern.now()+INSPECTION_DEADLINE_MS)
	state.inspect_queue=state.inspect_queue or {}
	if state.inspect_busy then
		if #state.inspect_queue>=MAX_INSPECTIONS-1 then
			local err="Host membership inspection queue is full; this action was not accepted. Refresh and review before submitting it again."
			state.queue_error=err;state.notice=err
			local ok,why=pcall(callback,nil,err)
			if not ok then state.transport_error="Host authority callback failed: "..tostring(why) end
			cx:render()
		else
			table.insert(state.inspect_queue,{cx=cx,callback=callback,deadline=deadline})
			cx:render() -- Keep the bridge lease busy for the queued verification too.
		end
		return
	end
	state.inspect_busy=true
	-- Render before the asynchronous inspection so the bridge lease reads busy for the whole
	-- in-flight window (up to INSPECTION_DEADLINE_MS); ORCH+ never closes or adopts a busy bridge.
	cx:render()
	local function finish(session,err,inventory)
		if session and tern.now()>deadline then session=nil;err="Host membership inspection deadline elapsed; this action was not processed" end
		if session and state.origin_session~=nil and session~=state.origin_session then session=nil;err="Authority moved from its original session. Reopen Config in the intended session; no state was rebound." end
		state.scope_error=err
		if session then state.inventory=inventory end
		local ok,why=pcall(callback,session,err)
		if not ok then state.transport_error="Host authority callback failed: "..tostring(why);state.notice=state.transport_error end
		cx:save();cx:render()
		state.inspect_busy=false
		local queued=table.remove(state.inspect_queue,1)
		-- The bridge lease reports busy while inspecting; render once more so it reads idle again.
		if queued then bridge_membership(state,queued.cx,queued.callback,queued.deadline) else cx:render() end
	end
	local function inspect_step(window,done)
		local remaining=deadline-tern.now()
		if remaining<=0 then done(nil,"Host membership inspection deadline elapsed; this action was not processed");return end
		inspect(window,done,math.min(3000,remaining))
	end
	inspect_step(nil,function(initial,err)
		if not initial then finish(nil,err);return end
		if type(initial.clients)~="table" then finish(nil,"Host client inventory is unavailable");return end
		local keys={};local seen={}
		-- Window halves attached through `tern remote serve` list as kind "remote"; their
		-- sessions live on this host daemon exactly like local desktop windows.
		for _,client in ipairs(initial.clients) do
			if (client.kind=="window" or client.kind=="remote") and type(client.window)=="string" and not seen[client.window] then
				if #client.window>256 then finish(nil,"Invalid native window identity");return end
				seen[client.window]=true;table.insert(keys,client.window)
			end
		end
		if #keys==0 or #keys>MAX_WINDOWS then finish(nil,"Visible host membership is missing or exceeds the 16-window inspection limit");return end
		local index=0;local memberships={};local owner=nil
		local function scan()
			index+=1
			if index>#keys then
				local total=0;local native=nil
				for _,id in pairs(memberships) do total+=1;native=id end
				if total~=1 then finish(nil,"Authority membership is missing or ambiguous. Keep this panel visible in its original session; parked membership is unknown.");return end
				inspect_step(owner,function(final,why)
					if not final then finish(nil,why);return end
					local current=pane_sessions(final,cx.pane)
					local n=0;if current then for _ in pairs(current) do n+=1 end end
					if not current or n~=1 or current[tostring(native)]~=native then finish(nil,"Host membership changed during inspection; review and refresh");return end
					finish(native,nil,final)
				end)
				return
			end
			inspect_step(keys[index],function(inventory,why)
				if not inventory then finish(nil,why);return end
				local found=pane_sessions(inventory,cx.pane)
				if not found then finish(nil,"Corrupt native session identity");return end
				for k,id in pairs(found) do memberships[k]=id;owner=keys[index] end
				scan()
			end)
		end
		scan()
	end)
end

-- The non-palette bridge is deliberately separate from normal Config rendering.
local Protocol=Dispatch.protocol
local Codec=require("./codec")
local function dispatch_verify(state,cx,r,callback)
	bridge_membership(state,cx,function(session,why)
		if not session then callback(nil,why);return end
		local controller=tonumber(r.origin_binding.host_pane_id)
		local memberships=if controller then pane_sessions(state.inventory,controller) else nil
		local n=0;if memberships then for _ in pairs(memberships) do n+=1 end end
		if not memberships or n~=1 or memberships[tostring(session)]~=session then callback(nil,"Controller source is not on this bridge's host/session");return end
		local found=false
		for _,pane in ipairs(tern.pane.list()) do
			if pane.pane==controller and pane.program=="orchplus.orchestrator" then found=true end
		end
		if not found then callback(nil,"Controller source is not the admitted ORCH+ controller block");return end
		local binding,err=Authority.binding(session)
		if not binding then callback(nil,err);return end
		state.origin_session=session;state.binding=binding
		callback(binding,nil,session)
	end)
end
-- Bridge lease (SPAWN_BRIDGE v1): lifecycle evidence the ORCH+ window reads before it reuses or
-- closes this pane, never authority. held: the registry names this pane in a requested window
-- authorization (or is unreadable); live: an execution projection is current; busy: a membership
-- verification is in flight; owner: the controller/window of the current request, else creator.
local LEASE_PREFIX="SPAWN_BRIDGE v1 "
local function bridge_creator(value)
	local text=function(v)return Protocol.text(v,256,false)end
	if not Protocol.fields(value,{schema=function(v)return v==1 end,controller_pane=function(v)return type(v)=="string" and #v<=32 and v:match("^%d+$")~=nil end,
		alias_nonce=text,window_key=function(v)return Protocol.text(v,256,true)end,window_epoch=Protocol.id}) then return nil end
	return {controller_pane=value.controller_pane,alias_nonce=value.alias_nonce,window_key=value.window_key,window_epoch=value.window_epoch}
end
local function lease_owner(state)
	local r=state.request
	if r then
		local b=r.origin_binding
		return {controller_pane=r.controller_pane,alias_nonce=b.alias_nonce,window_key=b.window_key,window_epoch=b.window_epoch}
	end
	return state.creator
end
-- The one human-visible line; machine nodes are hidden by dispatch.css but stay in the surface.
local function bridge_line(state,held,live)
	local body=state.body
	local what=if body then tostring(body.op or "request").." "..tostring(body.status or "answered") elseif state.error then "last request refused" else "idle"
	local note=if live then "executing an authorized ORCH+ effect"
		elseif held then "holding a requested window authorization"
		elseif state.restored then "restored view; reconcile through ORCH+, grants nothing"
		elseif body and type(body.error)=="table" and Protocol.id(body.error.code) then body.error.code
		elseif not body and not state.error then "awaiting ORCH+ requests"
		else nil
	return ("SPAWN bridge - "..what..(if note then " - "..note else "")):sub(1,160)
end
local function response_view(state,cx)
	local body=state.body
	local line=if body then Protocol.encode(body) else nil
	if not line and body and body.origin_binding then
		line=Protocol.encode(Protocol.reject(body,"oversize","Encoded bridge response exceeds 8192 bytes; no truncated response is valid"))
	end
	local node=ui.text(line or state.error or "SPAWN dispatch is awaiting a bounded request.")
	node.p=node.p or {};node.p.key=Protocol.NODE;node.p.role=Protocol.ROLE
	local execution,held=Dispatch.bridge_lease(state.request,cx.pane)
	local children={ui.text(ui.span(bridge_line(state,held,execution~=nil),"muted")),node}
	if execution then
		local bytes="SPAWN_EXECUTION v1 "..tern.json.encode(execution)
		if #bytes<=65536 then
			local private=ui.text(bytes);private.p=private.p or {};private.p.key="spawn-dispatch-execution";private.p.role="spawn.dispatch.execution"
			table.insert(children,private)
		end
	end
	local lease=tern.json.encode({schema=1,held=held,live=execution~=nil,busy=state.inspect_busy==true,owner=lease_owner(state)})
	if #lease>2048 then lease=tern.json.encode({schema=1,held=true,live=true,busy=true}) end
	local marker=ui.text(LEASE_PREFIX..lease);marker.p=marker.p or {};marker.p.key="spawn-dispatch-lease";marker.p.role="spawn.dispatch.lease"
	table.insert(children,marker)
	return {main=ui.col(children)}
end
tern.block.define("dispatch",{
	font="sans",
	init=function(_cx,args,saved)
		local state={}
		if type(saved)=="table" then
			if type(saved.request_json)=="string" then state.request=Protocol.decode(saved.request_json) end
			if type(saved.origin_session)=="number" then state.origin_session=saved.origin_session end
			state.creator=bridge_creator(saved.creator)
		end
		-- The creating ORCH+ window names itself (lease display only, never identity or authority).
		if not state.creator and type(args)=="table" and type(args[1])=="string" and #args[1]<=2048 then
			local ok,value=pcall(tern.json.decode,args[1])
			if ok then state.creator=bridge_creator(value) end
		end
		if state.request then
			-- A saved block is a view cursor, never execution authority.
			state.restored=true
			state.body=Protocol.body(state.request,"uncertain",nil,{code="target_unavailable",message="Reconcile this request through status; saved block state grants no execution"})
		end
		return state
	end,
	view=function(state,cx)return response_view(state,cx)end,
	event=function(state,event,cx)
		if event.ev~="action" then return end
		if event.act=="import_config" then
			local migration,why=Dispatch.import_decode(event.value,false)
			if not migration then state.error=why;return end
			bridge_membership(state,cx,function(session,err)
				if not session then state.error=err;return end
				local binding,bind_error=Authority.binding(session)
				if not binding or binding.host_key~=migration.target_host then state.error=bind_error or "Migration target host differs";return end
				state.body=Dispatch.import_config(migration);cx:render()
			end);return
		end
		if event.act=="spawn.authorize" then
			local value=Codec.strict_decode(event.value,65536)
			if not Protocol.fields(value,{request_json=true,nonce=Protocol.id,executor_id=Protocol.id,orch_claim=true}) or type(value.request_json)~="string" then return end
			local r=Protocol.decode(value.request_json);if not r then return end
			-- Membership was verified before issuing this challenge. The SPAWN
			-- window inspected the exact live grant after that async boundary.
			-- Do not add another asynchronous gap before consuming the nonce.
			state.request=r;state.restored=nil
			state.body=Dispatch.authorize(r,value.nonce,cx.pane,function(body)
				if state.request and Protocol.equal(state.request,r) then state.body=body;cx:render() end
			end,value.orch_claim,value.executor_id)
			cx:save();cx:render();return
		end
		if event.act=="spawn.claim" or event.act=="spawn.begin" or event.act=="spawn.result" or event.act=="spawn.wakeclaim" or event.act=="spawn.wakebegin" or event.act=="spawn.wakeresult" or event.act=="spawn.wakedefer" then
			local value=Codec.strict_decode(event.value,65536)
			if not Protocol.fields(value,{request_json=true,executor_id=Protocol.id},{result=true,orch_claim=true}) or type(value.request_json)~="string" then return end
			local r=Protocol.decode(value.request_json)
			if not r or (r.op~="launch" and r.op~="adopt" and r.op~="stop" and r.op~="native_wake") then return end
			dispatch_verify(state,cx,r,function(binding,why)
				if not binding then state.body=Protocol.reject(r,"binding_mismatch",why);return end
				state.request=r;state.restored=nil
				state.body=if r.op=="launch" or r.op=="adopt" then Dispatch.claim(r,value.executor_id,event.act:sub(7),value.result) elseif r.op=="stop" then Dispatch.stop_claim(r,value.executor_id,event.act:sub(7),value.result) else Dispatch.wake_claim(r,value.executor_id,event.act:sub(7),value.result,value.orch_claim)
				cx:save();cx:render()
			end);return
		end
		local r,why=Protocol.decode(event.value)
		if not r or event.act~=r.op then state.error=if why then why.message else "Operation differs from request";return end
		dispatch_verify(state,cx,r,function(binding,err,session)
			if not binding then state.body=Protocol.reject(r,"binding_mismatch",err);return end
			state.request=r;state.restored=nil
			if r.op=="catalog" or r.op=="status" or r.op=="owner_status" then
				state.body=Dispatch.request(r,binding,session,function()end)
			else
				state.body=Dispatch.stage(r,binding,session,cx.pane)
			end
			cx:save();cx:render()
		end)
	end,
	save=function(state)return {request_json=if state.request then tern.json.encode(state.request) else nil,origin_session=state.origin_session,creator=state.creator}end,
})
