-- The execution host is the only durable writer. Config is saved records only.
local ui = tern.ui
local Config = require("./config")
local Authority = require("./authority")
local Review = require("./setup_review")
local Native = require("./native_cli")
local Executor = require("./host_executor")
local Dispatch = require("./dispatch")
local DispatchState = require("./dispatch_state")
local ManagedSetup = require("./managed_setup")
local Prereq = require("./prereq")
local PageNavigation = require("./page_navigation")
local WindowJournal = require("./window_journal")
local SetupDiscovery = require("./setup_discovery")
-- The status-bar prompt claim is serialised on this single host thread (see status/status_prompt.luau).
require("./status/status_prompt").host_serve()
local observer_namespace, observer_migration_error = WindowJournal.host_initialize(function()
	return string.format("observer-%d-%08x-%08x-%08x", os.time(), math.random(1,2147483647), math.random(1,2147483647), math.random(1,2147483647))
end)
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
local function decode(value,limit)
	limit=limit or MAX_TEXT
	if type(value)~="string" or #value>limit then return nil,"JSON exceeds "..tostring(limit).." bytes" end
	local ok,result=pcall(tern.json.decode,value)
	return if ok then result else nil,if ok then nil else tostring(result)
end
local function inspect(window,callback,timeout_ms)
	local ok,err=pcall(Native.inspect,window,{timeout_ms=math.max(1,math.floor(timeout_ms or INSPECTION_DEADLINE_MS))},function(result,inspection_error)
		if inspection_error then callback(nil,inspection_error);return end
		if result.status~=0 or result.timed_out or #result.stdout>2000000 then callback(nil,"Host session inspection unavailable or over limit");return end
		local decoded,value=pcall(tern.json.decode,result.stdout)
		if not decoded or type(value)~="table" or type(value.sessions)~="table" then callback(nil,"Invalid host session inventory");return end
		callback(value,nil,result)
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
-- A remote client's window key names a window of the CLIENT's daemon, which this host
-- daemon never lists (it knows the client as "" or as its own key). The captured key is
-- a routing hint only: it is echoed back to the client and never handed to this host's
-- `tern inspect --window`. For a remote execution host, find the host daemon's own window
-- by the Config pane's membership in the keys this daemon lists (as bridge_membership does).
local function remote_host(state)
	return type(state.host)=="table" and state.host.kind=="remote"
end
local function resolve_host_window(state,pane,inspect_step,done)
	if not remote_host(state) then state.host_window=nil;done(state.native_window,nil);return end
	inspect_step(nil,function(initial,err)
		if not initial then done(nil,err);return end
		if type(initial.clients)~="table" then done(nil,"Host client inventory is unavailable");return end
		local keys,seen={},{}
		for _,client in ipairs(initial.clients) do
			if (client.kind=="window" or client.kind=="remote") and type(client.window)=="string" and #client.window<=256 and not client.window:find("%c") and not seen[client.window] then
				seen[client.window]=true;table.insert(keys,client.window)
			end
		end
		if #keys==0 or #keys>MAX_WINDOWS then done(nil,"Visible host windows are missing or exceed the 16-window inspection limit");return end
		local owner,session,index=nil,nil,0
		local function scan()
			index+=1
			if index>#keys then
				if owner==nil then done(nil,"Config pane is not visible in any host window; keep it visible in its original session");return end
				state.host_window=owner;done(owner,nil);return
			end
			inspect_step(keys[index],function(inventory,why)
				if not inventory then done(nil,why);return end
				local found=pane_sessions(inventory,pane)
				if not found then done(nil,"Corrupt native session identity");return end
				for _,id in pairs(found) do
					if session~=nil and session~=id then done(nil,"Config pane membership is ambiguous across host windows");return end
					session=id;owner=owner or keys[index]
				end
				scan()
			end)
		end
		scan()
	end)
end
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
	local function finish(session,err,inventory,native_result)
		if state.closed then state.inspect_busy=false;state.inspect_queue={};return end
		if session and tern.now()>deadline then session=nil;err="Host membership inspection deadline elapsed; this action was not processed" end
		if session and state.origin_session~=nil and session~=state.origin_session then session=nil;err="Authority moved from its original session. Reopen Config in the intended session; no state was rebound." end
		state.scope_error=err
		if session then
			state.inventory=inventory;state.default_cwd=nil
			for _,pane in ipairs(tern.pane.list()) do
				if pane.pane==cx.pane then state.default_cwd=pane.cwd;break end
			end
		end
		local ok,why=pcall(callback,session,err)
		if not ok then state.transport_error="Host authority callback failed: "..tostring(why);state.notice=state.transport_error end
		if session then auto_forget(state,cx,native_result,deadline) end
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
		inspect_step(window,function(final,why,native_result)
			if not final then finish(nil,why);return end
			local current=pane_sessions(final,cx.pane)
			local n=0;if current then for _ in pairs(current) do n+=1 end end
			if not current or n~=1 or current[tostring(native)]~=native then finish(nil,"Host membership changed during inspection; review and refresh");return end
			finish(native,nil,final,native_result)
		end)
	end)
	end
	resolve_host_window(state,cx.pane,inspect_step,function(resolved,why)
		if resolved==nil then finish(nil,why);return end
		window=resolved
		read_membership()
	end)
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
local function setup_client(inventory,window)
	local found=nil
	for _,client in ipairs(if inventory then inventory.clients or {} else {}) do
		if (client.kind=="window" or client.kind=="remote") and client.window==window then
			if found or type(client.conn)~="number" or client.conn<0 or client.conn%1~=0 or type(client.since)~="number" or client.since<0 or client.since%1~=0 then return nil end
			found=client
		end
	end
	return found
end
local function reload(state)
	if not state.binding then return false end
	local snapshot,err=Authority.snapshot(state.binding,Executor.epoch())
	if not snapshot then state.notice=err;state.transport_error=err;state.reload_error=err;state.snapshot=nil;return false end
	if state.transport_error==state.reload_error then state.transport_error=nil end
	state.reload_error=nil;state.snapshot=snapshot;state.config={schema=2,agents=snapshot.records}
	for _,job in ipairs(snapshot.jobs or {}) do
		if job.setup_consumed then
			if state.import_review and state.import_review.attempt_id==job.attempt_id then state.import_review=nil end
			if state.setup_result_attempt==job.attempt_id then state.setup_result_attempt=nil end
			-- The result is consumed: the retained "received" lead is no longer true.
			if state.notice==SETUP_RESULT_NOTICE then state.notice=nil end
		end
	end
	if state.choose_start_page then
		state.page="setup"
		for _,record in ipairs(snapshot.records) do
			if not record.review_required and type(record.command)=="string" and record.command:find("%S") and (record.backend~="native-agent" or type(record.prompt)=="string" and record.prompt:find("%S")) then state.page="spawn";break end
		end
		state.choose_start_page=nil
	end
	local obligation,probe_error=Authority.setup_probe_read(state.host_key)
	if probe_error then state.reload_error=probe_error;state.notice=probe_error;return false end
	if obligation and (not state.managed_route or state.managed_route.nonce~=obligation.nonce) then
		obligation.cleanup_only=true;state.managed_route=obligation
	end
	if state.managed_route then
		local route=state.managed_route;route.cleanup_pending=obligation~=nil;route.owned_pane=nil;route.discovery_complete=nil;route.cleanup_blocked=nil
		route.bound_pane=if obligation then obligation.pane else nil
		route.bound_window_pane=if obligation then obligation.window_pane else nil
		if obligation and (route.authority_id~=state.binding.authority_id or route.config_revision~=snapshot.config_revision) then
			route.cleanup_only=true;route.status="failed";route.error="Setup configuration or authority changed; only native cleanup is permitted"
		end
		if obligation and route.window==state.native_window and state.inventory then
			-- Desktop incarnation is bound by the directed consent response, not
			-- by a window key shared by several remote connections.
			local incarnation_ok=type(route.native_namespace)=="string" and type(route.window_consent)=="string" and (not route.origin_epoch or route.origin_epoch==Executor.epoch())
			local matches=0;local found=nil;local scoped=false
			for _,session in ipairs(state.inventory.sessions) do
				if session.id==route.native_session then scoped=true end
				for _,tab in ipairs(session.tabs or {}) do for _,block in ipairs(tab.blocks or {}) do
					if block.command==route.command then
						matches+=1
						if session.id==route.native_session and block.cwd==route.cwd then found=block.id end
					end
				end end
			end
			if incarnation_ok and scoped and matches==0 and obligation.pane~=nil then route.discovery_complete=true
			elseif incarnation_ok and scoped and matches==1 and found then
				local bound,why=Authority.setup_probe_bind(state.host_key,route.nonce,found)
				if bound then route.owned_pane=found;route.pane=found;route.bound_pane=found;route.discovery_complete=true else route.error=why end
			elseif matches>0 then route.error="Native diagnostic command/cwd/scope is ambiguous; cleanup remains pending"
			elseif incarnation_ok and scoped and obligation.pane==nil then route.error="No positive native pane evidence for this diagnostic; an uncertain start remains held" end
			if not incarnation_ok then
				route.discovery_complete=nil;route.owned_pane=nil;route.cleanup_blocked=true;route.status="failed";route.error="Native client/host incarnation changed or is unreadable; cleanup remains pending"
			end
		end
	end
	return true
end
-- Config membership is window-scoped; it is never global absence evidence.
-- One bounded HOST scan unions every native window twice, with stable client
-- incarnations, then applies only unchanged pre-scan candidates.
local forget_busy=false
local function cleanup_windows(result)
	local windows,why,inventory=WindowJournal.client_inventory(result)
	if not windows then return nil,why end
	local count=0
	for _ in pairs(windows) do count+=1 end
	if count==0 or count>MAX_WINDOWS then return nil,"Native window inventory is empty or exceeds the cleanup bound" end
	for _,client in ipairs(inventory.clients) do
		if client.kind~="window" and client.kind~="cli" then return nil,"An unqualified native client view may own saved sessions" end
	end
	return windows,nil
end
local function same_windows(before,after)
	if not after then return false end
	for key,value in pairs(before) do
		local current=after[key]
		if not current or current.conn~=value.conn or current.since~=value.since then return false end
	end
	for key in pairs(after) do if not before[key] then return false end end
	return true
end
auto_forget=function(state,cx,native_result,deadline)
	local local_live=live_sessions(state)
	if forget_busy or not state.binding or not local_live then return end
	local binding=state.binding
	local ok,preview,why,captured=pcall(Authority.forget_sessions,binding,local_live,false)
	if not ok or not preview then state.forget_hold=tostring(if ok then why else preview);return end
	if preview.sessions==0 then state.forget=preview;state.forget_hold=nil;return end
	local windows,problem=cleanup_windows(native_result)
	if not windows or not windows[state.host_window or state.native_window] then
		state.forget_hold=problem or "The owning native window incarnation is unavailable";return
	end
	local order={}
	for window in pairs(windows) do table.insert(order,window) end
	table.sort(order)
	forget_busy=true
	local function finish(result,err)
		forget_busy=false
		if state.closed or state.binding~=binding then return end
		state.forget_hold=err
		if result then state.forget=result;if result.sessions>0 then reload(state) end end
		cx:save();cx:render()
	end
	local round,index=1,1
	local prior,live=nil,{}
	local step
	step=function()
		if state.closed or state.binding~=binding then finish(nil,"Config ownership changed during session cleanup");return end
		local remaining=deadline-tern.now()
		if remaining<=0 then finish(nil,"Complete session inspection exceeded its existing deadline");return end
		local window=order[index]
		inspect(window,function(inventory,err,result)
			if not inventory then finish(nil,err);return end
			local current,roster_error=cleanup_windows(result)
			if not same_windows(windows,current) then finish(nil,roster_error or "Native window incarnations changed during session cleanup");return end
			local count=0
			for key,session in pairs(inventory.sessions) do
				count+=1
				if type(key)~="number" or key%1~=0 or key<1 or key>#inventory.sessions
					or type(session)~="table" or type(session.id)~="number" or session.id%1~=0
					or session.id<0 or session.id>9007199254740991 then
					finish(nil,"Native session inventory is incomplete or invalid");return
				end
				live[session.id]=true
			end
			if count~=#inventory.sessions then finish(nil,"Native session inventory is incomplete or invalid");return end
			index+=1
			if index<=#order then step();return end
			if round==1 then prior=live;live={};round=2;index=1;step();return end
			for id in pairs(prior) do if not live[id] then finish(nil,"Native session membership changed during cleanup");return end end
			for id in pairs(live) do if not prior[id] then finish(nil,"Native session membership changed during cleanup");return end end
			if not live[binding.native_session] then finish(nil,"The owning native session is no longer observed");return end
			if state.closed or state.binding~=binding or tern.now()>deadline then finish(nil,"Session cleanup authority or deadline changed");return end
			local applied,summary,failure=pcall(Authority.forget_sessions,binding,live,true,captured)
			if not applied or not summary then finish(nil,tostring(if applied then failure else summary));return end
			finish(summary,nil)
		end,remaining)
	end
	step()
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
-- Ordinary attempts settle themselves: the host diffs its own panes against
-- every binding on load, every SWEEP_MS and after each observation. It never
-- needs an open Config block and never closes or kills anything.
local SWEEP_MS=15000
local sweep_queued=false
local function refresh_blocks(binding,err)
	for _,block in pairs(live_blocks) do
		local state,cx=block.state,block.cx
		if state.binding and (binding==nil or state.binding.session_key==binding.session_key) then
			reload(state)
			if err then state.notice=err end
			cx:render()
		end
	end
end
local function sweep()
	sweep_queued=false
	local bindings=Authority.execution_bindings()
	local ok,list=pcall(tern.pane.list)
	if not bindings or not ok or type(list)~="table" then return end
	local panes={}
	for _,info in ipairs(list) do if type(info.pane)=="number" and info.pane%1==0 then panes[info.pane]={title=info.title} end end
	local epoch,now=Executor.epoch(),os.time()
	for _,binding in ipairs(bindings) do
		local changed,err=Authority.sweep(binding,panes,epoch,now)
		if err or (changed and changed>0) then refresh_blocks(binding,err) end
	end
end
local function queue_sweep()
	if sweep_queued then return end
	sweep_queued=true;tern.timer(1,sweep)
end
local function periodic_sweep()
	sweep();tern.timer(SWEEP_MS,periodic_sweep)
end
Executor.install(Authority,function(binding,err)
	refresh_blocks(binding,err)
	queue_sweep()
end)
tern.timer(1,periodic_sweep)
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
local ProviderIcons=require("./provider_icons")
local function action(state,name) return name.."@"..tostring(if state.snapshot then state.snapshot.config_revision else -1) end
local function switch_row(id,label,on,hint) return {id=id,label=label,hint=hint,control={k="switch",on=on}} end
local function text_row(id,label,value,hint,disabled) return {id=id,label=label,hint=hint,disabled=disabled,control={k="text",value=value,mono=true}} end
local function choice_row(id,label,value,options,hint) return {id=id,label=label,hint=hint,control={k="choice",value=value,options=options,style="menu"}} end
local function action_row(id,label,act,hint) return {id=id,label=label,hint=hint,control={k="action",act=act,label=label}} end
local function static_row(id,label,value,hint)
	return {id=id,label=label,hint=value.."\n"..hint,disabled="Read-only observation",control={k="action",act="noop",label="Read only"}}
end
-- A child row sits beneath its heading section and carries indent=1 for the native list.
local function child(row)
	row.indent=1
	return row
end
local managed_candidates,native_check_scope
-- Preparation counts only while it still matches the record's launch/account contract.
-- Editing a contract field of a prepared record invalidates it (see update_record); a
-- saved OS account that no longer matches the verified worker identity is stale too.
local CONTRACT_FIELDS={provider=true,backend=true,command=true,arguments=true,cwd=true,host=true,user=true,key_path=true,prompt=true}
local function preparation_current(record)
	local mailbox=record.mailbox
	if type(mailbox)~="table" or mailbox.verified~=true then return false end
	if type(record.user)=="string" and record.user~="" and record.backend~="ssh-command" and record.user~=mailbox.worker_identity then return false end
	return true
end
local function unprepared_ids(state)
	local ids={}
	for _,record in ipairs(state.config.agents) do
		if record.enabled and not preparation_current(record) then table.insert(ids,record.id) end
	end
	return ids
end
local SETUP_RESULT_NOTICE="Setup result received. SPAWN saves, prepares and verifies the approved agents automatically."
local GUIDED_HELP="Guided setup opens a helper beside SPAWN that finds your agents and asks you to approve the exact roster once. SPAWN then saves, prepares and verifies them automatically; there is no second approval. Choose the devices below, then start."
local function readable_fields(rows,prefix,label,value)
	if type(value)~="table" then
		table.insert(rows,static_row(prefix,label,tostring(value),"Retained observation; not permission to launch."))
		return
	end
	local keys={};for key in pairs(value) do table.insert(keys,key) end
	table.sort(keys,function(a,b)if type(a)=="number" and type(b)=="number" then return a<b end;return tostring(a)<tostring(b) end)
	if #keys==0 then table.insert(rows,static_row(prefix,label,"None","No retained entries.")) end
	for _,key in ipairs(keys) do
		if key=="initial_prompt" and type(value[key])=="string" then
			table.insert(rows,static_row(prefix.."-"..key,label.." · Initial prompt",tostring(#value[key]).." bytes","Open Advanced for raw prompt diagnostics; the original bytes remain in the machine channel."))
		else readable_fields(rows,prefix.."-"..tostring(key),label.." · "..tostring(key),value[key]) end
	end
end
local function review_rows(rows,prefix,records,hint)
	local review,why=Review.prepare({schema=2,setup_run_id="config-display",confirmed=true,agents=records},"config-display")
	if not review then table.insert(rows,static_row(prefix,"Record review unavailable",tostring(why),"Preserved source was not changed."));return end
	for _,record in ipairs(review.rows) do
		for index,field in ipairs(record.fields) do
			table.insert(rows,static_row(prefix.."-"..record.id.."-"..tostring(index),record.label.." · "..field.label,field.value,hint))
		end
	end
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
					review_rows(rows,"source-"..id.."-"..tostring(index),{record},"Source: "..source.label..". Preserved candidate; choose one source below.")
				end
			end
		end
		table.insert(rows,choice_row("review:"..id..":"..tostring(state.snapshot.config_revision),id.." · source",if review.choices[id]~=nil then tostring(review.choices[id]) else "",options,"Every record needs an explicit choice. Originals remain preserved."))
	end
	table.insert(rows,action_row("review-confirm","Confirm selected migration",action(state,"review-confirm"),review.reason))
	return {{id="migration",page=state.page,title="Review saved sources",rows=rows}}
end
-- An active setup run is a setup helper attempt that has not ended.
local function setup_active(state)
	local consumed={}
	for _,job in ipairs(state.snapshot.jobs or {}) do if job.setup_consumed then consumed[job.attempt_id]=true end end
	for _,a in ipairs(state.snapshot.attempts) do
		if a.purpose=="setup" and not consumed[a.id] and a.phase~="Exited" and a.phase~="Failed" then return true end
	end
	for _,job in ipairs(state.snapshot.jobs or {}) do if job.setup and job.pending_bytes and job.pending_bytes>0 and not job.setup_consumed then return true end end
	return false
end
local function setup_job(state,cx,id)
	for _,job in ipairs(if state.snapshot then state.snapshot.jobs or {} else {}) do
		if job.attempt_id==id and job.setup and job.setup.window==state.native_window and job.setup.host_config_pane==cx.pane then return job end
	end
	return nil
end
local function prepare_manual_review(state,revision)
	state.import_review=nil
	local payload,err=Config.decode_setup_json(state.import_text)
	if not payload or type(payload)~="table" or payload.schema~=2 or type(payload.agents)~="table" then state.notice=err or "Expected current-schema {schema:2,agents:[...]} JSON";return end
	for key in pairs(payload) do if key~="schema" and key~="agents" and key~="setup_run_id" and key~="confirmed" and key~="paid_checks" then state.notice="Unexpected setup JSON field: "..tostring(key);return end end
	if payload.setup_run_id~=nil or payload.confirmed~=nil then
		if type(payload.setup_run_id)~="string" or #payload.setup_run_id==0 or #payload.setup_run_id>256 or payload.setup_run_id:find("%c") or payload.confirmed~=true then state.notice="Guided setup recovery requires a valid setup_run_id and confirmed:true; otherwise paste a manual schema/agents object";return end
	end
	local records,why=Config.validate_records(payload.agents);if not records then state.notice=why;return end
	state.import_review={records=records,revision=revision,run=payload.setup_run_id,bytes=state.import_text}
	state.notice="Validated every record. Review the exact settings on the original host/session, then Import reviewed records. Manual recovery does not prove original automatic-source provenance."
end
local function setup_sections(state)
	local topology=state.setup_topology or {mode="single"}
	local busy=setup_active(state)
	local queued=false
	for _,intent in ipairs(state.intents or {}) do if intent.kind=="setup" then queued=true;break end end
	local guided={
		child(choice_row("setup-device-mode","Single or Multi Device Setup?",topology.mode,{{value="single",label="Single device (default)"},{value="multi",label="Multi device"}},"Agents run on the primary execution machine. A Tern desktop attached through SSH is not another agent SSH hop.")),
	}
	local find=child(action_row("setup-find-devices","Find execution machine(s)",action(state,"setup-find-devices"),"Read the devices already known to this Tern window. No connection, account or key is created."))
	if topology.mode~="multi" then find.disabled="Single device uses this execution machine. Choose Multi device to find others."
	elseif topology.request then find.disabled="Discovery is running." end
	table.insert(guided,find)
	if topology.observation then
		local options={}
		for _,device in ipairs(topology.observation.devices) do table.insert(options,{value=tostring(device.id),label=device.name..(if device.id==topology.observation.current then " — current execution machine" else "")..(if device.state~="connected" then " — "..device.state else "")}) end
		table.insert(guided,child(choice_row("setup-primary","Which Device is the primary execution machine?",tostring(topology.selected),options,"Discovery and preparation will run there, under the selected existing account. Other machines keep their own saved agents; no cross-host federation is configured.")))
	end
	local launch=child(action_row("setup-start-helper","Start Guided setup — may use model credits",action(state,"setup-start-helper"),"Uses your current Tern default agent on the selected machine, on the left of SPAWN. It discovers commands and asks for your settings approval once; it does not start orchestration work."))
	if busy then launch.disabled="Finish the current Guided setup before starting another helper."
	elseif queued then launch.disabled="Guided setup is already queued."
	elseif topology.request then launch.disabled="Wait for the current discovery."
	elseif topology.mode=="multi" and not topology.observation then launch.disabled="Find execution machine(s) first, then choose the primary machine." end
	table.insert(guided,launch)
	if topology.error then table.insert(guided,static_row("setup-device-error","Execution machine","Setup required",topology.error)) end
	if busy then
		table.insert(guided,child(action_row("setup-result","Recover setup result",action(state,"launch-result"),"Recovery only: SPAWN normally saves the approved result by itself. This asks the SPAWN window that started the run to process it once; nothing is saved twice.")))
	end
	local rows={
		action_row("setup-add-local","Add agent on "..tostring(state.host and state.host.name or state.host_key or "this machine"),action(state,"add-local"),"Choose a provider and account, then review its launch settings."),
	}
	-- Preparation follows installation order: saved agents that ORCH+ still needs
	-- prepared get ONE action for the missing work; prepared agents are reused.
	if #state.config.agents>0 then
		local missing=unprepared_ids(state)
		if #missing>0 then
			-- The one action names exactly what a click may run, before the click.
			local candidates,blocked=managed_candidates(state,true,missing)
			local scopes={}
			if candidates then
				for _,candidate in ipairs(candidates) do
					if candidate.draft.backend=="native-agent" then table.insert(scopes,native_check_scope(candidate.draft)) end
				end
			end
			if not candidates then
				table.insert(rows,static_row("setup-managed","Prepare agents for ORCH+","Setup required",tostring(blocked)))
			else
				local label="Prepare agents for ORCH+"
				local hint=tostring(#missing).." saved agent(s) still need preparation. Already prepared agents are reused, not repeated."
				if #scopes>0 then
					label..=" — uses model credits"
					hint..=" Paid native checks, one harmless model message each: "..table.concat(scopes," | ").." May cost model credits; not a sandbox. Other agents are checked offline."
				else
					hint..=" All checks are offline; no model is called."
				end
				local prepare=action_row("setup-managed",label,action(state,"managed-prepare-missing"),hint)
				if state.managed_busy or (state.managed_batch and state.managed_batch.status~="completed" and state.managed_batch.status~="failed") then prepare.disabled="Setup is already running." end
				table.insert(rows,prepare)
			end
		else
			table.insert(rows,text_row("setup-managed-state","Agents prepared for ORCH+","All saved agents are prepared","Preparation is current. Nothing more to click.","Already prepared"))
		end
	end
	if state.advanced then
		table.insert(rows,action_row("setup-managed-advanced","Inspect or re-prepare agents",action(state,"managed-open"),"Per-agent inspection and re-preparation, with machine-facing detail."))
	end
	for _,job in ipairs(state.snapshot.jobs or {}) do
		if job.setup and (state.advanced or not job.setup_consumed) then
			local status=if job.setup_discarded then "Discarded without saving" elseif job.setup_consumed then "Agents saved" elseif job.pending_bytes and job.pending_bytes>0 then "Ready to save your agents" else "Answer the setup questions"
			table.insert(rows,static_row("setup-submission-"..job.attempt_id,"Guided setup result",status,if state.advanced then "Run "..tostring(job.setup_run_id)..". Review the exact retained settings; saving does not launch agents." else "The helper holds your one approval. SPAWN saves, prepares and verifies the roster by itself; if that did not finish, choose Recover setup result."))
			if job.pending_bytes and job.pending_bytes>0 and not job.setup_consumed then
				table.insert(rows,action_row("discard-setup-"..job.attempt_id,"Discard this setup result",action(state,"discard-setup:"..job.attempt_id),"Opens an explicit native decision for this exact pending submission. Saved records, helper conversations, other results and history remain unchanged."))
			end
		end
	end
	if state.advanced then
		table.insert(rows,static_row("setup-host","Execution host",state.host_key or "Unknown","Settings belong to this host; labels do not isolate accounts."))
		table.insert(rows,action_row("setup-add-ssh","Add SSH record manually",action(state,"add-ssh"),"Review the SSH destination, command and account before launch."))
		table.insert(rows,action_row("setup-reset",if state.armed=="reset-roster" then "Confirm delete saved roster" else "Delete saved roster",action(state,"reset-roster"),"Two deliberate clicks; installations, logins and launch history are unchanged."))
		table.insert(rows,text_row("manual-json","Paste setup JSON",state.import_text,"Advanced manual recovery: use the original captured host and session. Pasted run IDs do not prove original automatic-source provenance; nothing starts."))
		table.insert(rows,action_row("bridge-import","Allow roster import","bridge-import-open","Paste the complete migration preview JSON above. Opens an exact one-use host gate; no import or launch."))
		table.insert(rows,action_row("bridge-import-cancel","Cancel pending roster import","bridge-import-cancel","Invalidates this panel's unconsumed migration gate."))
		table.insert(rows,static_row("bridge-import-gate","Migration gate",state.bridge_import_gate or "Closed","Only an explicit owner action opens this gate. Runtime reload invalidates an unused gate."))
		table.insert(rows,action_row("manual-review","Review pasted JSON",action(state,"manual-review"),"Validate every record, argument and existing ID before confirmation."))
		for _,job in ipairs(state.snapshot.jobs or {}) do
			if job.setup and job.pending_bytes and job.pending_bytes>0 and not job.setup_consumed then
				table.insert(rows,action_row("manual-recover-"..job.attempt_id,"Recover retained setup "..tostring(job.setup_run_id),action(state,"manual-recover:"..job.attempt_id),"Review immutable accepted bytes from this original host/session, even if the original conversation or Config pane has closed. No file reread. Manual recovery does not prove original automatic-source provenance."))
			end
		end
	end
	local preview,records=DispatchState.import_decode(state.import_text,true)
	if preview and state.advanced then
		table.insert(rows,static_row("bridge-import-source","Migration source",preview.source_client,"Source revision "..tostring(preview.source_revision).." · SHA256 "..preview.source_sha256))
		table.insert(rows,static_row("bridge-import-target","Migration target",preview.target_host,"Must match this Config host before the one-use gate can open."))
		review_rows(rows,"bridge-import-record",records,"Non-secret configuration snapshot; divergent existing IDs remain a conflict.")
	end
	if state.import_review and state.advanced then
		review_rows(rows,"import",state.import_review.records,"Review the exact settings; conflicting IDs are never renamed or overwritten.")
		table.insert(rows,action_row("manual-confirm","Import reviewed records", "manual-confirm@"..tostring(state.import_review.revision),"Manual recovery does not prove original automatic-source provenance. Imports only; never launches."))
	end
	return {
		{id="setup-guided",page="setup",title="Guided setup",hint=GUIDED_HELP,rows=guided},
		{id="setup-guide",page="setup",title="Agent setup",rows=rows},
	}
end
local MANAGED_FIELDS={id=true,provider=true,provider_family=true,account_label=true,backend=true,executable=true,arguments=true,task_argument_index=true,cwd=true,root=true,user=true}
local function managed_draft(state)
	if not state.managed_draft then
		state.managed_draft=ManagedSetup.defaults(state.default_cwd);state.managed_draft_revision=state.snapshot.config_revision
		local index=1
		while record_by_id(state,state.managed_draft.id) do index+=1;state.managed_draft.id="managed-local-"..tostring(index) end
	end
	return state.managed_draft
end
local function managed_change(state,field,value)
	if not MANAGED_FIELDS[field] or type(value)~="string" or #value>32000 or value:find("%z") then return end
	if state.managed_batch and state.managed_batch.status~="completed" and state.managed_batch.status~="failed" then state.notice="Wait for the current setup before editing its approved settings.";return end
	managed_draft(state)
	if state.managed_draft_revision~=state.snapshot.config_revision then state.notice="stale-config: reselect the current record (or Create a new managed record) before editing this draft";return end
	state.managed_draft_touched=true
	managed_draft(state)[field]=value;state.managed_probe=nil;state.managed_record=nil;state.managed_route=nil;state.editing=nil
end
local function managed_native_select(state,value)
	if state.managed_draft_revision~=state.snapshot.config_revision then state.notice="stale-config: reselect the current saved Agent before adopting a native route";return end
	local selected=tonumber(value);local route=if selected then (state.managed_native_choices or {})[selected] else nil
	if not route then return end
	local draft,why=ManagedSetup.from_native(route.command,state.default_cwd)
	if not draft then state.notice=why;return end
	local matching=nil
	for _,record in ipairs(state.config.agents) do
		local existing=ManagedSetup.from_record(record,state.default_cwd)
		if not existing.preparation_error and record.backend==draft.backend and existing.user==draft.user and existing.executable==draft.executable and existing.arguments==draft.arguments then
			if matching then state.notice="Multiple saved records match this route; select the exact saved Agent instead";return end
			matching=record
		end
	end
	state.managed_existing=if matching then matching.id else nil
	state.managed_draft=if matching then ManagedSetup.from_record(matching,state.default_cwd) else draft
	if not matching then
		local index=1
		while record_by_id(state,state.managed_draft.id) do index+=1;state.managed_draft.id="managed-local-"..tostring(index) end
	end
	state.managed_native_selected=value;state.managed_draft_revision=state.snapshot.config_revision;state.managed_draft_touched=true
	state.managed_probe=nil;state.managed_record=nil;state.managed_route=nil;state.editing=nil
end
local PREPARE_WAIT_MS=180000
local managed_batch_next
local function managed_batch_fail(state,message)
	local batch=state.managed_batch
	if batch then batch.status="failed";batch.error=tostring(message);batch.consent=nil end
	state.managed_busy=nil
	state.notice="SPAWN Setup failed: "..tostring(message)..(if batch and #batch.saved>0 then ". Saved "..tostring(#batch.saved).." of "..tostring(#batch.entries).." agents; remaining agents are not confirmed ready." else "")..". Resolve this problem, then review setup before trying again."
end
local function managed_record_idle(state,id)
	return Authority.record_preparation_available(state.host_key,id)
end
function managed_candidates(state,all,selected)
	local candidates={}
	local function add(draft,existing)
		if draft.preparation_error then return nil,draft.account_label..": "..draft.preparation_error end
		if draft.source_record and not draft.source_record.enabled then return nil,"Enable "..draft.account_label.." in Agent settings before preparation. No resources or model check were started." end
		if draft.source_record and draft.source_record.review_required then return nil,"Review and approve the saved launch settings for "..draft.account_label.." in Agent settings before preparation." end
		local idle,why=managed_record_idle(state,draft.id);if not idle then return nil,why end
		if draft.backend=="ssh-command" then return nil,"The SSH destination for "..draft.account_label.." is not proven to be this machine. Open SPAWN on the intended Tern machine, then explicitly choose its local/native route and existing account. Hostname spelling, including localhost, is not proof." end
		if draft.backend~="local-terminal" and draft.backend~="native-agent" then return nil,"Choose an actual supported native or same-machine terminal route for "..draft.account_label end
		table.insert(candidates,{draft=draft,existing=existing})
		return true
	end
	if all and selected then
		local seen={}
		for _,id in ipairs(selected) do
			if type(id)~="string" or seen[id] then return nil,"The reviewed agent selection is invalid" end
			seen[id]=true
			local record=record_by_id(state,id)
			if not record or not record.enabled then return nil,"A reviewed enabled agent changed before preparation" end
			local ok,why=add(ManagedSetup.from_record(record,state.default_cwd),id);if not ok then return nil,why end
		end
	elseif all then
		for _,record in ipairs(state.config.agents) do
			if record.enabled then local ok,why=add(ManagedSetup.from_record(record,state.default_cwd),record.id);if not ok then return nil,why end end
		end
	else
		if state.managed_draft_revision~=state.snapshot.config_revision then return nil,"stale-config: Settings changed. Select the current agent before preparing it." end
		local draft=Authority.clone(managed_draft(state))
		if not state.managed_existing and record_by_id(state,draft.id) then return nil,"That saved agent already exists. Select it before preparing." end
		local ok,why=add(draft,state.managed_existing);if not ok then return nil,why end
	end
	if #candidates==0 then return nil,if all and #state.config.agents>0 then "No enabled agents are selected. Choose an agent and use Enable agent before preparation." else "Save at least one agent, or review a new agent's settings first." end
	return candidates
end
function native_check_scope(draft)
	local source=draft.source_record or {}
	return draft.provider.." — "..draft.account_label.." (model: "..tostring(source.model or "saved CLI settings/default")..(if source.profile then "; profile: "..source.profile else "").."; existing account: "..(if draft.user~="" then draft.user else "current OS account").."; arguments: "..(if draft.arguments~="" then draft.arguments else "none")..")"
end
local function managed_batch_offer(state,cx,expected,all,plan,missing)
	if state.managed_busy or (state.managed_batch and state.managed_batch.status~="failed" and state.managed_batch.status~="completed") then state.notice="Setup is already running; no second preparation was requested.";return end
	local pending,why=Authority.setup_probe_read(state.host_key)
	if pending or why then state.notice=why or "The previous diagnostic still needs positively observed cleanup. Nothing was repeated.";return end
	local candidates,problem=managed_candidates(state,all,if plan then plan.selected else missing)
	if not candidates then state.notice="SPAWN Setup failed: "..problem;return end
	local nonce=if plan then plan.nonce else string.format("prepare-%d-%08x-%08x",os.time(),math.random(1,2147483647),math.random(1,2147483647))
	local begin=state.snapshot.setup.state=="not_started" or state.snapshot.setup.state=="dismissed"
	local entries={}
	for index,candidate in ipairs(candidates) do
		table.insert(entries,{nonce=nonce.."-"..tostring(index),record_id=candidate.draft.id,label=candidate.draft.provider.." — "..candidate.draft.account_label,backend=candidate.draft.backend,revision=expected+(if begin then 1 else 0)+index-1})
	end
	if plan and not Dispatch.protocol.equal(entries,plan.entries) then state.notice="Saved agent identities or revisions differ from the exact reviewed preparation; no checks were started.";return end
	state.managed_batch={nonce=nonce,revision=expected,entries=entries,candidates=candidates,index=1,saved={},status="awaiting_consent",deadline=tern.now()+30000,expected_records=Authority.clone(state.config.agents),expected_revision=expected,binding=state.binding}
	state.managed_draft_touched=true
	local offered=state.managed_batch
	tern.timer(30000,function()
		if not state.closed and state.managed_batch==offered and offered.status=="awaiting_consent" then managed_batch_fail(state,"The clicked-window approval expired; nothing was launched");cx:render() end
	end)
	if plan then return end -- Consent was captured in the actual final native approval.
	-- Capture the real clicked window synchronously, before awaiting any resource IO.
	cx:render() -- Publish the exact offered nonce before opening its native handoff.
	local opened,open_error=pcall(function()cx:open("tern-spawn://managed-prepare/"..string.format("%.0f",cx.pane).."/"..tostring(expected).."/"..nonce)end)
	if not opened then managed_batch_fail(state,"Could not reach the window you clicked: "..tostring(open_error)) end
end
managed_batch_next=function(state,cx,batch)
	if state.closed or state.managed_batch~=batch then return end
	local entry=batch.entries[batch.index]
	if not entry then
		batch.status="completed";batch.consent=nil;state.managed_busy=nil
		state.notice="SPAWN SETUP SUCCESSFUL — saved and verified "..tostring(#batch.saved).." agents. Provider login and optional readiness were not checked."
		return
	end
	batch.status="preparing";batch.deadline=tern.now()+PREPARE_WAIT_MS;state.managed_busy=true
	tern.timer(PREPARE_WAIT_MS,function()
		if not state.closed and state.managed_batch==batch and batch.status=="preparing" and batch.entries[batch.index]==entry then managed_batch_fail(state,"Preparation timed out for "..entry.label.."; no diagnostic was launched");cx:render() end
	end)
	verify(state,cx,function(session,why)
		if state.managed_batch~=batch or batch.status~="preparing" then return end
		if not session or state.binding~=batch.binding or not reload(state) then managed_batch_fail(state,why or "The setup owner changed");return end
		if state.snapshot.config_revision~=batch.expected_revision or not Dispatch.protocol.equal(state.config.agents,batch.expected_records) then managed_batch_fail(state,"Saved agent settings changed during setup; remaining consent was cancelled");return end
		if not managed_record_idle(state,entry.record_id) then managed_batch_fail(state,entry.label.." started work while setup was pending. Settle that work before preparation.");return end
		local candidate=batch.candidates[batch.index]
		state.managed_existing=candidate.existing;state.managed_draft=Authority.clone(candidate.draft);state.managed_draft_revision=batch.expected_revision
		state.managed_probe=nil;state.managed_record=nil;state.managed_route=nil
		ManagedSetup.prepare(candidate.draft,{host_os=state.snapshot.host_os,host_shell=state.snapshot.host_shell},function(record,probe,problem)
			if state.closed or state.managed_batch~=batch or batch.status~="preparing" then return end
			if tern.now()>batch.deadline then managed_batch_fail(state,"Preparation timed out for "..entry.label.."; no diagnostic was launched");cx:render();return end
			if not record or not probe or not probe.passed then managed_batch_fail(state,entry.label..": "..tostring(problem or "Required resource checks failed"));cx:render();return end
			verify(state,cx,function(current,scope_error)
				if state.managed_batch~=batch or batch.status~="preparing" then return end
				if not current or state.binding~=batch.binding or not reload(state) then managed_batch_fail(state,scope_error or "The setup owner changed");return end
				if state.snapshot.config_revision~=batch.expected_revision or not Dispatch.protocol.equal(state.config.agents,batch.expected_records) or not Dispatch.protocol.equal(state.managed_draft,candidate.draft) then managed_batch_fail(state,"Agent settings changed while preparing "..entry.label);return end
				if not managed_record_idle(state,entry.record_id) then managed_batch_fail(state,entry.label.." has new active or uncertain work; no diagnostic was launched");return end
				if tern.now()>batch.deadline then managed_batch_fail(state,"Preparation approval expired for "..entry.label.."; no diagnostic was launched");return end
				if state.snapshot.setup.state=="not_started" or state.snapshot.setup.state=="dismissed" then
					local begun,begin_error=Authority.setup_edit(state.host_key,batch.expected_revision,"begin",{})
					if not begun or not reload(state) then managed_batch_fail(state,begin_error or "Could not begin setup");return end
					batch.expected_revision=state.snapshot.config_revision
				end
				if batch.expected_revision~=entry.revision then managed_batch_fail(state,"The approved diagnostic revision changed");return end
				local fits,budget_error=Authority.setup_capacity_available(state.host_key,entry.revision,record,probe)
				if not fits then managed_batch_fail(state,budget_error);return end
				state.managed_record=record;state.managed_probe=probe;state.managed_probe_revision=entry.revision;state.managed_draft_revision=entry.revision
				local route,route_error=ManagedSetup.route(record,probe,state.snapshot,entry.revision,state.native_window,entry.nonce)
				if not route then managed_batch_fail(state,route_error);return end
				local consent=batch.consent[batch.index]
				route.status="running";route.native_session=current;route.source_pane=cx.pane;route.authority_id=state.binding.authority_id;route.origin_epoch=Executor.epoch()
				route.native_namespace=batch.recipient.native_namespace;route.native_conn=batch.recipient.native_conn;route.native_since=batch.recipient.native_since;route.window_consent=consent.window_consent
				route.record_id=entry.record_id
				local claimed,claim_error=Authority.setup_probe_claim(state.host_key,entry.revision,route)
				if not claimed then managed_batch_fail(state,claim_error);return end
				route.cleanup_pending=true;state.managed_route=route;batch.status="verifying";state.managed_busy=nil
				state.notice="Preparing "..entry.label.." ("..tostring(batch.index).." of "..tostring(#batch.entries).."). Verification and saving follow automatically."
			end)
		end)
	end)
end
local function managed_sections(state)
	local draft=managed_draft(state)
	if (#state.config.agents==0 or state.managed_edit_one or state.advanced) and state.snapshot.host_os~="windows" and not state.managed_native_choices and not state.managed_native_request then state.managed_native_request={nonce=string.format("accounts-%d-%08x",os.time(),math.random(1,2147483647)),window=state.native_window} end
	local setup=state.snapshot.setup or {state="not_started",readiness={state="not_run",config_revision=0,summary=""}}
	local rows={
		static_row("managed-state","Setup",({not_started="Not prepared",in_progress="Preparing",completed="Saved",adopted_existing="Saved",dismissed="Dismissed"})[setup.state] or setup.state,"Helper access and native routing are verified automatically. Provider authentication, custom CLI semantics and readiness remain separate."),
	}
	local missing=unprepared_ids(state)
	local normal_view=not state.advanced and not state.managed_edit_one and #state.config.agents>0
	local candidates,blocked
	if normal_view and #missing==0 then
		-- Everything enabled is already prepared: show that state, no button.
		table.insert(rows,text_row("managed-all-prepared","Agents prepared for ORCH+","All saved agents are prepared","Preparation is current. Per-agent re-preparation is under Advanced.","Already prepared"))
	else
		candidates,blocked=managed_candidates(state,true,if normal_view then missing else nil)
	end
	if candidates then
		local names,native={},{}
		for _,candidate in ipairs(candidates) do
			local label=candidate.draft.provider.." — "..candidate.draft.account_label
			table.insert(names,label)
			if candidate.draft.backend=="native-agent" then table.insert(native,native_check_scope(candidate.draft)) end
		end
		local batch_action=action_row(if normal_view then "managed-prepare-missing" else "managed-prepare-all",if #native>0 then "Prepare saved agents — includes paid native checks" else "Prepare saved agents",action(state,if normal_view then "managed-prepare-missing" else "managed-prepare-all"),"Prepares, verifies, saves and refreshes "..tostring(#candidates).." enabled agents on this execution machine: "..table.concat(names,", ")..". Disabled agents stay unchanged. SSH destinations are never inferred or converted automatically. Terminal checks are offline."..(if #native>0 then " One model message each for: "..table.concat(native,", ")..". These checks may use credits, use the saved model and permissions, and are not sandboxes." else " No provider/model task is launched."))
		if state.managed_busy or (state.managed_batch and state.managed_batch.status~="completed" and state.managed_batch.status~="failed") then batch_action.disabled="Setup is already running." end
		table.insert(rows,batch_action)
	elseif blocked and #state.config.agents>0 then table.insert(rows,static_row("managed-batch-prerequisite","Prepare saved agents","Setup required",blocked)) end
	if #state.config.agents>0 and not state.managed_edit_one and not state.advanced then
		if state.notice then table.insert(rows,static_row("managed-notice","Setup status","Review",state.notice)) end
		table.insert(rows,action_row("managed-exercise","Check provider readiness…",action(state,"managed-exercise"),"Optional paid provider exercise, with separate consent. Required terminal setup above is offline."))
		return {{id="managed-setup",page="managed",title="Prepare agents for ORCH+",rows=rows}}
	end
	if state.snapshot.host_os=="macos" and draft.backend=="local-terminal" then
		local capability=state.terminal_capability
		table.insert(rows,static_row("terminal-capability","Automatic terminal continuation",if state.terminal_capability_busy then "Checking" elseif capability then (if capability.available then "Available" else "Setup required") else "Not checked",if capability then capability.summary else "This optional macOS capability uses an existing Python 3 interpreter, standard-library ctypes and native libproc. It does not gate ordinary launches or native OMP, and SPAWN never installs Python automatically."))
		local check=action_row("terminal-capability-check","Check terminal continuation capability",action(state,"terminal-capability-check"),"Observe the execution host's real Python/libproc capability. If missing, use your approved macOS Python 3 installer, then check again; no credentials or permissions are changed.")
		if state.terminal_capability_busy then check.disabled="Capability observation is already running" end
		table.insert(rows,check)
	end
	if state.notice then table.insert(rows,static_row("managed-notice","Setup status","Review",state.notice)) end
	local options={{value="",label="Create a new managed record"}}
	for _,record in ipairs(state.config.agents) do table.insert(options,{value=record.id,label=record.provider.." — "..record.account_label}) end
	table.insert(rows,choice_row("managed-existing","Agent",state.managed_existing or "",options,"Update this agent without replacing other saved accounts."))
	if draft.source_record and draft.source_record.backend=="ssh-command" then table.insert(rows,static_row("managed-local-conversion","Execution machine","Explicit route choice required","The old SSH destination is not verified as this machine, even if its name looks local. Only choose Local terminal or Native agent if this Tern execution machine is the intended target. Preparation checks the existing account here; it never reuses the SSH destination/key.")) end
	if draft.source_record and not draft.source_record.enabled then table.insert(rows,action_row("managed-enable-agent","Enable agent",action(state,"managed-enable:"..draft.source_record.id),"Explicitly enables this saved launch choice. Preparation has not started; other agent settings remain unchanged.")) end
	if draft.source_record and draft.source_record.review_required then table.insert(rows,action_row("managed-review-agent","Review agent settings",action(state,"managed-review:"..draft.source_record.id),"Review and approve its saved launch settings before resource or model checks.")) end
	if state.snapshot.host_os~="windows" then
		local native_options={{value="",label="Choose a discovered native route"}}
		for index,route in ipairs(state.managed_native_choices or {}) do table.insert(native_options,{value=tostring(index),label=route.label.." — "..route.command}) end
		table.insert(rows,choice_row("managed-native","Native account",state.managed_native_selected or "",native_options,"Actual Tern default and native agent routes on this execution host. Selecting a route never launches it; labels are not OS users. Existing matching SPAWN records keep their identity."))
		if state.managed_native_error then table.insert(rows,static_row("managed-native-error","Native discovery","Review",state.managed_native_error)) end
	end
	for _,field in ipairs(if state.advanced then {"id","provider","provider_family","account_label","executable","arguments","task_argument_index","cwd","root","user"} else {"provider","account_label","executable","cwd","user"}) do
		if field=="user" and state.snapshot.host_os=="windows" then continue end
		local labels={id="Stable record ID",provider="Provider",provider_family="Underlying AI provider",account_label="Account label",executable="Executable",arguments="Fresh launch arguments",task_argument_index="Task argument position",cwd="Working folder",root="Mailbox folder",user="Existing POSIX account"}
		local hints={provider_family="Configured underlying provider for OMP/wrappers; not runtime identity.",arguments="Literal argv. Configure explicit fresh-session flags. No shell command string.",task_argument_index="Terminal only: one-based insertion position; empty appends the task after fresh arguments. Native OMP uses its native prompt channel.",root="Current-user default is stable plugin data; selected-account default uses its verified home. Existing explicit roots are preserved; no permissions or Git trust are changed.",user="Empty uses the current account. An existing same-host account requires already-authorized noninteractive sudo access; its actual home and executable are observed before helper installation. No account, credentials or permissions are created.",executable=if state.snapshot.host_os=="windows" then "Choose an installed native .exe using Windows CRT arguments." else "Installed command name or absolute executable path."}
		table.insert(rows,text_row("managed:"..field,labels[field],text(draft[field]),hints[field]))
	end
	table.insert(rows,choice_row("managed:backend","Launch route",draft.backend,if state.snapshot.host_os=="windows" then {{value="local-terminal",label="Local terminal"}} else {{value="native-agent",label="Native agent"},{value="local-terminal",label="Local terminal"}},"Use this machine's configured native agent integration or a terminal; a provider label does not verify native recognition."))
	if state.advanced and (not state.managed_probe or not state.managed_probe.passed or (state.managed_route and state.managed_route.cleanup_pending==false)) then
		table.insert(rows,action_row("managed-probe","Check resources only",action(state,"managed-probe"),"Advanced resource diagnostic only. Use Prepare and save for the complete required setup."))
	end
	local paid=draft.backend=="native-agent"
	local prepare=action_row("managed-prepare","Prepare and save"..(if paid then " — uses model credits" else ""),action(state,"managed-prepare"),"Checks the existing account, command and folder; prepares helpers; verifies the route; saves and refreshes automatically. "..(if paid then "Sends one harmless native model message for "..native_check_scope(draft)..". May use credits; not a sandbox." else "Uses a temporary offline terminal diagnostic, then closes only that diagnostic. No provider/model task is launched."))
	if state.managed_busy or (state.managed_batch and state.managed_batch.status~="completed" and state.managed_batch.status~="failed") or (state.managed_route and state.managed_route.cleanup_pending) then prepare.disabled="Wait for setup or its owned diagnostic cleanup." end
	table.insert(rows,prepare)
	if state.managed_busy then table.insert(rows,static_row("managed-busy","Probe","Running","Wait for actual host/account/dependency/argv/helper observations.")) end
	if state.managed_probe then
		for index,observation in ipairs(state.managed_probe.observations) do
			if state.advanced or observation.state~="passed" then table.insert(rows,static_row("managed-observation-"..index,observation.id,observation.state,observation.summary)) end
		end
		local candidate=state.managed_record
		if candidate and state.advanced then
			table.insert(rows,static_row("managed-identity","Actual worker identity",candidate.mailbox.worker_identity,"One OS account does not isolate provider identities."))
			table.insert(rows,static_row("managed-helper","Reviewed target helper",candidate.mailbox.helper_path,"Exact packaged bytes in a stable, digest-specific bundle."))
			table.insert(rows,static_row("managed-producer","Verified producer helper",candidate.mailbox.producer_helper_path,"Packaged helper access is machine-observed, not a human attestation."))
			table.insert(rows,static_row("managed-capabilities","Managed capabilities",table.concat(candidate.mailbox.capabilities,", "),"Enabled record; "..candidate.mailbox.wake..". Provider authentication and task readiness are not inferred."))
			table.insert(rows,static_row("managed-fresh","Fresh launch argv",candidate.fresh_executable.." "..Config.render_arguments(candidate.fresh_arguments),"Review provider fresh-session and permission flags explicitly; labels and role text grant no isolation."))
			table.insert(rows,static_row("managed-cli-proof","Provider CLI semantics","Not verified","A route diagnostic verifies only its observed boundary, not custom CLI flag meanings, authentication or task readiness."))
		end
		if state.managed_probe.passed then
			table.insert(rows,static_row("managed-route-status","Launch verification",if state.managed_route then state.managed_route.status else "Ready to verify",if state.managed_route then state.managed_route.error or state.managed_route.summary or "Verification is running; successful cleanup saves setup automatically." else "The final check opens a temporary diagnostic and closes only that diagnostic before saving."))
			if not state.managed_route and state.advanced then
				table.insert(rows,action_row("managed-route-probe",if candidate and candidate.backend=="native-agent" then "Verify and save — uses model credits" else "Verify and save",action(state,"managed-route-probe"),"Native OMP sends one harmless startup body with your selected permissions and may use model credits. This is not a sandbox. Terminal uses an offline packaged helper. Neither certifies provider readiness."))
			end
		end
	end
	if state.managed_route and state.managed_route.cleanup_only and not state.managed_probe then
		table.insert(rows,static_row("managed-route-status","Interrupted diagnostic",state.managed_route.status,state.managed_route.error or "The owning native window must positively identify and close its diagnostic. No launch is replayed. Another probe remains blocked until native cleanup is observed."))
	end
	if state.advanced then table.insert(rows,action_row("managed-dismiss","Dismiss setup",action(state,"managed-dismiss"),"Preserves records/resources without claiming verification.")) end
	local readiness=setup.readiness
	table.insert(rows,static_row("managed-readiness","Provider readiness",(({not_run="Not checked",running="Checking",passed="Passed",failed="Needs attention"})[readiness.state] or readiness.state)..(if readiness.config_revision~=state.snapshot.config_revision then " (stale)" else ""),readiness.summary.." Setup does not certify provider readiness."))
	table.insert(rows,action_row("managed-exercise","Check provider readiness…",action(state,"managed-exercise"),"Optional real task/report/check exercise in ORCH+, with separate consent."))
	return {{id="managed-setup",page="managed",title="Prepare agents for ORCH+",rows=rows}}
end
local function record_sections(state)
	local sections={
		{id="agent-overview",page="agents",title="Overview",rows={static_row("agents-configured","Agents configured",tostring(#state.config.agents),"Saved provider records only.")}},
		{id="agent-filters",page="agents",title="Agent details",rows={choice_row("agents-filter-provider","Filter by provider",state.provider_filter,provider_options(state),"Providers come only from saved records."),text_row("agents-filter-label","Filter by label",state.label_filter,"Matches saved account suffixes.")}},
	}
	local matches=filtered_records(state)
	if #matches==0 then table.insert(sections,{id="agent-empty",page="agents",title="Matching agents",rows={static_row("agents-empty","Matching agents","None","No saved records match these filters.")}}) end
	for _,record in ipairs(matches) do
		local prefix=function(field)return record_row_id(state,record.id,field) end
		local backends={{value="local-terminal",label="Terminal"}}
		if state.advanced or record.backend=="ssh-command" then table.insert(backends,{value="ssh-command",label="SSH terminal"}) end
		if state.snapshot.host_os~="windows" then table.insert(backends,1,{value="native-agent",label="Native agent"}) end
		local rows={
			text_row(prefix("provider"),"Provider",record.provider,"Display label, not execution identity or proof of native agent recognition."),
			text_row(prefix("account_label"),"Account label suffix",record.account_label,"A distinguishing suffix, not an account-isolation mechanism."),
			choice_row(prefix("backend"),"Launch mode",record.backend,backends,"Settings only; this editor never launches a process."),
			text_row(prefix("command"),"Command",text(record.command),"Approved executable name or path."),
			text_row(prefix("arguments"),"Arguments",Config.render_arguments(record.arguments),"Shell-like editor syntax preserves quoted argument boundaries."),
			text_row(prefix("cwd"),"Working directory",text(record.cwd),"Used on the execution host."),
			choice_row(prefix("placement"),"Placement",record.placement,{{value="tab",label="New tab"},{value="split",label="Split"},{value="replace_if_alone",label="Replace if alone"}},"Saved placement: tab, split, or replace_if_alone."),
			switch_row(prefix("enabled"),"Enabled",record.enabled,"Disabled records cannot launch."),
		}
		if state.advanced then
			table.insert(rows,text_row(prefix("provider_family"),"Underlying AI provider",text(record.provider_family),"For OMP and wrappers, declare the real underlying provider. This is configuration, not verified runtime identity."))
			table.insert(rows,text_row(prefix("id"),"Stable id",record.id,"Launch-history identity.","Stable ids are immutable"))
			table.insert(rows,text_row(prefix("user"),"Unix user",text(record.user),"Non-secret account routing; labels do not create users."))
			table.insert(rows,text_row(prefix("json"),"Full record JSON","","Advanced: load this complete record including mailbox, fresh-launch and model/profile fields. Keep its stable ID; saving requires explicit settings approval before launch."))
		end
		if state.advanced then
			if record.backend=="native-agent" or record.backend=="ssh-command" or record.host then table.insert(rows,text_row(prefix("host"),"Host",text(record.host),"Native host identity or explicit SSH destination.")) end
			if record.backend=="ssh-command" then table.insert(rows,text_row(prefix("key_path"),"Key path",text(record.key_path),"Path only; never paste private key contents.")) end
		end
		if string.lower(record.provider)=="omp" then
			table.insert(rows,text_row(prefix("prompt"),"Approved startup prompt",text(record.prompt),"Delivered once per new Native OMP launch; never on reload. A custom nonempty prompt is preserved."))
		end
		if record.review_required then
			table.insert(rows,static_row("review-reason-"..record.id,"Needs settings review",text(record.review_reason),"Edit the launch settings, then explicitly approve them."))
			table.insert(rows,action_row("approve-"..record.id,"Approve reviewed command and settings",action(state,"approve:"..record.id),"Clears the review block only if the full canonical record validates."))
		end
		table.insert(sections,{id="record-"..record.id,page="agents",title=record.provider.." — "..record.account_label..(if state.advanced then " · "..record.id else ""),rows=rows})
	end
	return sections
end
-- Each row publishes one saved-agent launch intent; orchestration belongs to ORCH+.
local PAGES={{id="runtime",label="Current agents",icon="sparkle"},{id="spawn",label="Start an agent",icon="sparkle"},{id="agents",label="Agent settings",icon="sparkle"},{id="managed",label="Prepare for ORCH+",icon="sparkle"},{id="setup",label="Setup",icon="sparkle"}}
local PAGE_IDS={};for _,page in ipairs(PAGES) do PAGE_IDS[page.id]=true end
local INTENT_KEY,INTENT_ROLE="spawn-launch-intent","spawn.launch.intent"
local MAX_INTENTS=16
local QUEUE_FULL="Too many launches queued; wait a moment"
local intent_sequence=0
local function intent_queue_id()
	return string.format("intent-queue-%d-%08x-%08x-%08x",os.time(),math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647))
end
-- Pending intents queue oldest first, so every click launches exactly once.
-- Each gets a fresh id; the window runs each at most once and acknowledges it.
local function publish_intent(state,cx,kind,revision,record_id)
	if observer_migration_error then state.notice=observer_migration_error;return end
	state.intents=state.intents or {}
	if #state.intents>=MAX_INTENTS then state.intent_refused=true;state.notice=QUEUE_FULL;return end
	intent_sequence+=1
	state.intent_queue_id=state.intent_queue_id or intent_queue_id()
	table.insert(state.intents,{intent_id=tostring(cx.pane)..":"..string.format("%.0f",tern.now())..":"..tostring(intent_sequence),kind=kind,record_id=record_id,config_revision=revision,native_window=if kind=="readiness" or kind=="route_probe" or kind=="discard" then state.native_window else nil})
	state.intent_refused=nil
	state.notice=if kind=="setup" then "Guided setup requested; the SPAWN window starts it."
		elseif kind=="result" then "Setup result review requested in the SPAWN window."
		elseif kind=="discard" then "Exact setup-result discard decision requested in this native window; nothing has been consumed yet."
		elseif kind=="readiness" then "Optional readiness navigation requested in this Config's owner native window."
		else "Spawn requested; the SPAWN window launches it."
	cx:save()
end
local LAUNCH_LINE_MAX=160
local function provider_key(record)
	local key=string.lower(record.provider)
	return if key:match("^[a-z0-9-]+$") then key else "other"
end
local function launch_line(record)
	local command=text(record.command)
	if command=="" and record.backend=="native-agent" then command="Native OMP" end
	local arguments=Config.render_arguments(record.arguments)
	local line=command..(if arguments~="" then " "..arguments else "").." · "..(if text(record.cwd)~="" then record.cwd else "default folder")
	if #line>LAUNCH_LINE_MAX then
		-- Cut before a UTF-8 continuation byte so the line stays valid text.
		local cut=LAUNCH_LINE_MAX-3
		while cut>0 and (string.byte(line,cut+1) or 0)>=0x80 and (string.byte(line,cut+1) or 0)<0xC0 do cut-=1 end
		line=line:sub(1,cut).."…"
	end
	return line
end
local function launch_blocked(record)
	if not record.enabled then return "Disabled in Config" end
	if record.review_required then return "Needs settings review: "..(if text(record.review_reason)~="" then record.review_reason else "approve its launch settings in Configured agents") end
	if record.backend=="native-agent" and not text(record.prompt):find("%S") then return "Needs an approved startup prompt in Configured agents" end
	return nil
end
-- Start an agent is SPAWN's own page: Tern's prefs rows have no icon slot (Tern 0.9.22),
-- so this one page draws a documented table (provider icon cell, command cell, Spawn button cell)
-- beside the same page navigation. Every other page stays on the prefs layout.
-- One bordered card per row: icon and bold title in the head; the detail and the button share the body line.
local function spawn_card(key,icon,title,detail,button,mono)
	local line={ui.node("col",{grow=1},{ui.text(ui.span(detail or "",if mono then "muted mono" else "muted"))}),button}
	local props={role="spawn-card",key=key}
	if icon then props.icon=icon end
	return ui.card(title,{ui.node("row",{role="spawn-line",gap="sm"},line)},props)
end
local function spawn_agent_rows(state)
	local rows={}
	for _,record in ipairs(state.config.agents) do
		local blocked=launch_blocked(record)
		local title={ui.span(record.provider.." — "..record.account_label,"strong")}
		-- The reason stays on the row so a blocked agent is never silently dimmed.
		if blocked then table.insert(title,ui.span("  · "..blocked,"muted")) end
		table.insert(rows,spawn_card("spawn-launch:"..provider_key(record)..":"..record.id,ProviderIcons.for_provider(record.provider),title,launch_line(record),
			ui.button("Spawn",{size="sm",title=blocked,disabled=blocked or false,actions={click=action(state,"launch:"..record.id)}}),true))
	end
	return rows
end
local function spawn_page(state,lead)
	local nav={}
	for _,page in ipairs(PAGES) do
		table.insert(nav,ui.button("",{icon=page.icon,title=page.label,aria={label=page.label},variant="quiet",on=page.id==state.page,
			actions={click="page-go:"..page.id},key="spawn-nav:"..page.id}))
	end
	local body={
		ui.node("row",{role="spawn-top"},{
			ui.node("col",{grow=1},{ui.text(ui.span("02 · Start an agent","muted"))}),
			ui.button("Close",{size="sm",variant="quiet",actions={click="close"},key="spawn-close"}),
		}),
		-- Plain bold text, not Markdown: some Tern builds draw a Markdown heading as its raw "#" source.
		ui.node("row",{role="spawn-title"},{ui.text(ui.span("Start an agent","strong"))}),
		ui.text(ui.span(lead,"muted")),
	}
	local agents=spawn_agent_rows(state)
	if #agents==0 then
		table.insert(body,ui.card(ui.span("Saved agents","strong"),{ui.text(ui.span("None. Add agents in Setup first.","muted"))},{role="spawn-card",key="spawn-launch-empty"}))
	else for _,card in ipairs(agents) do table.insert(body,card) end end
	if state.intent_refused then
		table.insert(body,ui.card(ui.span(QUEUE_FULL,"strong"),{ui.text(ui.span("This click was not queued. Wait for the pending launch, then choose the agent again.","muted"))},{role="spawn-card",key="spawn-queue-full"}))
	end
	table.insert(body,ui.text(ui.span("Options","muted")))
	table.insert(body,spawn_card("spawn-refresh",nil,ui.span("Refresh","strong"),"Reload saved settings and current agents.",ui.button("Refresh",{size="sm",actions={click="refresh"}})))
	table.insert(body,spawn_card("spawn-advanced",nil,ui.span(if state.advanced then "Close Advanced" else "Advanced","strong"),"Raw diagnostics, full-record JSON and manual recovery.",
		ui.button(if state.advanced then "Close Advanced" else "Advanced",{size="sm",actions={click=if state.advanced then "advanced-close" else "advanced-open"}})))
	return ui.node("row",{role="spawn-start-page",gap="md",align="start"},{
		ui.node("col",{role="spawn-nav",gap="xs"},nav),
		ui.node("col",{role="spawn-page",gap="sm",grow=1,flex=1,fill=true},body),
	})
end
local function migration_hold(state,problem)
	if type(problem)=="table" then problem=problem.message or problem.code end
	state.admin_status="Held"
	state.admin_error=tostring(problem or "Managed migration observation is unavailable")
	state.notice=state.admin_error
end
local function migration_start(state,cx,operation,observed_nonce)
	if not state.binding then migration_hold(state,"Open Config on its original verified host before inspecting migration");return end
	local qualification,peer_origin
	if operation=="inspect" then
		-- A new read can supersede an unsubmitted challenge: its nonce fences any
		-- late callback before the sole writer. A potentially applied transition
		-- remains a live obligation until authoritative reconciliation settles it.
		local prior=state.admin_pending
		local why
		if prior and prior.started then
			qualification,why=Dispatch.admin_source(state.binding)
			if qualification then state.admin_qualification=qualification end
			if not qualification or not prior.transition_source or not Dispatch.protocol.equal(qualification.proof,prior.transition_source) then
				migration_hold(state,why or "The prior migration transition may have committed; its pending intent is retained for exact source reconciliation")
				return
			end
		end
		state.admin_pending=nil;state.admin_observation=nil
		if not qualification then qualification,why=Dispatch.admin_source(state.binding) end
		if not qualification then migration_hold(state,why);return end
		state.admin_qualification=qualification
	else
		local observed=state.admin_observation
		if not observed or observed.nonce~=observed_nonce or state.admin_pending then
			migration_hold(state,"This migration control is stale or another observation is pending; explicitly inspect again");return
		end
		qualification=observed.qualification
		peer_origin=observed.peer_origin
	end
	local expected=Dispatch.protocol.clone(qualification.proof)
	local pending={operation=operation,expected=expected,peer_origin=peer_origin,binding=state.binding,observed_nonce=observed_nonce}
	state.admin_pending=pending;state.admin_error=nil
	local nonce=string.format("migration-%d-%08x-%08x",os.time(),math.random(1,2147483647),math.random(1,2147483647))
	state.managed_migration_consent={nonce=nonce,operation=operation,observed_nonce=observed_nonce,
		deadline=tern.now()+30000,pending=pending}
	state.admin_status="Waiting for the window you clicked"
	-- Native client routing is only available synchronously in the button event.
	-- Remote clients may share an empty window key; never select from that list.
	local opened,why=pcall(function()cx:open("tern-spawn://managed-migration/"..string.format("%.0f",cx.pane).."/"..operation.."/"..nonce)end)
	if not opened then state.managed_migration_consent=nil;migration_hold(state,"Could not reach the clicked window: "..tostring(why)) end
end
local function migration_consent(state,event,cx)
	local P=Dispatch.protocol
	local input=if type(event.value)=="string" and #event.value<=4096 then decode(event.value) else nil
	local consent=state.managed_migration_consent
	if not consent or type(input)~="table" or input.nonce~=consent.nonce or input.operation~=consent.operation then return end
	state.managed_migration_consent=nil -- Consume before verification awaits, even on refusal.
	local pending=consent.pending
	if tern.now()>consent.deadline or state.admin_pending~=pending or state.binding~=pending.binding
		or (consent.operation~="inspect" and (not state.admin_observation or state.admin_observation.nonce~=consent.observed_nonce))
		or not P.fields(input,{nonce=true,operation=true,window=function(v)return type(v)=="string" and #v<=256 end,
			native_namespace=function(v)return P.text(v,128) end,native_conn=function(v)return P.integer(v,0) end,
			native_since=function(v)return P.integer(v,0) end,window_consent=function(v)return P.text(v,256) end}) then
		migration_hold(state,"Migration consent expired or changed incarnation; explicitly inspect again");return
	end
	state.admin_status="Verifying original native membership"
	verify(state,cx,function(session,why)
		if state.admin_pending~=pending then return end
		if not session or state.binding~=pending.binding then migration_hold(state,why or "Config authority changed during migration inspection");return end
		if tern.now()>consent.deadline then migration_hold(state,"Migration consent expired during membership verification; explicitly inspect again");return end
		pending.inventory=state.inventory
		pending.challenge={schema=1,nonce=consent.nonce,
			operation=consent.operation,native_window=input.window,native_conn=input.native_conn,native_since=input.native_since,
			native_namespace=input.native_namespace,window_consent=input.window_consent,
			native_session=session,host_pane_id=tostring(cx.pane),expected=pending.expected}
		state.admin_status="Waiting for fresh ORCH+ source qualification"
	end)
end
local function migration_result(state,event,cx)
	local pending=state.admin_pending
	local challenge=pending and pending.challenge
	if not challenge then return end
	if pending.started then migration_hold(state,"This migration transition was already submitted; inspect its current source rather than replaying it");return end
	local P=Dispatch.protocol
	local Codec=require("./wire/codec")
	local value,_,shapes=Codec.strict_decode(event.value,65536)
	if not P.fields(value,{intent_id=true,operation=true,native_window=true,native_namespace=true,window_consent=true,local_source=true,peer_qualification=true})
		or value.intent_id~=challenge.nonce or value.operation~=challenge.operation or not P.equal(value.local_source,challenge.expected) then
		migration_hold(state,"Migration callback does not match the original source intent; inspect again explicitly");return
	end
	local native=value.native_window
	if not P.fields(native,{window_key=true,conn=true,since=true})
		or native.window_key~=challenge.native_window or native.conn~=challenge.native_conn or native.since~=challenge.native_since
		or value.native_namespace~=challenge.native_namespace or value.window_consent~=challenge.window_consent
		or state.origin_session~=challenge.native_session or state.binding~=pending.binding or tostring(cx.pane)~=challenge.host_pane_id or state.closed then
		migration_hold(state,"Migration callback belongs to another native Config incarnation");return
	end
	local peer=value.peer_qualification
	if not P.fields(peer,{protocol=function(v)return v==2 end,phase=function(v)return v=="legacy" or v=="prepared" or v=="stable" end,
		source_nonce=function(v)return P.text(v,128) end,host_pane_id=function(v)return P.text(v,32) and v:match("^%d+$")~=nil end,
		authority_revision=function(v)return P.integer(v,0) end,source_sha256=P.digest,qualification=true},
		{authority_namespace=function(v)return P.text(v,128) end,compatibility=true,result=true})
		or not Codec.validate_dispatch_migration_qualification(peer.qualification,"orch",shapes)
		or peer.source_sha256~=peer.qualification.proof.source_sha256 or peer.authority_revision~=peer.qualification.proof.source_revision
		or (peer.authority_namespace~=nil and peer.authority_namespace~=peer.qualification.proof.candidate_namespace) then
		migration_hold(state,"ORCH+ has not published a complete matching source qualification; local SPAWN inspection remains available");return
	end
	if pending.peer_origin and (peer.host_pane_id~=pending.peer_origin.host_pane_id or peer.source_nonce~=pending.peer_origin.source_nonce) then
		migration_hold(state,"ORCH+ source incarnation changed since the inspected migration control was created");return
	end
	local peer_pane=tonumber(peer.host_pane_id)
	local members=peer_pane and pane_sessions(pending.inventory,peer_pane)
	local count=0;if members then for _ in pairs(members) do count+=1 end end
	local program=false
	for _,pane in ipairs(tern.pane.list()) do if pane.pane==peer_pane and pane.program=="orchplus.orchestrator" then program=true end end
	if count~=1 or members[tostring(challenge.native_session)]~=challenge.native_session or not program then
		migration_hold(state,"ORCH+ source is not the original native host/session controller block");return
	end
	-- No await after the fresh window proof. The sole writer independently checks
	-- the captured source again; the callback cannot supply a newer local fence.
	pending.started=challenge.operation~="inspect"
	local called,qualification,why,disposition=pcall(Dispatch.admin_apply,challenge.operation,challenge.expected,peer.qualification,function(proof)
		pending.transition_source=Dispatch.protocol.clone(proof)
	end)
	if not called then migration_hold(state,qualification);return end
	if not qualification then
		if disposition=="refused" then state.admin_pending=nil;state.admin_observation=nil end
		migration_hold(state,why);return
	end
	state.admin_pending=nil;state.admin_error=nil
	state.admin_qualification={proof=qualification.proof,selection=qualification.selection}
	state.admin_observation={nonce=challenge.nonce,qualification=state.admin_qualification,
		peer_origin={host_pane_id=peer.host_pane_id,source_nonce=peer.source_nonce}}
	state.admin_status=if challenge.operation=="inspect" then "Sources inspected; review before preparing"
		elseif challenge.operation=="prepare" then "Candidate prepared; inspect both current candidates before finishing"
		else "Paired migration finished"
	state.notice=state.admin_status
end
local function runtime_sections(state)
	local live={};local history={};local other={};local transport={}
	local restart=state.snapshot.host_restart_notice
	if restart and type(restart.count)=="number" and restart.count>0 then
		table.insert(live,static_row("host-restart","Host restarted: "..tostring(restart.count).." SPAWN "..(if restart.count==1 then "agent" else "agents").." ended (cleared automatically)","Informational","Their launches moved to history. Nothing was relaunched."))
	end
	for _,a in ipairs(state.snapshot.attempts) do
		local target=if a.phase=="Exited" or a.phase=="Failed" or not a.unresolved then history else live
		local phase=if state.scope_error and a.unresolved then "Unknown (last observed "..a.phase..")" else a.phase
		local record=record_by_id(state,a.record_id)
		local label=if record then record.provider.." — "..record.account_label elseif state.advanced then a.record_id else "Agent no longer configured"
		local detail=phase
		if state.advanced then
			detail..=" · "..a.mode.." · observer "..a.observer_id.." · pane "..tostring(a.pane or "unbound")
			if a.exit_status~=nil then detail..=" · exit "..tostring(a.exit_status) end
			if a.error_category then detail..=" · "..a.error_category end
		end
		if a.diagnostic then detail..=" · "..a.diagnostic end
		table.insert(target,static_row("attempt-"..a.id,label,detail,if state.advanced then "Observation scope "..a.scope..". Liveness is observer-reported, not authentication or readiness." else "This Tern session"))
	end
	if #live==0 then table.insert(live,static_row("live-empty","SPAWN launches","None","No live SPAWN launches in this native session.")) end
	if #history==0 then table.insert(history,static_row("history-empty","Failed/exited history","None","Failed terminal output stays in its original shell pane.")) end
	table.insert(history,action_row("clear-history",if state.armed=="clear-history" then "Confirm clear reviewed terminal history" else "Clear reviewed terminal history",action(state,"clear-history"),"Only terminal metadata is removed; panes and live attempts remain."))
	if state.scope_error or not state.inventory then
		table.insert(other,static_row("other-unknown","Observation scope","Unknown",state.scope_error or "Refresh to inspect visible host sessions."))
	else
		local seen={}
		for _,session in ipairs(state.inventory.sessions) do
			if session.id~=state.origin_session and not seen[session.id] then seen[session.id]=true;table.insert(other,static_row("other-"..tostring(session.id),text(session.name),"Native session "..tostring(session.id),"Read-only visible host inventory; never imported as a configured account. Parked membership is unknown.")) end
		end
		if #other==0 then table.insert(other,static_row("other-empty","Other Tern sessions","None visible","Read-only scope: this authority's owning native window inventory. Other client views are available through Running agents.")) end
		local forget=state.forget
		local kept=if forget and forget.kept>0 then string.format(" %d absent sessions retained because obligations or captured state still require them.",forget.kept) else ""
		local last=if forget then string.format("last run: %d sessions / %d attempts",forget.sessions,forget.attempts) else "not run yet"
		local held=if state.forget_hold then " Cleanup held: "..state.forget_hold.."; saved histories retained." else ""
		if state.advanced or state.forget_hold then table.insert(other,static_row("forget-status","Ended sessions","Automatic cleanup"..(if state.advanced then " · "..last else ""),"Settled sessions are cleaned up automatically."..kept..held)) end
	end
	if not state.advanced then
		-- Retained history and results stay available in the hidden snapshot.
		return {{id="running",page="runtime",title="Current agents",rows=live},{id="other",page="runtime",title="Other Tern sessions",rows=other}}
	end
	for id,reply in pairs(state.snapshot.replies) do
		readable_fields(transport,"reply-"..id,"Result "..id,reply)
		if state.advanced then table.insert(transport,static_row("reply-raw-"..id,"Raw result",tern.json.encode(reply),"Advanced diagnostic; retained until acknowledged or explicitly reviewed.")) end
		table.insert(transport,action_row("review-reply-"..id,if state.armed=="review-reply:"..id then "Confirm reviewed result" else "Mark result reviewed",action(state,"review-reply:"..id),"The observer may no longer receive this result; inspect its exact outcome before confirmation."))
	end
	table.insert(transport,action_row("reset-transport",if state.armed=="reset-transport" then "Confirm transport identity reset" else "Reset reviewed transport",action(state,"reset-transport"),"Requires no pending requests and every result acknowledged or reviewed. Preserves roster and attempts; old clients must reopen Config."))
	table.insert(transport,action_row("managed-migration-inspect","Inspect paired managed sources","managed-migration-inspect","Explicit HOST inspection publishes this source for ORCH+ without changing the read-only setup catalog. Incomplete peers remain visibly held."))
	table.insert(transport,static_row("managed-migration-status","Paired managed migration",state.admin_status or "Not inspected",state.admin_error or "Inspect the exact current sources before any migration transition. Ordinary SPAWN remains independent."))
	if state.admin_qualification then readable_fields(transport,"managed-migration-source","Captured SPAWN source",state.admin_qualification.proof) end
	if state.admin_observation and not state.admin_pending then
		local nonce=state.admin_observation.nonce
		table.insert(transport,action_row("managed-migration-prepare","Prepare validated paired migration","managed-migration-prepare:"..nonce,"Uses the exact inspected source and a fresh observation of the same ORCH+ source incarnation."))
		table.insert(transport,action_row("managed-migration-finish","Finish validated paired migration","managed-migration-finish:"..nonce,"Only compatible validated current candidates may finish; unresolved effects remain blocking."))
	end
	if state.binding then
		local owners,why=Dispatch.recovery_view(state.binding)
		if not owners then table.insert(transport,static_row("bridge-recovery-error","Managed dispatch",tostring(why),"Preserve the transport registry; no automatic reset."))
		else for _,owner in ipairs(owners) do
			local id=owner.logical_session_id
			readable_fields(transport,"bridge-owner-"..id,"Managed controller "..id,owner)
			table.insert(transport,action_row("bridge-recover-"..id,if owner.fenced then "I verified previous controller and pending launch executors stopped or retired" else "Fence managed controller for recovery","bridge-recover:"..id..":"..tostring(owner.revision)..":"..(if owner.fenced then "confirm" else "fence"),"Confirmation records operator attestation, not machine proof. Stop known-active executors first. It never starts a replacement or clears worker reservations."))
		end end
	end
	return {{id="running",page="runtime",title="SPAWN launches",rows=live},{id="history",page="runtime",title="Failed/exited history",rows=history},{id="other",page="runtime",title="Other Tern sessions",rows=other},{id="transport",page="runtime",title="Transport review",rows=transport}}
end
local function request_page_context(state,entry)
	state.page_only=true;state.page_entry=entry;state.page=entry.page;state.native_window=entry.native_window
	state.page_context_active=nil
	state.page_context_request={entry=entry,nonce=string.format("page-%d-%08x-%08x",os.time(),math.random(1,2147483647),math.random(1,2147483647))}
	state.notice="Waiting for SPAWN's own native context. Navigation has not created resources or completed setup."
end
local function view(state,cx)
	local snapshot=if state.snapshot then Authority.clone(state.snapshot) else {version=2,host_key=state.host_key or "unknown",authority_id="unavailable",session_key="unknown",config_revision=0,records={},attempt_revision=0,attempts={},jobs={},replies={},request_sequences={},host_os=tern.runtime.os,host_shell=tern.getenv("SHELL") or tern.getenv("ComSpec") or "unknown",ready=false}
	snapshot.host_cwd=state.default_cwd
	local replies=0;for _ in pairs(snapshot.replies) do replies+=1 end
	for _,entry in ipairs(state.transient or {}) do
		local id=entry.reply.request_id
		if entry.authority_id==snapshot.authority_id and snapshot.replies[id]==nil and replies<64 then snapshot.replies[id]=Authority.clone(entry.reply);replies+=1 end
	end
	if state.scope_error or not state.binding then snapshot.ready=false;snapshot.error=state.scope_error or state.notice or "Host membership pending" end
	local failure=observer_migration_error or state.reload_error or state.queue_error or state.transport_error
	if failure then snapshot.ready=false;snapshot.error=failure end
	local lead="Choose an agent, start a conversation, or manage its settings."
	if state.notice==SETUP_RESULT_NOTICE and not (state.snapshot and setup_active(state)) then state.notice=nil end
	if state.notice then lead..=" "..state.notice end
	if snapshot.error then lead..=" "..snapshot.error end
	local sections={}
	if state.snapshot then
		if state.snapshot.migration then sections=review_sections(state)
		elseif state.page=="managed" then sections=managed_sections(state)
		elseif state.page=="setup" then sections=setup_sections(state)
		elseif state.page=="spawn" then sections={}
		elseif state.page=="runtime" then sections=runtime_sections(state)
		else sections=record_sections(state) end
	end
	if not state.binding and state.page_only then
		table.insert(sections,{id="managed-page-entry",page=state.page,title="Prepare agents for ORCH+",rows={static_row("managed-page-context","Connecting to SPAWN",if state.page_context_request then "Waiting" else "Setup required",state.notice or "Refresh to reopen SPAWN on this execution machine. No resources have been prepared.")}})
	end
	table.insert(sections,{id="refresh",page=state.page,title="Options",rows={
		action_row("refresh","Refresh","refresh","Reload saved settings and current agents."),
		action_row("advanced",if state.advanced then "Close Advanced" else "Advanced",if state.advanced then "advanced-close" else "advanced-open","Raw diagnostics, full-record JSON and manual recovery.\nNot required for Guided setup."),
	}})
	local payload="SPAWN_STATE_V2 "..tern.json.encode(snapshot)
	if #payload>120000 then
		lead..=" Snapshot exceeds capacity; preserved state was not truncated or reset."
		payload="SPAWN_STATE_V2 "..tern.json.encode({version=2,host_key=snapshot.host_key,authority_id=snapshot.authority_id,session_key=snapshot.session_key,config_revision=snapshot.config_revision,records={},attempt_revision=snapshot.attempt_revision,attempts={},jobs={},replies={},request_sequences={},host_os=snapshot.host_os,host_shell=snapshot.host_shell,ready=false,error="Snapshot exceeds capacity; preserved state was not truncated or reset"})
	end
	local diagnostic=ui.text(payload);diagnostic.p=diagnostic.p or {};diagnostic.p.key="spawn-state";diagnostic.p.hidden=true
	local own_page=state.snapshot~=nil and not state.snapshot.migration and state.page=="spawn"
	local children={if own_page then spawn_page(state,lead) else ui.node("prefs",{title="SPAWN",lead=lead,pages=PAGES,page=state.page,sections=sections,focus=state.focus,editing=state.editing}),diagnostic}
	if state.advanced then table.insert(children,ui.text("Advanced raw diagnostics\n"..payload)) end
	-- Always publish a readable queue, including before a fresh Config's first click.
	-- Only a matching queue identity can prove durable ACK removal.
	local intent=ui.text(tern.json.encode({schema=1,queue_id=state.intent_queue_id,intents=state.intents or {}}));intent.p=intent.p or {};intent.p.key=INTENT_KEY;intent.p.role=INTENT_ROLE;intent.p.hidden=true
	table.insert(children,intent)
	if state.managed_route then
		local route=ui.text(tern.json.encode(state.managed_route));route.p=route.p or {};route.p.key="spawn-managed-route";route.p.role="spawn.managed.route";route.p.hidden=true
		table.insert(children,route)
	end
	if state.managed_native_request and state.page=="managed" then
		local request=ui.text(tern.json.encode(state.managed_native_request));request.p=request.p or {};request.p.key="spawn-native-accounts";request.p.role="spawn.native.accounts";request.p.hidden=true
		table.insert(children,request)
	end
	if state.setup_topology then
		local topology=state.setup_topology
		local node=ui.text(tern.json.encode({mode=topology.mode,selected=topology.selected,observation=topology.observation,request=topology.request,window=state.native_window}))
		node.p=node.p or {};node.p.key="spawn-setup-topology";node.p.role="spawn.setup.topology";node.p.hidden=true;table.insert(children,node)
	end
	if state.page_context_request then
		local pending=ui.text(tern.json.encode(state.page_context_request));pending.p=pending.p or {};pending.p.key="spawn-page-context";pending.p.role="spawn.page.context";pending.p.hidden=true
		table.insert(children,pending)
	end
	if state.admin_pending and state.admin_pending.challenge then
		local migration=ui.text(tern.json.encode(state.admin_pending.challenge));migration.p=migration.p or {}
		migration.p.key="spawn-managed-migration";migration.p.role="spawn.managed.migration";migration.p.hidden=true
		table.insert(children,migration)
	end
	if state.managed_batch then
		local batch=state.managed_batch
		local node=ui.text(tern.json.encode({schema=1,nonce=batch.nonce,revision=batch.revision,entries=batch.entries,status=batch.status,error=batch.error,window=state.native_window}))
		node.p=node.p or {};node.p.key="spawn-managed-prepare";node.p.role="spawn.managed.prepare";node.p.hidden=true;table.insert(children,node)
	end
	if state.setup_result_attempt and state.binding and setup_job(state,cx,state.setup_result_attempt) then
		local pending,why=Authority.setup_pending(state.binding,state.setup_result_attempt)
		if pending and not pending.consumed then
			local result=ui.text(pending.bytes);result.p=result.p or {};result.p.key="spawn-setup-result";result.p.role="spawn.setup.result";result.p.hidden=true
			table.insert(children,result)
		elseif why then table.insert(children,ui.text("Setup result unavailable: "..tostring(why))) end
	end
	return {main=ui.col(children)}
end
-- A prepared record whose launch/account contract changed is no longer prepared: the
-- verification was made for the old contract, so it is withdrawn, never silently kept.
local function withdraw_stale_preparation(old,new)
	if type(new.mailbox)~="table" or new.mailbox.verified~=true then return false end
	for field in pairs(CONTRACT_FIELDS) do
		if not Dispatch.protocol.equal(old[field],new[field]) then new.mailbox.verified=false;return true end
	end
	return false
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
		if canonical.mailbox and (canonical.mailbox.verified==true or canonical.mailbox.evidence_ref~=nil) and not Dispatch.protocol.equal(canonical.mailbox,record.mailbox) then state.notice="Managed readiness cannot be supplied by JSON. Use Prepare agents for ORCH+; unchanged previously verified helpers are preserved.";return end
		withdraw_stale_preparation(record,canonical)
		canonical.review_required=true
		canonical.review_reason=record.review_reason or "Review all launch, mailbox and selector settings after editing this record's JSON"
		local next_records=Authority.clone(state.config.agents);next_records[index]=canonical
		mutate(state,cx,revision,"replace-records",{records=next_records});return
	end
	local allowed={provider=true,provider_family=true,account_label=true,host=true,user=true,key_path=true,command=true,arguments=true,cwd=true,prompt=true,placement=true,backend=true,enabled=true}
	if not allowed[field] then return end
	local candidate=Authority.clone(record)
	if field=="arguments" then
		local args,err=Config.parse_arguments(value);if not args then state.notice=err;return end;value=args
	elseif field=="enabled" then
		if type(value)~="boolean" then state.notice="Expected a switch value";return end
	elseif type(value)~="string" or #value>32000 then state.notice="Invalid or oversized field";return end
	candidate[field]=value
	if field=="backend" and value~=record.backend then candidate.review_required=true;candidate.review_reason="Review this account's launch command and routing after changing launch mode" end
	local canonical,err=Config.validate_record(candidate);if not canonical then state.notice=err;return end
	if withdraw_stale_preparation(record,canonical) then state.notice="This agent's launch settings changed, so its ORCH+ preparation was withdrawn. Prepare agents for ORCH+ to check it again." end
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
local function open(state,cx,context_request)
	if state.page_only and not state.binding and context_request==nil then state.notice="Waiting for SPAWN's own native context; refresh this page to retry";return end
	verify(state,cx,function(session,err)
		if not session then state.notice=err;return end
		if context_request~=nil and state.page_context_active~=context_request then state.notice="The page entry changed during owner bootstrap; no old context was applied";return end
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
		if type(state.notice)=="string" and state.notice:match("^Waiting for SPAWN's own native context") then state.notice=nil end
		if context_request~=nil then state.page_context_active=nil end
	end)
end
local definition={
	font="sans",
	init=function(cx,args,saved)
		local discovery=nil;if #args>0 then discovery=decode(args[1]) end
		local page_only=type(discovery)=="table" and discovery.kind=="page"
		local state={config={schema=2,agents={}},host_key=if page_only then nil else host_key(discovery),page="runtime",provider_filter="",label_filter="",import_text="",notice=nil,editing=nil,focus=nil,setup_topology={mode="single"}}
		if type(saved)=="table" then
			if PAGE_IDS[saved.page] then state.page=saved.page end
			if type(saved.origin_session)=="number" then state.origin_session=saved.origin_session end
			if type(saved.origin_scope)=="string" then state.origin_scope=saved.origin_scope end
			if not state.host_key and type(saved.host_key)=="string" then state.host_key=saved.host_key end
			if type(saved.intents)=="table" then
				state.intents=Authority.clone(saved.intents)
				-- A retired unadmitted bulk click is not an effect to replay.
				-- Already admitted individual attempts remain in Authority.
				for index=#state.intents,1,-1 do
					if type(state.intents[index])=="table" and state.intents[index].kind=="all" then table.remove(state.intents,index);state.notice="A previous bulk request was retired. Choose one saved agent to start." end
				end
			end
			if type(saved.intent_queue_id)=="string" and #saved.intent_queue_id>0 then state.intent_queue_id=saved.intent_queue_id end
		end
		if page_only then
			state.page_only=true;state.page="managed"
			local entry,why=PageNavigation.page(discovery)
			if entry then request_page_context(state,entry) else state.notice=why end
		elseif type(discovery)=="table" then
			state.native_window=discovery.native_window
			state.host=discovery.host
			state.client_config=discovery.client_config
			state.choose_start_page=discovery.page=="start"
			if PAGE_IDS[discovery.page] then state.page=discovery.page end
		end
		live_blocks[cx.pane]={state=state,cx=cx}
		if not page_only then open(state,cx) end
		return state
	end,
	view=function(state,cx)return view(state,cx) end,
	event=function(state,event,cx)
		local incoming=event
		if event.ev=="action" and event.id=="main" and event.act=="spawn.migration-result" then migration_result(state,event,cx);return end
		if event.ev=="action" and event.id=="main" and event.act=="managed-migration-consent" then migration_consent(state,event,cx);return end
		if event.ev=="action" and event.id=="main" and event.act=="page-entry" then
			local entry,why=PageNavigation.page(event.value)
			if not entry then state.notice=why;return end
			if state.native_window~=nil and state.native_window~=entry.native_window then state.notice="This SPAWN pane belongs to another native window; no page was rebound";return end
			if state.binding then state.page=entry.page;state.editing=nil;state.focus=nil;open(state,cx)
			else request_page_context(state,entry) end
			return
		end
		if event.ev=="action" and event.id=="main" and event.act=="spawn.page-context" then
			local pending=state.page_context_request
			local response=decode(event.value,MAX_TEXT+256)
			if not pending or type(response)~="table" or response.nonce~=pending.nonce then state.notice="Stale SPAWN owner context was refused";return end
			for key in pairs(response) do if key~="nonce" and key~="context" and key~="error" then state.notice="Unexpected SPAWN owner context field";return end end
			if response.error~=nil then
				if response.context~=nil or type(response.error)~="string" or #response.error>1024 then state.notice="Invalid SPAWN owner context failure";return end
				state.page_context_request=nil;state.notice=response.error;return
			end
			local context,why=PageNavigation.context(response.context,pending.entry.native_window)
			if not context then state.notice=why;return end
			local key=host_key(context)
			if not key or (state.host_key and state.host_key~=key) then state.notice="SPAWN owner context changed execution host; no settings were opened";return end
			state.page_context_request=nil;state.page_context_active=pending
			state.host_key=key;state.host=context.host;state.client_config=context.client_config;state.native_window=context.native_window
			open(state,cx,pending)
			return
		end
		if event.ev=="action" and event.id=="main" and (event.act=="spawn.launch-intent-claim" or event.act=="spawn.launch-intent-ack") then
			local P=Dispatch.protocol
			if observer_migration_error then state.notice=observer_migration_error;return end
			local input=decode(event.value,2048)
			if type(input)~="table" or not P.text(input.intent_id,256) or type(input.window_key)~="string" or #input.window_key>256
				or not P.text(input.observer_id,200) or not P.integer(input.conn,0) or not P.integer(input.since,0) then state.notice="Invalid launch intent recipient";return end
			if input.queue_id~=state.intent_queue_id then state.notice="Launch intent belongs to another Config queue";return end
			for _,pending in ipairs(state.intents or {}) do
				if pending.intent_id~=input.intent_id then continue end
				if event.act=="spawn.launch-intent-ack" then
					if not WindowJournal.same_recipient(pending.recipient,input) then state.notice="Launch intent acknowledgment belongs to another incarnation";return end
					for index,current in ipairs(state.intents) do
						if current==pending then
							table.remove(state.intents,index)
							local saved,save_error=pcall(function()cx:save()end)
							if not saved then table.insert(state.intents,index,pending);state.notice="Launch acknowledgment could not be persisted: "..tostring(save_error)
							else state.intent_refused=nil end
							return
						end
					end
				end
				if pending.recipient~=nil then return end
				local retirement=WindowJournal.capture()
				-- A remote client's key is foreign to this host daemon: inspect through the
				-- host window resolved by verification and match its remote client entries.
				local remote=remote_host(state)
				local scope=if remote then state.host_window else input.window_key
				if scope==nil then state.notice="Launch recipient cannot be resolved until this Config pane is verified in a host window";return end
				local started,why=pcall(Native.inspect,scope,{timeout_ms=5000},function(result,problem)
					if state.closed then return end
					local windows,identity_error,inventory=nil,problem,nil
					if not identity_error then windows,identity_error,inventory=WindowJournal.client_inventory(result) end
					local recipient=nil
					if windows and not remote and windows[input.window_key] then
						local handle;handle,identity_error=WindowJournal.open(input.window_key,result,retirement)
						if handle and WindowJournal.same_recipient(handle.recipient,input) then recipient=handle.recipient end
					elseif windows and (remote or state.native_window==input.window_key) then
						-- Remote conn/since belong to this host's SSH connection, not
						-- the desktop's native window. Keep the desktop's directed
						-- recipient opaque; never open its journal on the remote host.
						for _,client in ipairs(inventory.clients) do
							if client.kind=="remote" and client.window==scope and P.integer(client.conn,0) and P.integer(client.since,0) then
								recipient={window_key=input.window_key,observer_id=input.observer_id,conn=input.conn,since=input.since}
								break
							end
						end
					end
					if not recipient then state.notice=identity_error or "Launch recipient does not match the connected native window";cx:render();return end
					local sessions=if inventory and type(inventory.sessions)=="table" then pane_sessions(inventory,cx.pane) else nil
					local session_count=0;if sessions then for _ in pairs(sessions) do session_count+=1 end end
					if session_count~=1 or state.origin_session==nil or sessions[tostring(state.origin_session)]~=state.origin_session then state.notice="Launch recipient no longer owns this Config session";cx:render();return end
					if pending.native_window~=nil and pending.native_window~=input.window_key then return end
					for _,current in ipairs(state.intents or {}) do
						if current==pending and current.recipient==nil then
							local prior_queue=state.intent_queue_id
							state.intent_queue_id=state.intent_queue_id or intent_queue_id()
							current.recipient=recipient
							local saved,save_error=pcall(function()cx:save()end)
							if not saved then current.recipient=nil;state.intent_queue_id=prior_queue;state.notice="Launch recipient could not be persisted: "..tostring(save_error) end
							cx:render();return
						end
					end
				end)
				if not started then state.notice="Launch recipient inspection failed: "..tostring(why) end
				return
			end
			return
		end
		if event.ev=="action" and event.id=="main" and event.act=="spawn.request" then
			local input,err=decode(event.value)
			if not input then state.transport_error=err;return end
			acknowledge_transient(state,input)
			verify(state,cx,function(session,why)
				if not session then state.transport_error=why;refuse(state,input,why);return end
				if not state.binding then state.transport_error="Authority not initialized";refuse(state,input,state.transport_error);return end
				local ok,reason=Authority.request(state.binding,input,{config_pane=cx.pane,window=state.native_window,host_window=state.host_window,inventory=state.inventory,epoch=Executor.epoch()})
				if ok and (input.op=="launch_record" or input.op=="start_setup") then Executor.attach(state.binding) end
				state.transport_error=if ok then nil else reason;reload(state)
				if not ok then refuse(state,input,reason) end
				queue_sweep()
			end)
			return
		end
		if event.ev=="action" and event.id=="main" and event.act=="spawn.setup-result-select" then
			local input,why=decode(event.value,2048)
			if type(input)~="table" or type(input.attempt_id)~="string" then state.notice=why or "Invalid setup result selection";return end
			for key in pairs(input) do if key~="attempt_id" then state.notice="Unexpected setup result selection field";return end end
			state.setup_result_attempt=nil
			local binding=state.binding
			verify(state,cx,function(session,err)
				if not session or state.binding~=binding or not reload(state) then state.notice=err or "Setup Config source changed";return end
				if not setup_job(state,cx,input.attempt_id) then state.notice="Setup result belongs to another Config pane or window";return end
				local pending,problem=Authority.setup_pending(binding,input.attempt_id)
				if not pending or pending.consumed then state.notice=problem or "No unconsumed submitted setup result";return end
				state.setup_result_attempt=input.attempt_id;state.notice=SETUP_RESULT_NOTICE
			end)
			return
		end
		if event.ev=="action" and event.id=="main" and event.act=="spawn.setup-devices" then
			local topology=state.setup_topology
			local input=decode(event.value,32000)
			if not topology or not topology.request or type(input)~="table" or input.nonce~=topology.request.nonce or input.window~=state.native_window then return end
			topology.request=nil
			local observed,why=SetupDiscovery.devices(input.devices,input.current)
			topology.observation=observed;topology.selected=if observed then observed.current else nil
			topology.error=why or (if type(input.error)=="string" then input.error:sub(1,1024) else nil)
			return
		end
		if event.ev=="action" and event.id=="main" and event.act=="spawn.native-accounts" then
			local input,why=decode(event.value,100000);local pending=state.managed_native_request
			if not pending or type(input)~="table" or input.nonce~=pending.nonce or input.window~=state.native_window or type(input.choices)~="table" or #input.choices>32 then state.notice=why or "Stale native account discovery was refused";return end
			local choices={}
			for _,route in ipairs(input.choices) do
				if type(route)~="table" or type(route.command)~="string" or #route.command>8192 or route.command:find("%c") or type(route.label)~="string" or #route.label>256 or route.label:find("%c") then state.notice="Invalid native account discovery";return end
				table.insert(choices,{command=route.command,label=route.label})
			end
			state.managed_native_choices=choices;state.managed_native_request=nil
			state.managed_native_error=if type(input.error)=="string" then input.error:sub(1,1024) else nil
			if not state.managed_draft_touched and not state.managed_existing and choices[1] and choices[1].label=="Tern default agent" then managed_native_select(state,"1") end
			return
		end
		local _,input_field=parse_record_row(incoming.item)
		if not state.advanced and (incoming.item=="manual-json" or input_field=="json"
			or (event.ev=="action" and type(event.act)=="string" and (event.act:match("^manual%-") or event.act=="bridge-import-open"))) then
			state.notice="Open Advanced explicitly to edit JSON or recover a setup result.";return
		end
		if event.ev=="change" and type(incoming.item)=="string" then
			local pending=false
			for _,intent in ipairs(state.intents or {}) do if intent.kind=="setup" then pending=true end end
			if pending and (incoming.item=="setup-device-mode" or incoming.item=="setup-primary") then state.notice="The chosen execution machine is already queued; it was not changed.";return end
			if state.managed_batch and state.managed_batch.status~="completed" and state.managed_batch.status~="failed" and (incoming.item=="managed-existing" or incoming.item=="managed-native") then state.notice="Wait for setup before choosing another agent.";return end
		end
		if event.ev=="change" then
			if incoming.item=="agents-filter-provider" then state.provider_filter=text(incoming.value);state.editing=nil
			elseif incoming.item=="setup-device-mode" then
				if state.setup_topology and (incoming.value=="single" or incoming.value=="multi") then
					state.setup_topology={mode=incoming.value};state.editing=nil
				end
			elseif incoming.item=="setup-primary" then
				if state.setup_topology and state.setup_topology.observation then
					local device,why=SetupDiscovery.primary(state.setup_topology.observation,tonumber(incoming.value),state.setup_topology.mode)
					if device then state.setup_topology.selected=device.id;state.setup_topology.error=nil else state.setup_topology.error=why end
					state.editing=nil
				end
			elseif incoming.item=="manual-json" then state.import_text=text(incoming.value);state.import_review=nil
			elseif incoming.item=="managed-native" then
				managed_native_select(state,incoming.value)
			elseif incoming.item=="managed-existing" then
				state.managed_edit_one=true
				state.managed_draft_touched=true;state.managed_native_selected=nil
				local record=record_by_id(state,incoming.value)
				state.managed_existing=if record then record.id else nil
				state.managed_draft=if record then ManagedSetup.from_record(record,state.default_cwd) else nil
				managed_draft(state);state.managed_draft_revision=state.snapshot.config_revision
				state.managed_probe=nil;state.managed_record=nil;state.managed_route=nil;state.editing=nil
			elseif type(incoming.item)=="string" and incoming.item:match("^managed:") then managed_change(state,incoming.item:sub(9),incoming.value)
			else
				local rid,rev=nil,nil
				if type(incoming.item)=="string" then rid,rev=incoming.item:match("^review:(.+):(%d+)$") end
				if rid then mutate(state,cx,tonumber(rev),"review-choice",{id=rid,source=tonumber(incoming.value)})
				else local id,field,revision=parse_record_row(incoming.item);if id then update_record(state,cx,id,field,incoming.value,revision) end end
			end
		elseif event.ev=="activate" then
			local item=incoming.item;local draft=nil;local revision=nil
			if item=="agents-filter-provider" then state.focus=item;state.editing={row=item,option=state.provider_filter};return
			elseif item=="setup-device-mode" or item=="setup-primary" then
				local topology=state.setup_topology
				if topology then state.focus=item;state.editing={row=item,option=if item=="setup-device-mode" then topology.mode else tostring(topology.selected)} end
				return
			elseif item=="agents-filter-label" then draft=state.label_filter
			elseif item=="manual-json" then draft=state.import_text
			elseif item=="managed-existing" then state.focus=item;state.editing={row=item,option=state.managed_existing or ""};return
			elseif item=="managed-native" then state.focus=item;state.editing={row=item,option=state.managed_native_selected or ""};return
			elseif type(item)=="string" and item:match("^managed:") then
				local field=item:sub(9)
				if field=="backend" then state.focus=item;state.editing={row=item,option=managed_draft(state).backend};return end
				if MANAGED_FIELDS[field] then draft=managed_draft(state)[field] end
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
			if event.act=="advanced-open" or event.act=="advanced-close" then
				state.advanced=event.act=="advanced-open";state.editing=nil;state.focus=nil;state.import_review=nil;return
			end
			if event.act=="managed-migration-inspect" then migration_start(state,cx,"inspect");return end
			local migration_operation,migration_nonce
			if type(event.act)=="string" then migration_operation,migration_nonce=event.act:match("^managed%-migration%-(%a+):(.+)$") end
			if migration_operation=="prepare" or migration_operation=="finish" then
				-- Match the rendered inspection token instead of borrowing newer state.
				migration_start(state,cx,migration_operation,migration_nonce);return
			end
			local go_page=if type(event.act)=="string" then event.act:match("^page%-go:(%a+)$") else nil
			if go_page then event.act="page";event.value=go_page end
			if event.act=="page" and event.value=="start" then state.choose_start_page=true;open(state,cx);return end
			if event.act=="page" and PAGE_IDS[event.value] then
				if state.page_only and not state.binding then if state.page_entry then request_page_context(state,state.page_entry) end;return end
				state.page=event.value;state.focus=nil;state.editing=nil;state.armed=nil;open(state,cx);return
			end
			if event.act=="refresh" then
				if state.page_only and not state.binding then if state.page_entry then request_page_context(state,state.page_entry) else state.notice="Invalid page entry; reopen Managed local setup from SPAWN" end;return end
				if state.page=="managed" then state.managed_native_choices=nil;state.managed_native_request=nil;state.managed_native_error=nil end
				open(state,cx);return
			end
			if event.act=="managed-prepare-consent" or event.act=="managed-reviewed-prepare" then
				local input=decode(event.value,65536)
				if event.act=="managed-reviewed-prepare" then
					local ref=if type(input)=="table" then input.reviewed else nil
					if type(ref)~="table" or type(input.entries)~="table" or #input.entries<1 or #input.entries>32 or not Dispatch.protocol.text(input.nonce,256) or input.nonce:find("[^%w%-]") or input.window~=state.native_window then return end
					state.guided_prepare_seen=state.guided_prepare_seen or {}
					if state.guided_prepare_seen[input.nonce] then return end
					state.guided_prepare_seen[input.nonce]=true
					if not reload(state) or state.snapshot.config_revision~=input.config_revision then state.notice="Agents were saved, but preparation settings changed. No checks were started.";return end
					local job=setup_job(state,cx,ref.attempt_id)
					local retained,why=Authority.setup_pending(state.binding,ref.attempt_id)
					if not job or job.setup_discarded or not retained or not retained.consumed or retained.setup_run_id~=ref.setup_run_id or retained.digest~=ref.pending_digest then state.notice=why or "The exact reviewed setup save is unavailable; no preparation was accepted.";return end
					local approved,approval_error=Authority.reviewed_setup_preparation(state.binding,ref.import_request_id,ref.attempt_id,ref.pending_digest)
					if not approved or approved.nonce~=input.nonce or approved.revision~=input.config_revision or approved.window~=input.window or approved.native_namespace~=input.native_namespace or approved.native_conn~=input.native_conn or approved.native_since~=input.native_since or not Dispatch.protocol.equal(approved.entries,input.entries) or not Dispatch.protocol.equal(approved.consents,input.consents) then state.notice=approval_error or "Preparation differs from the exact native approval saved with these settings; nothing was started.";return end
					local selected={}
					for _,entry in ipairs(input.entries) do if type(entry)~="table" then return end;table.insert(selected,entry.record_id) end
					managed_batch_offer(state,cx,input.config_revision,true,{nonce=input.nonce,entries=input.entries,selected=selected})
				end
				local batch=state.managed_batch
				if not batch or batch.status~="awaiting_consent" or type(input)~="table" or input.nonce~=batch.nonce or input.config_revision~=batch.revision or input.window~=state.native_window then return end
				if type(input.consents)~="table" or #input.consents~=#batch.entries or type(input.native_namespace)~="string" or #input.native_namespace==0 or #input.native_namespace>96 or not Dispatch.protocol.integer(input.native_conn,0) or not Dispatch.protocol.integer(input.native_since,0) then return end
				local seen={}
				for index,entry in ipairs(batch.entries) do
					local consent=input.consents[index]
					if type(consent)~="table" or consent.nonce~=entry.nonce or not Dispatch.protocol.text(consent.window_consent,256) or seen[consent.window_consent] then return end
					seen[consent.window_consent]=true
				end
				if tern.now()>batch.deadline then managed_batch_fail(state,"The clicked-window approval expired; nothing was launched");return end
				batch.status="accepted";batch.consent=Authority.clone(input.consents)
				batch.recipient={native_namespace=input.native_namespace,native_conn=input.native_conn,native_since=input.native_since}
				managed_batch_next(state,cx,batch);return
			end
			if event.act=="managed-prepare-next" then
				local input=decode(event.value,2048);local batch=state.managed_batch;local route=state.managed_route
				if not batch or batch.status~="waiting_next" or not route or type(input)~="table" then return end
				local entry=batch.entries[batch.index];local consent=batch.consent[batch.index]
				if input.nonce~=entry.nonce or input.window_consent~=consent.window_consent or input.window~=state.native_window or input.native_namespace~=batch.recipient.native_namespace or input.native_conn~=batch.recipient.native_conn or input.native_since~=batch.recipient.native_since or route.nonce~=entry.nonce or route.status~="passed" or route.cleanup_pending~=false then return end
				verify(state,cx,function(session,why)
					if state.managed_batch~=batch or batch.status~="waiting_next" or state.managed_route~=route then return end
					if not session or state.binding~=batch.binding or not reload(state) then managed_batch_fail(state,why or "The setup owner changed before completion");return end
					if state.snapshot.config_revision~=batch.expected_revision or not Dispatch.protocol.equal(state.config.agents,batch.expected_records) then managed_batch_fail(state,"Saved settings changed before setup completion; remaining approval was cancelled");return end
					batch.index+=1;managed_batch_next(state,cx,batch)
				end);return
			end
			if event.act=="managed-route-consent" then
				local input=if type(event.value)=="string" and #event.value<=4096 then decode(event.value) else nil
				local consent=state.managed_route_consent
				if not consent or type(input)~="table" or input.nonce~=consent.nonce or input.config_revision~=consent.revision then return end
				state.managed_route_consent=nil -- Consume before awaiting; never replay consent.
				if tern.now()>consent.deadline or input.window~=state.native_window then state.notice="Diagnostic consent expired or changed window; click the diagnostic again.";return end
				local binding=state.binding
				verify(state,cx,function(session,why)
					if not session or state.binding~=binding or not reload(state) then state.notice=why or "Setup origin changed";return end
					if consent.revision~=state.snapshot.config_revision then state.notice="stale-config: review refreshed setup before repeating";return end
					if state.managed_route then state.notice="This diagnostic already ran or is running; it was not repeated.";return end
					if not state.managed_probe or not state.managed_probe.passed or state.managed_probe_revision~=consent.revision then state.notice="Complete this revision's resource prerequisites first";return end
					local route,err=ManagedSetup.route(state.managed_record,state.managed_probe,state.snapshot,consent.revision,state.native_window,consent.nonce)
					if not route then state.notice=err;return end
					route.status="running";route.native_session=session;route.source_pane=cx.pane
					route.authority_id=binding.authority_id;route.origin_epoch=Executor.epoch()
					route.native_namespace=input.native_namespace;route.native_conn=input.native_conn;route.native_since=input.native_since
					route.window_consent=input.window_consent
					route.record_id=state.managed_record.id
					local claimed,claim_error=Authority.setup_probe_claim(state.host_key,consent.revision,route)
					if not claimed then state.notice=claim_error;return end
					route.cleanup_pending=true;state.managed_route=route
					state.notice="Diagnostic accepted in the window you clicked. Waiting for its native launch."
				end);return
			end
			if event.act=="managed-route-preflight" or event.act=="managed-route-started" or event.act=="managed-route-observed" or event.act=="managed-route-finished" then
				local input=if type(event.value)=="string" and #event.value<=4096 then decode(event.value) else nil
				local route=state.managed_route
				if not route or type(input)~="table" or input.nonce~=route.nonce or input.window~=state.native_window or input.window~=route.window or type(input.pane)~="number" or input.pane<0 or input.pane%1~=0 then return end
				if input.native_namespace~=route.native_namespace or input.native_conn~=route.native_conn or input.native_since~=route.native_since then return end
				verify(state,cx,function(session,why)
					if not session or state.managed_route~=route or not reload(state) then state.notice=why or "Native probe origin changed";return end
					if route.cleanup_pending==false then return end
					if session~=route.native_session then route.status="failed";route.error="Diagnostic native session changed; cleanup remains pending";return end
					if event.act=="managed-route-preflight" then
						route.launch_ready=nil
						if route.cleanup_blocked or route.cleanup_only or route.status~="running" or route.bound_pane~=nil or not route.native_namespace then
							route.status="failed";route.error="Native diagnostic launch preflight refused; no launch is authorized and cleanup remains held";return
						end
						route.observation_deadline=tern.now()+45000
						route.launch_ready={nonce=route.nonce,config_revision=route.config_revision,native_namespace=route.native_namespace,native_conn=route.native_conn,native_since=route.native_since}
						route.error=nil
						return
					end
					if route.bound_window_pane and input.pane~=0 and route.bound_window_pane~=input.pane then route.status="failed";route.error="Diagnostic desktop pane identity changed";return end
					local native_pane=route.owned_pane or route.bound_pane
					local members=pane_sessions(state.inventory,native_pane);local count=0
					if members then for _ in pairs(members) do count+=1 end end
					if event.act=="managed-route-finished" then
						local retained=false
						for _,native_session in ipairs(state.inventory.sessions) do for _,tab in ipairs(native_session.tabs or {}) do for _,block in ipairs(tab.blocks or {}) do
							if block.command==route.command then retained=true end
						end end end
						if input.cleaned~=true or route.bound_pane==nil or input.pane~=route.bound_window_pane or not route.discovery_complete or not members or count~=0 or retained then route.status="failed";route.error="Owned diagnostic cleanup lacks positive bound-pane settlement; the obligation remains held";return end
						local cleared,clear_error=Authority.setup_probe_clear(state.host_key,route.nonce)
						if not cleared then route.status="failed";route.error=clear_error;return end
						route.cleanup_pending=false
						if route.observed and input.error==nil and not route.cleanup_only and state.snapshot.config_revision==route.config_revision and state.managed_probe and state.managed_probe.record_sha256==route.record_sha256 then
							route.status="passed"
							table.insert(state.managed_probe.observations,{id="native-route",state="passed",summary=route.summary})
							local saved,save_error=Authority.setup_edit(state.host_key,route.config_revision,if state.managed_existing then "adopt" else "commit",{record=state.managed_record,probe=state.managed_probe,verified=true})
							local refreshed=reload(state)
							state.notice=if saved then "Saved agent setup. Provider authentication, custom CLI semantics and readiness remain separate." else save_error
							if saved then
								local id=state.managed_record.id
								state.managed_probe=nil;state.managed_record=nil;state.managed_existing=id
								if refreshed then
									state.managed_draft=ManagedSetup.from_record(record_by_id(state,id),state.default_cwd)
									state.managed_draft_revision=state.snapshot.config_revision
								end
								local batch=state.managed_batch
								if batch and batch.status=="verifying" and batch.entries[batch.index] and batch.entries[batch.index].nonce==route.nonce then
									if not refreshed or state.snapshot.config_revision~=route.config_revision+1 then route.status="failed";managed_batch_fail(state,"The saved agent could not be read back");return end
									table.insert(batch.saved,id);batch.expected_revision=state.snapshot.config_revision
									batch.expected_records=Authority.clone(state.config.agents);batch.status="waiting_next"
									local settled_entry=batch.entries[batch.index]
									tern.timer(30000,function()
										if not state.closed and state.managed_batch==batch and batch.status=="waiting_next" and batch.entries[batch.index]==settled_entry then managed_batch_fail(state,"The saved agent's native completion receipt was not confirmed. Remaining checks were not started");cx:render() end
									end)
								end
							end
							if not saved then route.status="failed";if state.managed_batch then managed_batch_fail(state,save_error) end end
						else route.status="failed";route.error=route.error or tostring(input.error or "Native route observation did not pass"):gsub("%c"," "):sub(1,1024) end
						if route.status=="failed" and state.managed_batch then managed_batch_fail(state,route.error or "Route verification failed") end
						return
					end
					if not members or count~=1 or members[tostring(session)]~=session or input.pane==0 then return end
					if route.owned_pane==nil or route.owned_pane~=native_pane then route.status="failed";route.error="Exact native command/cwd ownership was not observed";return end
					local bound,bind_error=Authority.setup_probe_bind(state.host_key,route.nonce,native_pane,input.pane)
					if not bound then route.status="failed";route.error=bind_error;return end
					route.pane=native_pane;route.bound_window_pane=input.pane
					if route.status~="running" or route.observing or route.cleanup_only then return end
					if state.snapshot.config_revision~=route.config_revision or not state.managed_probe or state.managed_probe.record_sha256~=route.record_sha256 then route.status="failed";route.error="Configuration or probe changed; native cleanup is still required";return end
					-- A terminal diagnostic may exit before another window round trip.
					-- Its exact native identity is already bound; read its nonce-bound
					-- output now. OMP still needs the window's startup-body observation.
					if event.act=="managed-route-started" and route.backend=="native-agent" then return end
					route.observing=true
					local deadline=route.observation_deadline or (tern.now()+45000)
					local function observe()
						if state.closed or state.managed_route~=route or not reload(state) or route.cleanup_pending==false or route.cleanup_only or route.cleanup_blocked or route.status~="running" then return end
						ManagedSetup.observe_route(route,session,native_pane,function(summary,err,pending)
							if state.closed or state.managed_route~=route then return end
							if not reload(state) or state.snapshot.config_revision~=route.config_revision then summary=nil;err="Configuration changed during native process readback";pending=false end
							if state.managed_route~=route or route.cleanup_pending==false or route.cleanup_only or route.cleanup_blocked or route.status~="running" or not route.observing then return end
							if pending and tern.now()<deadline then
								route.summary="Native terminal observation is not complete; waiting within the diagnostic deadline"
								cx:render();tern.timer(250,observe);return
							end
							route.observing=nil;route.observed=summary~=nil;route.summary=summary
							route.status=if summary then "observed" else "failed"
							route.error=if pending then "Native terminal output did not complete before the diagnostic deadline" elseif err then tostring(err):gsub("%c"," "):sub(1,1024) else nil
							cx:render()
						end,state.host_window)
					end
					observe()
				end);return
			end
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
			if event.act=="close" then if event.value==nil then state.closed=true;state.inspect_queue={};live_blocks[cx.pane]=nil;cx:exit(0) else state.editing=nil;state.focus=nil end;return end
			local op,rev=event.act:match("^(.*)@(%d+)$");local expected=tonumber(rev)
			if not op or not state.snapshot then return end
			if expected~=state.snapshot.config_revision then reload(state);state.notice="stale-config: review the refreshed settings and repeat your action";return end
			if op=="managed-open" then state.page="managed";return end
			local review_id=op:match("^managed%-review:(.+)$")
			if review_id then
				local record=record_by_id(state,review_id)
				if record then state.page="agents";state.provider_filter=record.provider;state.label_filter=record.account_label;state.editing=nil end
				return
			end
			local enable_id=op:match("^managed%-enable:(.+)$")
			if enable_id then
				local binding=state.binding
				verify(state,cx,function(session,why)
					if not session or state.binding~=binding or not reload(state) then state.notice=why or "Agent settings changed";return end
					if state.snapshot.config_revision~=expected then state.notice="Settings changed. Review the agent again before enabling.";return end
					local record,index=record_by_id(state,enable_id)
					if not record or record.enabled then state.notice="Select the current saved agent before enabling.";return end
					local records=Authority.clone(state.config.agents);records[index].enabled=true
					local saved,problem=Authority.edit(binding,expected,"replace-records",{records=records})
					if not saved or not reload(state) then state.notice=problem or "Could not read back the enabled agent";return end
					state.managed_existing=enable_id;state.managed_draft=ManagedSetup.from_record(record_by_id(state,enable_id),state.default_cwd);state.managed_draft_revision=state.snapshot.config_revision
					state.managed_probe=nil;state.managed_record=nil;state.managed_route=nil;state.notice="Agent enabled. Review its settings before preparing; no agent has started."
				end);return
			end
			if op=="managed-edit-one" then
				if state.managed_batch and state.managed_batch.status~="completed" and state.managed_batch.status~="failed" then state.notice="Wait for the current setup.";return end
				state.managed_edit_one=true
				local record=state.config.agents[1]
				if record then
					state.managed_existing=record.id;state.managed_draft=ManagedSetup.from_record(record,state.default_cwd);state.managed_draft_revision=expected
					state.managed_draft_touched=true
				end
				return
			end
			if op=="managed-prepare-missing" then
				-- Reuse valid preparation: only enabled agents without verified preparation.
				local missing=unprepared_ids(state)
				if #missing==0 then state.notice="Every saved agent is already prepared for ORCH+; nothing to do.";return end
				managed_batch_offer(state,cx,expected,true,nil,missing);return
			end
			if op=="managed-prepare" or op=="managed-prepare-all" then managed_batch_offer(state,cx,expected,op=="managed-prepare-all");return end
			if op=="terminal-capability-check" then
				if state.snapshot.host_os~="macos" or state.terminal_capability_busy then return end
				state.terminal_capability_busy=true
				Prereq.terminal_continuation(function(available,summary)
					state.terminal_capability_busy=nil
					if state.closed then return end
					state.terminal_capability={available=available,summary=summary}
					cx:render()
				end)
				return
			end
			if op=="managed-exercise" then publish_intent(state,cx,"readiness",expected);return end
			if op=="managed-route-probe" then
				if state.managed_busy then state.notice="A prerequisite probe is already running";return end
				if state.managed_route then state.notice="This diagnostic already ran or is running. Create a fresh resource probe before another launch.";return end
				if state.managed_route_consent and tern.now()<=state.managed_route_consent.deadline then state.notice="Waiting for the window you clicked; no second diagnostic was requested.";return end
				if not state.managed_probe or not state.managed_probe.passed or state.managed_probe_revision~=expected then state.notice="Complete this revision's resource prerequisites first";return end
				local nonce=string.format("route-%d-%08x-%08x-%08x",os.time(),math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647))
				state.managed_route_consent={nonce=nonce,revision=expected,deadline=tern.now()+30000}
				state.notice="Opening the diagnostic in the window you clicked."
				-- Must remain synchronous in the native button event: no window-key
				-- override, asynchronous broadcast, or remote-connection guessing.
				local opened,why=pcall(function()cx:open("tern-spawn://managed-route/"..string.format("%.0f",cx.pane).."/"..tostring(expected).."/"..nonce)end)
				if not opened then state.managed_route_consent=nil;state.notice="Could not reach the clicked window: "..tostring(why) end
				return
			end
			if op=="managed-dismiss" or op=="managed-probe" then
				if state.managed_busy then state.notice="A prerequisite probe is already running";return end
				local binding=state.binding
				verify(state,cx,function(session,why)
					if not session or state.binding~=binding or not reload(state) then state.notice=why or "Setup origin changed";return end
					if expected~=state.snapshot.config_revision then state.notice="stale-config: review refreshed setup before repeating";return end
					if op=="managed-probe" then
						local selected,selection_error=managed_candidates(state,false)
						if not selected then state.notice=selection_error;return end
						local pending,pending_error=Authority.setup_probe_read(state.host_key)
						if pending or pending_error then state.notice=pending_error or "The previous native diagnostic still requires observed cleanup; no new resources or worker were created";return end
						managed_draft(state)
						if state.managed_draft_revision~=expected then state.notice="stale-config: reselect the current record before probing; old drafts cannot overwrite manual changes";return end
						if not state.managed_existing and record_by_id(state,managed_draft(state).id) then state.notice="That ID already exists. Select Review existing record; creation never overwrites a saved record.";return end
						local draft=Authority.clone(managed_draft(state));state.managed_busy=true;state.managed_probe=nil;state.managed_route=nil
						ManagedSetup.prepare(draft,{host_os=state.snapshot.host_os,host_shell=state.snapshot.host_shell},function(record,probe,err)
							state.managed_busy=nil
							if state.closed then return end
							if not reload(state) or state.snapshot.config_revision~=expected or not Dispatch.protocol.equal(draft,managed_draft(state)) then state.notice="Setup changed during probe; resources preserved. Probe the current draft again.";cx:render();return end
							if record and probe and probe.passed and (state.snapshot.setup.state=="not_started" or state.snapshot.setup.state=="dismissed") then
								local begun,begin_error=Authority.setup_edit(state.host_key,expected,"begin",{})
								if not begun or not reload(state) then state.notice=begin_error or "Could not begin setup";cx:render();return end
								expected=state.snapshot.config_revision;state.managed_draft_revision=expected
							end
							state.managed_record=record;state.managed_probe=probe;state.managed_probe_revision=expected
							state.notice=err or (if probe and probe.passed then "Resources verified. Verify and save checks the native launch route; provider readiness remains separate." else "Preparation failed. Resolve the reported problem before trying again.")
							cx:render()
						end)
						return
					end
					local ok,err=Authority.setup_edit(state.host_key,expected,"dismiss",{})
					reload(state);state.notice=if ok then "Setup dismissed. Saved agents and resources are unchanged." else err
					if ok then
						state.managed_probe=nil;state.managed_record=nil
						if state.managed_draft_revision==expected then state.managed_draft_revision=state.snapshot.config_revision end
					end
				end);return
			end
			if op=="review-confirm" then mutate(state,cx,expected,"review-confirm",{});return end
			local recovery_attempt=op:match("^manual%-recover:(.+)$")
			if recovery_attempt then
				local binding=state.binding
				verify(state,cx,function(session,why)
					if not session or state.binding~=binding or not state.advanced or not reload(state) then state.notice=why or "Manual recovery Config changed; open Advanced and review again";return end
					if state.snapshot.config_revision~=expected then state.notice="stale-config: review refreshed setup before recovery";return end
					local pending,problem=Authority.setup_pending(binding,recovery_attempt)
					if not pending or pending.consumed or type(pending.bytes)~="string" then state.notice=problem or "No unconsumed immutable setup result remains";return end
					state.import_text=pending.bytes;state.editing=nil;state.focus=nil
					prepare_manual_review(state,expected)
					if state.import_review then
						state.import_review.attempt_id=recovery_attempt
						state.import_review.pending_digest=pending.digest
					end
				end)
				return
			end
			if op=="manual-review" then
				prepare_manual_review(state,expected);return
			elseif op=="manual-confirm" then
				local review=state.import_review;if not review then state.notice="Review pasted JSON first";return end
				local binding=state.binding
				verify(state,cx,function(session,err)
					if not session then state.notice=err;return end
					if state.binding~=binding or state.import_review~=review or state.import_text~=review.bytes or not state.advanced then state.notice="stale-authority: review the pasted JSON again before importing";return end
					if not reload(state) then return end
					local observer="config-"..tostring(cx.pane);local seq=(state.snapshot.request_sequences[observer] or 0)+1;local acks={}
					if not review.run then review.run=state.binding.authority_id.."/manual/"..observer.."/"..tostring(seq) end
					for id,reply in pairs(state.snapshot.replies) do if reply.observer_id==observer then table.insert(acks,id) end end
					local data={setup_run_id=review.run,manual=true,confirmed=true}
					if review.attempt_id then
						data.attempt_id=review.attempt_id;data.pending_digest=review.pending_digest
					else data.records=review.records end
					local request={version=2,request_id=observer..":"..tostring(seq),authority_id=state.binding.authority_id,observer_id=observer,request_sequence=seq,acknowledged_requests=acks,expected_config_revision=review.revision,op="import_records",data=data}
					local ok,why=Authority.request(state.binding,request,{config_pane=cx.pane,window=state.native_window,host_window=state.host_window,inventory=state.inventory,epoch=Executor.epoch()})
					reload(state)
					local reply=state.snapshot and state.snapshot.replies[request.request_id]
					if ok and reply and reply.ok then state.import_review=nil;state.import_text="";state.notice="Imported "..tostring(reply.result.imported).." records. Manual recovery does not prove original automatic-source provenance. No agents were launched."
					else state.notice=why or (reply and reply.error) or "Import was not acknowledged; refresh and review transport" end
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
				table.insert(records,{id=id,provider=if op=="add-ssh" then "SSH agent" else "Local agent",account_label="Default",backend=if op=="add-ssh" then "ssh-command" else "local-terminal",enabled=true,placement="tab",arguments={},review_required=true,review_reason="Review this account's launch command and routing"})
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
			if op=="launch-setup" then
				if setup_active(state) then state.notice="Guided setup is already active. Review its result or finish the original helper first.";return end
				for _,intent in ipairs(state.intents or {}) do if intent.kind=="setup" then state.notice="Guided setup is already queued; no second helper was requested.";return end end
				state.setup_topology=state.setup_topology or {mode="single"}
				state.notice="Choose your device setup, then press Start Guided setup. No helper has started.";return
			end
			if op=="setup-find-devices" then
				if setup_active(state) then state.notice="Finish the current setup before finding devices again.";return end
				for _,intent in ipairs(state.intents or {}) do if intent.kind=="setup" then state.notice="Execution-machine selection is already queued.";return end end
				if not state.setup_topology then state.notice="Choose Single or Multi Device Setup first.";return end
				if state.setup_topology.mode~="multi" then state.notice="Single device uses this execution machine. Choose Multi device to find others.";return end
				if state.setup_topology.request then return end
				state.setup_topology.request={nonce=string.format("devices-%d-%08x",os.time(),math.random(1,2147483647))}
				state.setup_topology.observation=nil;state.setup_topology.selected=nil;state.setup_topology.error=nil
				return
			end
			if op=="setup-start-helper" then
				if setup_active(state) then state.notice="Finish the original setup helper first.";return end
				for _,intent in ipairs(state.intents or {}) do if intent.kind=="setup" then state.notice="Guided setup is already queued.";return end end
				local topology=state.setup_topology
				-- Single device: the window resolves the current execution machine itself.
				-- Multi device still needs an observed, connected primary machine.
				if not (topology and topology.mode=="single" and topology.observation==nil) then
					local device,why=SetupDiscovery.primary(if topology then topology.observation else nil,if topology then topology.selected else nil,if topology then topology.mode else nil)
					if not device then state.notice=why;return end
				end
				publish_intent(state,cx,"setup",expected);return
			end
			local discard_id=op:match("^discard%-setup:(.+)$")
			if discard_id then
				for _,job in ipairs(state.snapshot.jobs or {}) do
					if job.attempt_id==discard_id and job.setup and job.pending_bytes and job.pending_bytes>0 and not job.setup_consumed then publish_intent(state,cx,"discard",expected,discard_id);return end
				end
				state.notice="No matching unconsumed setup result remains; refresh before discarding.";return
			end
			if op=="launch-result" then publish_intent(state,cx,"result",expected);return end
			local launch_id=op:match("^launch:(.+)$")
			if launch_id then
				if not record_by_id(state,launch_id) then reload(state);state.notice="That saved agent no longer exists; review the refreshed list";return end
				publish_intent(state,cx,"record",expected,launch_id);return
			end
			if op=="reset-roster" or op=="clear-history" or op=="reset-transport" or op:match("^review%-reply:") then
				if state.armed~=op then state.armed=op;state.armed_attempt_revision=state.snapshot.attempt_revision;state.notice="Inspect the displayed state, then click the confirmation again.";return end
				state.armed=nil
				if op=="reset-roster" then mutate(state,cx,expected,"replace-records",{records={}})
				elseif op:match("^review%-reply:") then mutate(state,cx,expected,"review-reply",{id=op:sub(14)})
				else mutate(state,cx,expected,op,{attempt_revision=state.armed_attempt_revision}) end
			end
		end
	end,
	key=function(state,key,cx)
		local pasted=if key.name=="paste" and type(key.text)=="string" and #key.text<=4096 then Config.decode_setup_json(key.text) else nil
		if (type(pasted)=="table" and pasted.kind=="spawn-setup-result") or (pasted==nil and key.name=="paste" and type(key.text)=="string" and key.text:find('"kind"%s*:%s*"spawn%-setup%-result"')) then
			if #key.text>4096 then state.notice="Setup submission envelope exceeds 4096 bytes";cx:render();return true end
			local envelope,why=Config.decode_setup_json(key.text)
			if type(envelope)~="table" or envelope.kind~="spawn-setup-result" then state.notice=why or "Invalid setup submission envelope";cx:render();return true end
			local binding,window=state.binding,state.native_window
			verify(state,cx,function(session,err)
				if not session or not binding or state.binding~=binding or state.native_window~=window or not reload(state) then state.notice=err or "Setup submission Config source changed";return end
				local accepted,problem=Authority.setup_submission(binding,envelope,{config_pane=cx.pane,window=window,host_window=state.host_window,inventory=state.inventory,epoch=Executor.epoch()})
				if not reload(state) then return end
				if accepted then
					for _,job in ipairs(state.snapshot.jobs) do
						if job.setup_run_id==envelope.setup_run_id and setup_job(state,cx,job.attempt_id) then state.setup_result_attempt=job.attempt_id end
					end
					state.notice="Setup result accepted. Review the submitted records, then explicitly import them; no agents were launched."
				else state.notice=problem or "Setup submission refused; no records imported" end
			end)
			return true
		end
		local editing=state.editing;if type(editing)~="table" then return false end
		if key.name=="escape" then state.editing=nil;state.focus=nil;return true end
		if type(editing.draft)~="string" then return false end
		if key.name=="enter" then
			if editing.row=="agents-filter-label" then state.label_filter=editing.draft
			elseif editing.row=="manual-json" then state.import_text=editing.draft;state.import_review=nil
			elseif editing.row:match("^managed:") then managed_change(state,editing.row:sub(9),editing.draft)
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
	save=function(state)return {page=state.page,host_key=state.host_key,origin_session=state.origin_session,origin_scope=state.origin_scope,intents=state.intents,intent_queue_id=state.intent_queue_id} end,
}
tern.block.define("spawner",definition)

-- Enumerate the owning daemon's native client keys. Window aliases and names are
-- never used as native session identity. A final membership read fences scan drift.
local function bridge_membership(state,cx,callback,deadline,parked)
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
			table.insert(state.inspect_queue,{cx=cx,callback=callback,deadline=deadline,parked=parked})
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
		if queued then bridge_membership(state,queued.cx,queued.callback,queued.deadline,queued.parked) else cx:render() end
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
		local index=0;local memberships={};local owner=nil;local controller_memberships={};local controller_owner=nil
		local function scan()
			index+=1
			if index>#keys then
				local total=0;local native=nil
				for _,id in pairs(memberships) do total+=1;native=id end
				local parked_source=false
				if total==0 and parked and parked.valid() then
					for _,id in pairs(controller_memberships) do total+=1;native=id end
					if total==1 then owner=controller_owner;parked_source=true end
				end
				if total~=1 then finish(nil,"Authority membership is missing or ambiguous. Keep its original controller visible; unbound parked panes grant nothing.");return end
				inspect_step(owner,function(final,why)
					if not final then finish(nil,why);return end
					local current=pane_sessions(final,if parked_source then parked.pane else cx.pane)
					local n=0;if current then for _ in pairs(current) do n+=1 end end
					if not current or n~=1 or current[tostring(native)]~=native then finish(nil,"Host membership changed during inspection; review and refresh");return end
					if parked_source then
						local mounted=pane_sessions(final,cx.pane)
						if not parked.valid() or not mounted or next(mounted)~=nil then finish(nil,"Parked bridge ownership changed during inspection");return end
					end
					finish(native,nil,final)
				end)
				return
			end
			inspect_step(keys[index],function(inventory,why)
				if not inventory then finish(nil,why);return end
				local found=pane_sessions(inventory,cx.pane)
				if not found then finish(nil,"Corrupt native session identity");return end
				for k,id in pairs(found) do memberships[k]=id;owner=keys[index] end
				if parked then
					local controllers=pane_sessions(inventory,parked.pane)
					if not controllers then finish(nil,"Corrupt native controller identity");return end
					for k,id in pairs(controllers) do controller_memberships[k]=id;controller_owner=keys[index] end
				end
				scan()
			end)
		end
		scan()
	end)
end

-- Retained dispatch panes are honest recovery views only. Their original saved
-- correlation is preserved, never rebound to an ORCH relay or used for effects.
tern.block.define("dispatch",{
	font="sans",
	init=function(_cx,_args,saved)return {retained=saved}end,
	view=function()
		return {main=ui.col({ui.text("Retained SPAWN dispatch view — execution is disabled. Reconcile existing work through ORCH+ or SPAWN Advanced recovery; this pane grants no authority.")})}
	end,
	event=function()end,
	save=function(state)return state.retained end,
})
require("./dispatch_relay").install()

require("./updater/host").register()
