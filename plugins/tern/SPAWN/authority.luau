-- Host-only single writer. Admission is one atomic write; execution claims are explicit.
local Config = require("./config")
local Launch = require("./launch_state")
local Codec = require("./wire/codec")
local Backend = require("./backend")
local DispatchState = require("./dispatch_state")
local SetupDiscovery = require("./setup_discovery")
local M = {}
local MAX_BYTES = 120000
-- Pending submission bytes live once in the existing job, never in snapshots or
-- retained replies. The public channel keeps its original 120000-byte ceiling.
local MAX_SETUP_STORAGE_BYTES = 600000
local MAX_STORE_BYTES = MAX_BYTES + MAX_SETUP_STORAGE_BYTES
local MAX_SETUP_BYTES = 120000
local MAX_PENDING_BYTES = 240000
M.MAX_SETUP_BYTES = MAX_SETUP_BYTES
local STORAGE_VERSION = 4
local SNAPSHOT_PREFIX = "SPAWN_STATE_V2 "
local ADMISSION_SECONDS = 30
M.ADMISSION_SECONDS = ADMISSION_SECONDS
local KEEP_FINISHED = 26
-- After a daemon restart Tern restores panes and reruns agent commands only some
-- time after the host loads, so an attempt waits this long for re-adoption.
local RESTART_GRACE_SECONDS = 20
M.RESTART_GRACE_SECONDS = RESTART_GRACE_SECONDS
local MAX_INT = 9007199254740991

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = clone(item) end
	return result
end
M.clone = clone
local function equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end
local function integer(n, min)
	return type(n) == "number" and n >= min and n <= MAX_INT and n % 1 == 0
end
local function text(s, max)
	return type(s) == "string" and #s > 0 and #s <= max and not s:find("%c")
end
local function count(t)
	local n = 0
	for _ in pairs(t) do n += 1 end
	return n
end
local function fields(t, allowed)
	if type(t) ~= "table" then return false end
	for k in pairs(t) do if not allowed[k] then return false end end
	return true
end
local function array(t, max)
	if type(t) ~= "table" then return false end
	local n = count(t)
	if n > max then return false end
	for k in pairs(t) do if not integer(k, 1) or k > n then return false end end
	return true
end
local SETUP_STATES={not_started=true,in_progress=true,completed=true,dismissed=true,adopted_existing=true}
local READINESS_STATES={not_run=true,passed=true,failed=true,unavailable=true}
local function new_setup(revision,existing)
	return {schema=1,state=if existing then "in_progress" else "not_started",config_revision=revision,
		readiness={state="not_run",config_revision=revision,summary=""}}
end
local function readiness_valid(value,revision)
	return fields(value,{state=true,config_revision=true,summary=true}) and READINESS_STATES[value.state]==true
		and integer(value.config_revision,0) and value.config_revision<=revision
		and type(value.summary)=="string" and #value.summary<=1024 and not value.summary:find("%c")
end
local function setup_valid(value,revision)
	return fields(value,{schema=true,state=true,config_revision=true,readiness=true}) and value.schema==1
		and SETUP_STATES[value.state]==true and value.config_revision==revision and readiness_valid(value.readiness,revision)
end
local function encoded(value,limit)
	local ok, json = pcall(tern.json.encode, value)
	if not ok or #json > (limit or MAX_BYTES) then return nil, "capacity: encoded state exceeds its bounded size" end
	return json
end
local function attempt(scope, id)
	for _, a in ipairs(scope.launch.attempts) do if a.id == id then return a end end
	return nil
end
local function execution_observer(root) return root.namespace.."/executor" end
-- Missing or corrupt bridge evidence never grants a fresh authority.
local function managed_registry()
	local ok,registry=pcall(tern.kv.get,"dispatch-v1")
	if not ok then return nil,"Managed dispatch storage is unreadable; preserve it" end
	if registry==nil then
		local marked,marker=pcall(tern.kv.get,"dispatch-v1-initialized")
		if not marked or marker~=nil then return nil,"Managed dispatch registry is missing; restore it" end
		return false
	end
	local checked,valid,why=pcall(DispatchState.validate_registry,registry)
	if not checked or not valid then return nil,if checked then why else "Managed dispatch registry is invalid; preserve it" end
	for _,owner in pairs(if registry.version==2 then registry.sessions else registry.owners) do
		if not text(owner.authority,256) or not integer(owner.host_session,0) then return nil,"Managed session identity is invalid; preserve it" end
	end
	for _,entry in pairs(registry.requests) do
		for _,binding in ipairs({entry.binding or false,entry.authorization and entry.authorization.binding or false}) do
			if binding~=false and (type(binding)~="table" or not text(binding.session_key,2048) or not text(binding.authority_id,256) or not text(binding.host_key,1024) or not integer(binding.native_session,0)) then return nil,"Managed request authority binding is invalid; preserve it" end
		end
	end
	if registry.version==2 then
		for _,worker in pairs(registry.workers) do
			local b=worker.binding
			if b~=nil and (type(b)~="table" or not text(b.session_key,2048) or not text(b.authority_id,256) or not text(b.host_key,1024) or not integer(b.native_session,0)) then return nil,"Managed worker authority binding is invalid; preserve it" end
		end
	end
	return registry
end
local function unsettled(entry)
	local status=entry.body.status
	if entry.retirement_result~=nil or status=="pending" or status=="uncertain" or status=="claimed" or status=="launching" then return true end
	if status=="resolved" and (entry.request.op=="launch" or entry.request.op=="adopt" or entry.request.op=="enrol" or entry.request.op=="stop" or entry.request.op=="native_wake") then return true end
	local wake=entry.wake
	return wake~=nil and wake.phase~="submitted" and (wake.request_id~=nil or wake.phase~="resolved")
end
local function linked_launch(registry,entry)
	-- Native wake may reference a publication which in turn names its launch.
	-- Current workers outlive delivered launch results, without retaining requests.
	if registry.version==2 then
		local r=entry.request
		local launch_id=r.launch_request_id or r.target_request_id
		if r.op=="launch" or r.op=="adopt" or r.op=="enrol" then launch_id=r.request_id end
		local logical=r.logical_session_id
		local worker=launch_id and registry.workers[logical.."/"..launch_id]
		if worker then return worker end
	end
	for _=1,3 do
		if entry.request.op=="launch" or entry.request.op=="adopt" or entry.request.op=="enrol" then return entry end
		local r=entry.request
		local id=r.launch_request_id or r.target_request_id
		if not id then return nil end
		local key=(r.logical_session_id or r.origin_binding.logical_session_id).."/"..id
		if registry.version==2 and registry.workers[key] then return registry.workers[key] end
		entry=registry.requests[key]
		if not entry then return nil end
	end
	return nil
end
local function settled_managed(registry,key,scope)
	local settled={}
	for id,job in pairs(scope.jobs) do
		if job.pending and not job.pending.consumed then settled[id]=false end
	end
	-- An unreadable registry cannot prove that a terminal attempt is disposable.
	if registry==nil then return settled end
	for _,a in ipairs(scope.launch.attempts) do
		if a.purpose=="managed" and a.phase=="Exited" and not a.unresolved then settled[a.id]=true end
	end
	if registry==false or next(settled)==nil then return settled end
	local function protect(launch)
		-- Binding is persisted before reservation; an unbound launch owns no attempt.
		if launch and launch.binding and launch.binding.session_key==key then
			if launch.attempt_id then settled[launch.attempt_id]=nil
			else
				for _,a in ipairs(scope.launch.attempts) do if a.observer_id==launch.observer_id then settled[a.id]=nil end end
			end
		end
	end
	if registry.version==2 then
		for _,worker in pairs(registry.workers) do protect(worker) end
	end
	for _,entry in pairs(registry.requests) do
		if registry.version==2 or unsettled(entry) then
			protect(linked_launch(registry,entry))
		end
	end
	for _,generation in pairs(registry.mailboxes.generations) do
		if generation.status~="retired" or generation.active~=nil then
			local b=generation.binding
			local worker_key=b.logical_session_id.."/"..b.launch_request_id
			protect(if registry.version==2 then registry.workers[worker_key] else registry.requests[worker_key])
		end
	end
	return settled
end
local function managed_references(registry,key,scope,reset)
	if registry==false then return false end
	local identity=scope.managed_authority_id or scope.authority_id
	for _,owner in pairs(if registry.version==2 then registry.sessions else registry.owners) do
		if owner.authority==identity and owner.host_session==scope.native_session then return true end
	end
	if registry.version==2 then
		for _,worker in pairs(registry.workers) do
			if worker.binding and worker.binding.session_key==key then return true end
		end
	end
	for _,entry in pairs(registry.requests) do
		local live=registry.version==2 or unsettled(entry)
		local launch=if live then linked_launch(registry,entry) else nil
		if live and (entry.binding and entry.binding.session_key==key or launch and launch.binding and launch.binding.session_key==key) then return true end
		local a=entry.authorization
		if a and a.binding.session_key==key and (reset and a.phase=="consumed" or not reset and live) then return true end
	end
	for _,gate in pairs(registry.gates) do
		if gate.binding.session_key==key and (not gate.consumed or not gate.outcome or gate.outcome.status=="uncertain") then return true end
	end
	for _,generation in pairs(registry.mailboxes.generations) do
		if generation.status~="retired" then
			local logical=generation.binding.logical_session_id
			local associated=false
			local owner=(if registry.version==2 then registry.sessions else registry.owners)[logical]
			if owner then
				associated=true
				if owner.authority==identity and owner.host_session==scope.native_session then return true end
			end
			for _,retired in ipairs(if registry.version==2 then {} else registry.tombstones) do
				if retired.binding.logical_session_id==logical then
					associated=true
					if retired.authority==identity and retired.host_session==scope.native_session then return true end
				end
			end
			-- Orphan live evidence cannot safely be assigned to a different scope.
			if not associated then return true end
		end
	end
	return false
end
-- Admission fixes only display/placement fields; the approved record is read
-- from current configuration at claim/submit and fenced by config_revision.
local DISPLAY={"provider","account_label","backend","placement","cwd"}
local function display(record,purpose)
	return {provider=record.provider,account_label=record.account_label,backend=record.backend,
		placement=if purpose=="setup" then "tab" else record.placement,
		cwd=if record.backend~="ssh-command" and type(record.cwd)=="string" and record.cwd:find("%S") then record.cwd else "~"}
end
local SETUP_PUBLIC={"command","cwd","window","config_pane","host_config_pane","result_path","binding","host_key","authority_id","request_sequence","native_session","agent_pane","config_dir"}
local function public_setup(setup)
	if setup==nil then return nil end
	local value={}
	for _,name in ipairs(SETUP_PUBLIC) do value[name]=setup[name] end
	return value
end
local function public_job(job)
	local value={
		id=job.id,attempt_id=job.attempt_id,record_id=job.record_id,purpose=job.purpose,
		config_revision=job.config_revision,observer_id=job.observer_id,session_key=job.session_key,
		native_session=job.native_session,token=job.token,ticket=job.ticket,stage=job.stage,
		provider=job.provider,account_label=job.account_label,backend=job.backend,placement=job.placement,cwd=job.cwd,
		pane_reused=job.pane_reused,setup_run_id=job.setup_run_id,initial_prompt=job.initial_prompt,
		setup=public_setup(job.setup),
		pending_bytes=if job.pending then job.pending.length else nil,
		pending_digest=if job.pending then job.pending.digest else nil,
		setup_consumed=if job.pending then job.pending.consumed else nil,
		setup_discarded=if job.pending then job.pending.discarded else nil,
	}
	if job.native then
		value.native_pane=job.native.pane;value.native_window=job.native.window_key
		value.shell_program=job.native.program;value.native_tab=job.native_tab
	end
	return value
end
local function public_jobs(scope)
	local result={}
	for _,a in ipairs(scope.launch.attempts) do if a.purpose~="managed" then table.insert(result,public_job(scope.jobs[a.id])) end end
	return result
end
local function bounded(value,maximum)
	return type(value)=="string" and #value>0 and #value<=maximum and not value:find("%z")
end
-- One live cleanup obligation, not a history or permission to replay execution.
local function setup_probe_valid(route,revision)
	if not fields(route,{schema=true,nonce=true,config_revision=true,window=true,native_session=true,source_pane=true,native_conn=true,native_since=true,native_namespace=true,window_pane=true,window_consent=true,
		backend=true,command=true,cwd=true,record_id=true,record_sha256=true,expected_arguments=true,prompt=true,output=true,
		expected=true,worker_identity=true,user=true,host_os=true,status=true,pane=true,authority_id=true,origin_epoch=true}) or route.schema~=1
		or not text(route.nonce,256) or not integer(route.config_revision,0) or route.config_revision>revision
		or not text(route.authority_id,256) or route.origin_epoch~=nil and not text(route.origin_epoch,256)
		or type(route.window)~="string" or #route.window>256 or route.window:find("%c")
		or not integer(route.native_conn,0) or not integer(route.native_since,0)
		or route.native_namespace~=nil and not text(route.native_namespace,96)
		or route.window_consent~=nil and not text(route.window_consent,256)
		or route.record_id~=nil and not text(route.record_id,96)
		or route.window_pane~=nil and not integer(route.window_pane,1)
		or not integer(route.native_session,0) or not integer(route.source_pane,1)
		or not bounded(route.command,64000) or not text(route.cwd,8192)
		or type(route.record_sha256)~="string" or #route.record_sha256~=64 or not route.record_sha256:match("^[0-9a-f]+$")
		or not text(route.worker_identity,4096) or route.user~=nil and not text(route.user,4096)
		or route.host_os~="linux" and route.host_os~="macos" and route.host_os~="windows"
		or route.status~="running" or route.pane~=nil and not integer(route.pane,1) then return false end
	if route.backend=="native-agent" then
		if not bounded(route.prompt,8192) or not array(route.expected_arguments,264) or route.output~=nil or route.expected~=nil then return false end
		for _,word in ipairs(route.expected_arguments) do
			if type(word)~="string" or #word>32000 or word:find("%z") then return false end
		end
		return true
	end
	return route.backend=="local-terminal" and text(route.output,8192) and bounded(route.expected,8192)
		and route.prompt==nil and route.expected_arguments==nil
end
local function native_valid(value)
	return fields(value,{pane=true,window_key=true,program=true,executable=true,socket=true})
		and integer(value.pane,1) and type(value.window_key)=="string" and #value.window_key<=256 and not value.window_key:find("%c")
		and text(value.program,8192) and text(value.executable,8192) and text(value.socket,8192)
		and (value.executable:sub(1,1)=="/" or value.executable:match("^%a:[/\\]")~=nil or value.executable:sub(1,2)=="\\\\")
end
local function job_valid(root,key,scope,job,a)
	if not fields(job,{id=true,attempt_id=true,record_id=true,purpose=true,config_revision=true,observer_id=true,
		session_key=true,native_session=true,token=true,ticket=true,stage=true,admitted_at=true,
		provider=true,account_label=true,backend=true,placement=true,cwd=true,
		pane_reused=true,setup_run_id=true,initial_prompt=true,native=true,native_tab=true,epoch=true,process_identity=true,command=true,restart_grace=true,restart_grace_at=true,setup=true,pending=true}) then
		return false
	end
	if job.id~=a.id or job.attempt_id~=a.id or job.record_id~=a.record_id
		or job.session_key~=key or job.native_session~=scope.native_session
		or a.observer_id~=execution_observer(root) or not integer(job.admitted_at,0)
		or job.token~=key..":"..job.id or not integer(job.config_revision,0) or job.config_revision>root.config_revision then return false end
	if (a.purpose or "launch")~=job.purpose then return false end
	if Launch.validate_execution_projection(public_job(job))==nil then return false end
	local mode=if job.backend=="setup-default" then "Setup default" elseif job.backend=="native-agent" then "Native OMP" elseif job.backend=="ssh-command" then "SSH terminal" else "Terminal"
	if a.mode~=mode then return false end
	if job.backend=="setup-default" then
		local s=job.setup
		local allowed={native_conn=true,native_since=true,origin_epoch=true,before_panes=true}
		for _,name in ipairs(SETUP_PUBLIC) do allowed[name]=true end
		if not fields(s,allowed) or not Launch.validate_setup_projection(public_setup(s))
			or s.host_key~=root.host_key or s.native_session~=scope.native_session
			or not integer(s.native_conn,0) or not integer(s.native_since,0)
			or s.origin_epoch~=nil and not text(s.origin_epoch,4096)
			or s.before_panes~=nil and not array(s.before_panes,4096) then return false end
		if #s.binding~=64 or not s.binding:match("^[0-9a-f]+$")
			or s.result_path:sub(-(#s.binding+18))~="setup-result-"..s.binding..".json" then return false end
		local prefix=root.namespace..":"
		local generation=tonumber(s.authority_id:sub(#prefix+1))
		if s.authority_id:sub(1,#prefix)~=prefix or not integer(generation,1) or generation>=root.next_authority then return false end
		if s.before_panes then
			local seen={};for _,pane in ipairs(s.before_panes) do if not integer(pane,1) or seen[pane] then return false end;seen[pane]=true end
		end
		if job.native~=nil then
			if not fields(job.native,{pane=true,window_key=true}) or not integer(job.native.pane,1)
				or job.native.window_key~=s.window or a.pane~=job.native.pane or not integer(s.agent_pane,1) then return false end
		elseif a.pane~=nil or s.agent_pane~=nil then return false end
		if job.pending~=nil then
			local p=job.pending
			if not fields(p,{bytes=true,length=true,digest=true,consumed=true,discarded=true}) or not integer(p.length,1) or p.length>MAX_SETUP_BYTES
				or type(p.digest)~="string" or #p.digest~=64 or not p.digest:match("^[0-9a-f]+$")
				or type(p.consumed)~="boolean" then return false end
			if p.discarded~=nil and (p.discarded~=true or not p.consumed) then return false end
			if p.consumed then if p.bytes~=nil then return false end
			elseif not bounded(p.bytes,MAX_SETUP_BYTES) or #p.bytes~=p.length or Codec.sha256(p.bytes)~=p.digest then return false
			else
				local decoded=Config.decode_setup_json(p.bytes)
				if not decoded or require("./setup_review").prepare(decoded,job.setup_run_id)==nil then return false end
			end
			if job.native==nil then return false end
		end
		if job.native_tab~=nil or job.epoch~=nil or job.process_identity~=nil or job.command~=nil or job.restart_grace~=nil or job.restart_grace_at~=nil then return false end
		local stage=job.stage
		if stage=="admitted" or stage=="claimed" then return a.phase=="Starting" and job.native==nil and s.before_panes==nil and not job.pane_reused end
		if stage=="submission_intent" then return a.phase=="Starting" and job.native==nil and s.before_panes~=nil and not job.pane_reused end
		if stage=="submitted" or stage=="running" then return a.phase=="Running" and job.native~=nil and s.before_panes~=nil and not job.pane_reused end
		if stage=="failed" then return a.phase=="Failed" and job.native==nil end
		if stage=="unknown" then return a.phase=="Unknown" and a.unresolved end
		if stage=="resolved" then return a.phase=="Exited" and not a.unresolved and job.native~=nil end
		return false
	elseif job.setup~=nil or job.pending~=nil then return false end
	if job.native~=nil then
		if not native_valid(job.native) or a.pane~=job.native.pane then return false end
	elseif a.pane~=nil or job.native_tab~=nil or job.epoch~=nil or job.process_identity~=nil or job.command~=nil or job.restart_grace~=nil then return false end
	if job.epoch~=nil and not text(job.epoch,4096) then return false end
	if job.process_identity~=nil and not text(job.process_identity,4096) then return false end
	if job.restart_grace~=nil and not text(job.restart_grace,4096) then return false end
	if job.restart_grace_at~=nil and (job.restart_grace==nil or not integer(job.restart_grace_at,0)) then return false end
	if job.command~=nil and not bounded(job.command,64000) then return false end
	local stage=job.stage
	if stage=="admitted" then return a.phase=="Starting" and job.native==nil and not job.pane_reused end
	if stage=="claimed" then return a.phase=="Starting" and job.native~=nil and job.command==nil end
	if stage=="submission_intent" or stage=="submitted" then return a.phase=="Starting" and job.native~=nil and job.command~=nil end
	if stage=="running" then return (a.phase=="Running" or a.phase=="Waiting for input") and job.native~=nil and job.command~=nil end
	if stage=="completed" then return (a.phase=="Exited" or a.phase=="Failed") and job.native~=nil and job.command~=nil end
	if stage=="failed" then return a.phase=="Failed" end
	if stage=="unknown" then return a.phase=="Unknown" and a.unresolved end
	-- Settled without provider completion evidence: SPAWN ended it (pane closed,
	-- host restarted) or, in older stores, an operator released an Unknown.
	if stage=="resolved" then return not a.unresolved and (a.phase=="Exited" and job.native~=nil or a.phase=="Unknown") end
	return false
end
local OPS = {
	refresh={},import_records={setup_run_id=true,records=true,manual=true,attempt_id=true,pending_digest=true,confirmed=true,preparation=true},
	discard_setup_result={setup_run_id=true,attempt_id=true,pending_digest=true,confirmed=true},
	launch_record={record_id=true},start_setup={setup_run_id=true,command=true,cwd=true,window=true,config_pane=true},
	setup_claim={attempt_id=true,setup_run_id=true},setup_begin={attempt_id=true,setup_run_id=true},
	setup_bind={attempt_id=true,setup_run_id=true,pane=true},setup_uncertain={attempt_id=true,setup_run_id=true},
}
-- Upgrade boundary: manual release was removed because ordinary attempts settle
-- themselves. A request with a removed op is acknowledged, never executed.
local OBSOLETE = {resolve_attempt = {attempt_id=true,attempt_revision=true}, resolve_lost_attempts = {attempt_ids=true,attempt_revision=true}}
local OBSOLETE_RESULT = {obsolete=true, notice="An old Mark-no-longer-running request was cleared; SPAWN now does this automatically"}
local function preparation_valid(value)
	if not fields(value,{nonce=true,revision=true,entries=true,consents=true,window=true,native_namespace=true,native_conn=true,native_since=true})
		or not text(value.nonce,240) or value.nonce:find("[^%w%-]") or not integer(value.revision,0)
		or type(value.window)~="string" or #value.window>256 or value.window:find("%c")
		or not text(value.native_namespace,96) or not integer(value.native_conn,0) or not integer(value.native_since,0)
		or not array(value.entries,32) or #value.entries==0 or not array(value.consents,32) or #value.consents~=#value.entries then return false end
	local ids,tokens={},{}
	for index,entry in ipairs(value.entries) do
		local consent=value.consents[index]
		if not fields(entry,{nonce=true,record_id=true,label=true,backend=true,revision=true}) or entry.nonce~=value.nonce.."-"..tostring(index)
			or not text(entry.record_id,96) or ids[entry.record_id] or not text(entry.label,1024) or not integer(entry.revision,0)
			or entry.backend~="native-agent" and entry.backend~="local-terminal"
			or not fields(consent,{nonce=true,window_consent=true}) or consent.nonce~=entry.nonce or not text(consent.window_consent,256) or tokens[consent.window_consent] then return false end
		ids[entry.record_id]=true;tokens[consent.window_consent]=true
	end
	return true
end
local function request_valid(r)
	if not fields(r, {version=true,request_id=true,authority_id=true,observer_id=true,request_sequence=true,acknowledged_requests=true,expected_config_revision=true,op=true,data=true}) or r.version ~= 2 then return false end
	if not text(r.request_id, 256) or not text(r.authority_id, 256) or not text(r.observer_id, 256) or not integer(r.request_sequence, 1) or not integer(r.expected_config_revision, 0) then return false end
	local allowed = if type(r.op) == "string" then OPS[r.op] or OBSOLETE[r.op] else nil
	if not array(r.acknowledged_requests, 64) or allowed == nil or not fields(r.data, allowed) then return false end
	local seen = {}
	for _, id in ipairs(r.acknowledged_requests) do
		if not text(id,256) or seen[id] then return false end
		seen[id]=true
	end
	local d = r.data
	if r.op == "import_records" then
		if not text(d.setup_run_id,256) or d.confirmed~=true then return false end
		if d.preparation~=nil and (d.manual~=nil or not preparation_valid(d.preparation)) then return false end
		if d.manual==true and d.records~=nil then
			return d.attempt_id==nil and d.pending_digest==nil and Config.validate_records(d.records)~=nil
		end
		return (d.manual==nil or d.manual==true) and d.records==nil and text(d.attempt_id,96)
			and type(d.pending_digest)=="string" and #d.pending_digest==64 and d.pending_digest:match("^[0-9a-f]+$")~=nil
	end
	if r.op=="discard_setup_result" then return d.confirmed==true and text(d.setup_run_id,256) and text(d.attempt_id,96) and type(d.pending_digest)=="string" and #d.pending_digest==64 and d.pending_digest:match("^[0-9a-f]+$")~=nil end
	if r.op == "launch_record" then return text(d.record_id,96) end
	if r.op == "start_setup" then
		return text(d.setup_run_id,256) and bounded(d.command,32000) and d.command:find("%S")~=nil
			and text(d.cwd,8192) and type(d.window)=="string" and #d.window<=256 and not d.window:find("%c") and integer(d.config_pane,1)
	end
	if r.op:sub(1,6)=="setup_" then return text(d.attempt_id,96) and text(d.setup_run_id,256) and (r.op~="setup_bind" or integer(d.pane,1)) end
	return true
end
local function result_valid(reply,request,key,native_session)
	if OBSOLETE[request.op] then return reply.ok==true and reply.error==nil and equal(reply.result,OBSOLETE_RESULT) end
	if not reply.ok then return type(reply.error)=="string" and #reply.error>0 and #reply.error<=4096 and reply.result==nil end
	if reply.error~=nil then return false end
	local result=reply.result
	if request.op=="refresh" then return fields(result,{}) end
	if request.op=="import_records" then return fields(result,{imported=true,replayed=true}) and integer(result.imported,0) and result.imported<=32 and (result.replayed==nil or type(result.replayed)=="boolean") end
	if request.op=="discard_setup_result" then return fields(result,{discarded=true}) and result.discarded==true end
	if request.op:sub(1,6)=="setup_" then
		local job=if fields(result,{job=true}) then Launch.validate_execution_projection(result.job) else nil
		local stage=if request.op=="setup_claim" then "claimed" elseif request.op=="setup_begin" then "submission_intent"
			elseif request.op=="setup_bind" then "submitted" else "unknown"
		return job~=nil and job.id==request.data.attempt_id and job.purpose=="setup" and job.backend=="setup-default"
			and job.setup_run_id==request.data.setup_run_id and job.session_key==key and job.native_session==native_session
			and job.observer_id==request.observer_id and job.setup.authority_id==request.authority_id
			and job.stage==stage and job.config_revision==request.expected_config_revision
			and (request.op~="setup_bind" or job.setup.agent_pane==request.data.pane and job.native_pane~=nil)
	end
	-- launch_record / start_setup
	if not fields(result,{attempt=true,job=true,replayed=true}) or type(result.attempt)~="table" then return false end
	local a=result.attempt
	local digits=if type(a.id)=="string" then a.id:match("^attempt%-(%d+)$") else nil
	local id=if digits then tonumber(digits) else nil
	if not integer(id,1) or a.scope~=key or Launch.validate({version=1,next_attempt=id+1,revision=reply.attempt_revision,attempts={a}})==nil then return false end
	local job=Launch.validate_execution_projection(result.job)
	if not job or job.id~=a.id or job.record_id~=(if request.op=="start_setup" then "setup-default" else request.data.record_id) or a.record_id~=job.record_id
		or job.observer_id~=request.observer_id or job.session_key~=key or job.native_session~=native_session
		or job.config_revision>reply.config_revision or job.token~=key..":"..job.id
		or (result.replayed~=nil and result.replayed~=true) then return false end
	if request.op=="start_setup" then
		local s=job.setup
		return job.purpose=="setup" and job.backend=="setup-default" and job.setup_run_id==request.data.setup_run_id
			and s.command==request.data.command and s.cwd==request.data.cwd and s.window==request.data.window
			and s.config_pane==request.data.config_pane and s.request_sequence==request.request_sequence
			and s.authority_id==request.authority_id and job.stage=="admitted"
	end
	return job.purpose=="launch"
end

-- Native begin reserves a complete maximum-size result before the effect.
-- Accepted bytes replace that reservation; terminal/uncertain inactive sources
-- cannot submit later. Metadata headroom decreases as each immutable field lands.
local function setup_capacity(job,a)
	if not job or job.backend~="setup-default" then return 0,0,0,0 end
	if job.pending then
		local metadata=if a.unresolved then (if job.pending.consumed then 256 else 512) else 0
		if job.pending.consumed then return metadata,0,0,0 end
		local size=#tern.json.encode(job.pending.bytes)
		return metadata,job.pending.length,size,size
	end
	if job.stage=="admitted" or job.stage=="claimed" then return 2048,0,0,0 end
	if job.stage=="submission_intent" then return 2048,MAX_SETUP_BYTES,MAX_SETUP_BYTES*2+2,0 end
	if job.stage=="submitted" or job.stage=="running" then return 1024,MAX_SETUP_BYTES,MAX_SETUP_BYTES*2+2,0 end
	return 0,0,0,0
end
local function source_records(raw,host_key,label)
	if raw==nil then return {} end
	local sources={}
	-- Mixed flat/host stores must be reviewed separately, not merged by last writer.
	if type(raw)=="table" and raw.schema==2 and raw.agents~=nil then
		local copy=clone(raw); copy.agents=nil
		local host,err=Config.migrate(copy,host_key)
		if not host then return nil,err end
		local flat,flat_err=Config.migrate({schema=1,agents=raw.agents},host_key)
		if not flat then return nil,flat_err end
		table.insert(sources,{label=label.." host",records=host.records})
		if not equal(host.records,flat.records) then table.insert(sources,{label=label.." original",records=flat.records}) end
	else
		local result,err=Config.migrate(raw,host_key)
		if not result then return nil,err end
		table.insert(sources,{label=label,records=result.records})
	end
	return sources
end
local function validate(root)
	if not fields(root,{version=true,namespace=true,next_authority=true,host_key=true,config=true,config_revision=true,sessions=true,review=true,reviewed_sources=true,setup=true,setup_adoption_required=true,setup_probe=true}) or root.version ~= STORAGE_VERSION then return nil,"Unsupported or corrupt authority storage format; expected version 4. Preserve it and use a compatible version" end
	if not text(root.namespace,128) or not text(root.host_key,1024) or not integer(root.next_authority,1) or not integer(root.config_revision,0) or type(root.sessions)~="table" or type(root.reviewed_sources)~="table" then return nil,"Corrupt authority identity" end
	if not setup_valid(root.setup,root.config_revision) or root.setup_adoption_required~=nil and (root.setup_adoption_required~=true or root.setup.state~="in_progress" and root.setup.state~="dismissed") then return nil,"Corrupt setup lifecycle or readiness" end
	if root.setup_probe~=nil then
		if not setup_probe_valid(root.setup_probe,root.config_revision) then return nil,"Corrupt unfinished setup probe; preserve it for native cleanup" end
		local prefix=root.namespace..":"
		local identity=root.setup_probe.authority_id
		local generation=tonumber(identity:sub(#prefix+1))
		if identity:sub(1,#prefix)~=prefix or not integer(generation,1) or generation>=root.next_authority then return nil,"Corrupt setup probe authority incarnation; preserve it for native cleanup" end
	end
	-- Stores written before duplicate_policy was retired still carry it on saved
	-- records; strip it so the roster stays canonical instead of unreadable.
	local bucket=if type(root.config)=="table" and type(root.config.hosts)=="table" then root.config.hosts[root.host_key] else nil
	if type(bucket)=="table" and type(bucket.agents)=="table" then
		for _,record in pairs(bucket.agents) do if type(record)=="table" then record.duplicate_policy=nil end end
	end
	local migrated, err = Config.migrate(root.config,root.host_key)
	if not migrated or migrated.changed then return nil,err or "Noncanonical authority configuration" end
	if count(root.sessions)>64 or count(root.reviewed_sources)>64 then return nil,"Authority capacity exhausted" end
	for id,source in pairs(root.reviewed_sources) do
		if not text(id,96) or not fields(source,{host_key=true,config=true}) or not text(source.host_key,1024) or type(source.config)~="table" or source_records(source.config,source.host_key,"Client copy")==nil then return nil,"Corrupt preserved source receipt" end
	end
	local authority_ids={}
	for key, scope in pairs(root.sessions) do
		if not text(key,2048) or not fields(scope,{authority_id=true,managed_authority_id=true,managed_imports=true,native_session=true,launch=true,jobs=true,setup_runs=true,inbox=true,replies=true,requests=true,request_sequences=true,imports=true}) or not text(scope.authority_id,256) then return nil,"Corrupt authority scope" end
		-- Legacy v3 keys are accepted and stripped on the next persist. A pending
		-- request from the retired two-step admission is never silently dropped.
		if scope.inbox~=nil and (type(scope.inbox)~="table" or next(scope.inbox)~=nil) then return nil,"Saved authority holds a pending request from an older SPAWN version; preserve it and process it with that version before upgrading" end
		scope.inbox=nil;scope.imports=nil;scope.setup_runs=nil
		if not integer(scope.native_session,0) or key~=root.namespace.."/session/"..tostring(scope.native_session) or authority_ids[scope.authority_id] then return nil,"Corrupt native scope identity" end
		local identity_prefix=root.namespace..":"
		local generation=tonumber(scope.authority_id:sub(#identity_prefix+1))
		if scope.authority_id:sub(1,#identity_prefix)~=identity_prefix or not integer(generation,1) or generation>=root.next_authority then return nil,"Corrupt authority generation" end
		scope.managed_authority_id=scope.managed_authority_id or scope.authority_id
		if type(scope.managed_authority_id)~="string" then return nil,"Corrupt managed scope identity" end
		local managed_generation=tonumber(scope.managed_authority_id:sub(#identity_prefix+1))
		if scope.managed_authority_id:sub(1,#identity_prefix)~=identity_prefix or not integer(managed_generation,1) or managed_generation>generation then return nil,"Corrupt managed scope identity" end
		scope.managed_imports=scope.managed_imports or {}
		if type(scope.managed_imports)~="table" or count(scope.managed_imports)>64 then return nil,"Managed import receipt capacity exhausted" end
		for id,receipt in pairs(scope.managed_imports) do
			-- Receipts are kept canonical so a replay compares equal after retired fields are stripped.
			local canonical=Config.validate_records(receipt)
			if not text(id,256) or canonical==nil then return nil,"Corrupt managed import receipt" end
			scope.managed_imports[id]=canonical
		end
		authority_ids[scope.authority_id]=true
		local valid, launch_err = Launch.validate(scope.launch)
		if not valid then return nil,launch_err end
		if type(scope.jobs)~="table" then return nil,"Execution job capacity mismatch" end
		local ordinary=0
		for _,a in ipairs(scope.launch.attempts) do
			local job=scope.jobs[a.id]
			if type(job)=="table" and job.record~=nil then
				-- Legacy jobs carried a full record copy; keep only its admission display fields.
				if job.provider==nil and type(job.record)=="table" then
					local shown=display(job.record,job.purpose)
					for _,name in ipairs(DISPLAY) do job[name]=shown[name] end
				end
				job.record=nil
			end
			if a.scope~=key then return nil,"Corrupt attempt scope" end
			if a.purpose=="managed" then
				if job~=nil or a.observer_id==execution_observer(root) then return nil,"Managed attempt cannot carry an ordinary execution job" end
			else
				ordinary+=1
				if a.purpose=="setup" and (type(job)~="table" or job.backend~="setup-default") then return nil,"Saved setup work belongs to the earlier Native OMP setup protocol; preserve it and settle/review it with that version before upgrading" end
				if not job_valid(root,key,scope,job,a) then return nil,"Corrupt execution job or attempt association" end
			end
		end
		if count(scope.jobs)~=ordinary then return nil,"Execution job capacity mismatch" end
		if type(scope.replies)~="table" or type(scope.requests)~="table" or type(scope.request_sequences)~="table" then return nil,"Corrupt authority transport" end
		if count(scope.replies)>64 or count(scope.request_sequences)>64 or count(scope.requests)~=count(scope.replies) then return nil,"Transport capacity or result mismatch" end
		for observer, seq in pairs(scope.request_sequences) do if not text(observer,256) or not integer(seq,1) then return nil,"Corrupt request watermark" end end
		for _,job in pairs(scope.jobs) do
			if job.setup and job.setup.authority_id==scope.authority_id and job.setup.request_sequence>(scope.request_sequences[job.observer_id] or 0) then return nil,"Setup admission exceeds its observer watermark" end
		end
		for id, reply in pairs(scope.replies) do
			local req=scope.requests[id]
			if type(req)=="table" and type(req.data)=="table"
				and (req.op=="start_setup" and req.data.record_id~=nil or req.op=="import_records" and req.data.confirmed~=true) then
				return nil,"Retained setup transport belongs to an older SPAWN protocol; preserve and review it with that version before upgrading"
			end
			-- A retained manual-release request from an older SPAWN is acknowledged
			-- as obsolete in place; its old outcome is never replayed.
			if type(req)=="table" and OBSOLETE[req.op]~=nil and type(reply)=="table" then reply.ok=true;reply.error=nil;reply.result=clone(OBSOLETE_RESULT) end
			if not request_valid(req) or req.authority_id~=scope.authority_id or req.request_id~=id or not fields(reply,{request_id=true,observer_id=true,request_sequence=true,ok=true,error=true,config_revision=true,attempt_revision=true,result=true}) or reply.request_id~=id or reply.observer_id~=req.observer_id or reply.request_sequence~=req.request_sequence or type(reply.ok)~="boolean" or not integer(reply.config_revision,0) or not integer(reply.attempt_revision,0) or (scope.request_sequences[reply.observer_id] or 0)<reply.request_sequence then return nil,"Corrupt retained result" end
			if reply.config_revision>root.config_revision or reply.attempt_revision>scope.launch.revision or not result_valid(reply,req,key,scope.native_session) then return nil,"Corrupt result payload" end
		end
	end
	if root.review ~= nil then
		if not fields(root.review,{sources=true,choices=true,reason=true}) or not array(root.review.sources,64) or type(root.review.choices)~="table" or type(root.review.reason)~="string" then return nil,"Corrupt migration review" end
		for _, source in ipairs(root.review.sources) do
			local canonical=if fields(source,{label=true,records=true}) and text(source.label,256) then Config.validate_records(source.records) else nil
			if canonical==nil then return nil,"Corrupt migration source" end
			source.records=canonical
		end
		local ids={}
		for _,source in ipairs(root.review.sources) do for _,record in ipairs(source.records) do ids[record.id]=true end end
		for id,choice in pairs(root.review.choices) do
			if not ids[id] or not integer(choice,0) or choice>#root.review.sources then return nil,"Corrupt migration selection" end
		end
	end
	local pending_bytes,setup_encoded,pending_encoded=0,0,0
	for _,scope in pairs(root.sessions) do for _,a in ipairs(scope.launch.attempts) do
		local _,raw,reserved,actual=setup_capacity(scope.jobs[a.id],a)
		pending_bytes+=raw;setup_encoded+=reserved;pending_encoded+=actual
	end end
	if pending_bytes>MAX_PENDING_BYTES or setup_encoded>MAX_SETUP_STORAGE_BYTES then return nil,"Pending setup result capacity exhausted before native effect; review retained submissions first" end
	local bytes, size_err=encoded(root,MAX_STORE_BYTES)
	if not bytes then return nil,size_err end
	if #bytes-pending_encoded>MAX_BYTES then return nil,"Ordinary authority metadata exceeds 120000 bytes; preserve retained work" end
	return root
end
M.validate=validate
-- Only exact immutable bridge references establish managed purpose in v1.
-- Unknown ordinary executions and pending old transport require their old writer.
local function upgrade(raw,readonly)
	local source_raw=raw
	local roster_changed=false
	local function preserved(candidate,problem)
		if not candidate then return nil,problem end
		-- The v1 upgrade below already preserves this exact source in its managed
		-- backup. Do not partially migrate it by writing a second backup first.
		if roster_changed and source_raw.version~=1 and not readonly then
			local saved,why=pcall(function()
				local original=tern.kv.get("authority-roster-original")
				if original~=nil and not equal(original,source_raw) then error("Roster migration original differs; preserve both before continuing") end
				if original==nil then tern.kv.set("authority-roster-original",clone(source_raw)) end
				if not equal(tern.kv.get("authority-roster-original"),source_raw) then error("Roster migration backup readback differs") end
			end)
			if not saved then return nil,"Could not preserve original roster authority: "..tostring(why) end
		end
		return candidate
	end
	if type(raw)=="table" and (raw.version==1 or raw.version==3 or raw.version==STORAGE_VERSION) then
		local migrated,problem=Config.migrate(raw.config,raw.host_key)
		if not migrated then return nil,problem end
		if migrated.changed then
			roster_changed=true
			-- Provider metadata and retired bulk policy do not change account,
			-- executable, execution identity, grants, history or configuration epoch.
			raw=clone(raw);raw.config=migrated.store
		end
	end
	if type(raw)=="table" and raw.version==3 and raw.setup==nil and raw.setup_adoption_required==nil then
		local candidate=clone(raw)
		candidate.version=STORAGE_VERSION
		candidate.setup=new_setup(candidate.config_revision,true);candidate.setup_adoption_required=true
		return preserved(validate(candidate))
	end
	if type(raw)~="table" or raw.version~=1 then return preserved(validate(raw)) end
	local registry,why=managed_registry();if registry==nil then return nil,why end
	-- Never-created is distinct from lost initialized storage. Empty legacy
	-- scopes need no bridge evidence; actual attempts still require exact matches.
	if registry==false then registry={requests={},gates={}} end
	local candidate=clone(raw)
	if not fields(candidate,{version=true,namespace=true,next_authority=true,host_key=true,config=true,config_revision=true,sessions=true,review=true,reviewed_sources=true})
		or not text(candidate.namespace,128) or type(candidate.sessions)~="table" or type(candidate.reviewed_sources)~="table" then return nil,"Corrupt detached authority" end
	local Codec=require("./wire/codec")
	for key,scope in pairs(candidate.sessions) do
		if not fields(scope,{authority_id=true,launch=true,inbox=true,replies=true,requests=true,request_sequences=true,imports=true})
			or not text(scope.authority_id,256) or not array(scope.inbox,64) or #scope.inbox>0
			or type(scope.replies)~="table" or next(scope.replies)~=nil or type(scope.requests)~="table" or next(scope.requests)~=nil
			or type(scope.request_sequences)~="table" or type(scope.imports)~="table" then return nil,"Review pending or retained ordinary v1 transport with its original SPAWN version before upgrading" end
		local prefix=candidate.namespace.."/session/"
		local suffix=if type(key)=="string" and key:sub(1,#prefix)==prefix then key:sub(#prefix+1) else ""
		local native=tonumber(suffix)
		if not integer(native,0) or tostring(native)~=suffix or not Launch.validate(scope.launch) then return nil,"Corrupt detached session or launch ledger" end
		scope.native_session=native;scope.jobs={};scope.managed_authority_id=scope.authority_id;scope.managed_imports={}
		for _,a in ipairs(scope.launch.attempts) do
			local matched=0
			for request_key,entry in pairs(if registry.version==2 then registry.workers else registry.requests) do
				local b=entry.binding;local r=if registry.version==2 then entry else entry.request
				local launch=registry.version==2 or r.op=="launch" and entry.launch~=nil
				if launch and b and b.session_key==key and b.authority_id==scope.authority_id and b.host_key==candidate.host_key and b.native_session==native
					and entry.observer_id==a.observer_id and entry.observer_id=="managed-"..Codec.sha256(request_key)
					and r.record_id==a.record_id and (entry.attempt_id==a.id or registry.version~=2 and entry.attempt_id==nil and entry.attempt_pending==true) then
					if entry.pane_binding and tonumber(entry.pane_binding.pane_id)~=a.pane then return nil,"Detached managed pane evidence differs from launch ledger" end
					matched+=1
				end
			end
			if matched~=1 or a.scope~=key or a.purpose~=nil then return nil,"Detached attempt lacks one exact managed launch reference; preserve and review with its original version" end
			a.purpose="managed"
		end
		if count(scope.imports)>64 then return nil,"Detached import receipt capacity exhausted" end
		for id,receipt in pairs(scope.imports) do
			local canonical_receipt=Config.validate_records(receipt)
			if not text(id,256) or not canonical_receipt then return nil,"Corrupt detached import receipt" end
			if id:sub(1,7)=="bridge-" then
				local matched=false
				for _,gate in pairs(registry.gates) do
					local b=gate.binding
					if id=="bridge-"..gate.request.request_id and b.session_key==key and b.host_key==candidate.host_key and b.native_session==native and equal(gate.records,canonical_receipt) and gate.consumed then matched=true end
				end
				if not matched then return nil,"Detached managed import receipt lacks an exact consumed gate; preserve it for review" end
				scope.managed_imports[id]=canonical_receipt
			end
			-- Settled ordinary setup receipts are obsolete under v2 identical-
			-- record imports. The exact original backup retains them; never replay.
		end
		scope.inbox=nil;scope.imports=nil
	end
	for id,source in pairs(candidate.reviewed_sources) do candidate.reviewed_sources[id]={host_key=candidate.host_key,config=source} end
	candidate.version=STORAGE_VERSION
	candidate.setup=new_setup(candidate.config_revision,true);candidate.setup_adoption_required=true
	local valid,err=preserved(validate(candidate));if not valid then return nil,err end
	if readonly then return candidate end
	local saved,problem=pcall(function()
		local original=tern.kv.get("managed-v1-original")
		if original~=nil and not equal(original,source_raw) then error("Original detached authority backup differs; preserve both before upgrading") end
		if original==nil then tern.kv.set("managed-v1-original",clone(source_raw)) end
		if not equal(tern.kv.get("managed-v1-original"),source_raw) then error("Detached authority backup readback differs") end
	end)
	if not saved then return nil,"Could not preserve detached authority: "..tostring(problem) end
	return candidate
end
local function read_root(readonly)
	local ok,value=pcall(tern.kv.get,"authority")
	if not ok then return nil,"Could not read authority: "..tostring(value) end
	if value==nil then return nil,"Authority has not been initialized" end
	local root,why=upgrade(value,readonly);if not root then return nil,why end
	local got,marker=pcall(tern.kv.get,"authority-initialized")
	if not got or marker~=nil and marker~=root.namespace then return nil,"Authority initialization evidence is unreadable or differs; restore the matching store" end
	return root
end
-- The host-restart notice is informational: how many ordinary attempts the sweep
-- ended as "Host restarted" under the current daemon epoch. Nothing to act on.
local function restart_notice(scope,host_epoch)
	if not text(host_epoch,4096) then return nil end
	local ended=0
	for _,a in ipairs(scope.launch.attempts) do
		local job=scope.jobs[a.id]
		if a.phase=="Exited" and job~=nil and job.restart_grace==host_epoch then ended+=1 end
	end
	if ended==0 then return nil end
	-- Only a digest of the host epoch is published, never the raw boot identity.
	return {restart_id=require("./wire/codec").sha256(host_epoch):sub(1,32),count=ended}
end
local function snapshot_value(root,key,host_epoch)
	local scope=root.sessions[key]
	local value={version=2,namespace=root.namespace,host_key=root.host_key,authority_id=scope.authority_id,session_key=key,
		config_revision=root.config_revision,records=clone(root.config.hosts[root.host_key].agents),setup=clone(root.setup),
		adoption_required=root.setup_adoption_required,
		attempt_revision=scope.launch.revision,attempts=clone(scope.launch.attempts),jobs=public_jobs(scope),
		replies=clone(scope.replies),request_sequences=clone(scope.request_sequences),
		host_os=tern.runtime.os,host_shell=tern.getenv("SHELL") or tern.getenv("ComSpec") or "unknown",
		ready=root.review==nil,migration=clone(root.review),
		error=if root.review then "Migration or legacy source review required in Config" else nil,
		-- Not "host_restart": windows before 0.5.0 accept that key only as a list of
		-- blocking Unknown attempts and would refuse the whole snapshot. They ignore
		-- unknown top-level keys, so the informational notice travels under its own.
		host_restart_notice=restart_notice(scope,host_epoch)}
	return value
end
local function capacity(root)
	local valid,err=validate(root)
	if not valid then return false,err end
	local pending_encoded,reserved=0,0
	for _,scope in pairs(root.sessions) do
		for _,a in ipairs(scope.launch.attempts) do
			local job=scope.jobs[a.id]
			local metadata,_,_,actual=setup_capacity(job,a)
			reserved+=metadata;pending_encoded+=actual
		end
	end
	local stored=encoded(root,MAX_STORE_BYTES)
	-- Only the once-retained raw strings extend the old authority byte budget.
	-- Keep native binding/settlement headroom before admitting another effect.
	if not stored or #stored-pending_encoded+reserved>MAX_BYTES then return false,"Authority capacity exhausted; review retained work before admitting more" end
	for key,scope in pairs(root.sessions) do
		local value=snapshot_value(root,key,nil)
		value.host_restart_notice={restart_id=string.rep("0",32),count=128}
		local reserve=0
		for _,a in ipairs(scope.launch.attempts) do reserve+=setup_capacity(scope.jobs[a.id],a) end
		local json=encoded(value)
		if not json or #SNAPSHOT_PREFIX+#json+reserve>MAX_BYTES then return false,"Snapshot capacity exhausted; nothing saved" end
	end
	return true
end
-- Jobs exist exactly for retained attempts; history removal drops the rest.
local function retain_jobs(scope)
	local retained={}
	for _,a in ipairs(scope.launch.attempts) do retained[a.id]=scope.jobs[a.id] end
	scope.jobs=retained
end
-- Every write trims each session to its newest KEEP_FINISHED finished attempts
-- (clear-history eligibility) in the same atomic persist, bounding state size.
local function persist(root)
	root.setup.config_revision=root.config_revision
	local registry=managed_registry()
	for key,scope in pairs(root.sessions) do
		local removed,trim_err=Launch.trim_history(scope.launch,KEEP_FINISHED,settled_managed(registry,key,scope))
		if removed==nil then return false,trim_err end
		if removed>0 then retain_jobs(scope) end
	end
	local valid,err=capacity(root)
	if not valid then return false,err end
	local ok,why=pcall(function()
		-- Write the loss fence first. An interrupted first save stays visibly
		-- uninitialized/lost rather than permitting a second empty authority.
		local marker=tern.kv.get("authority-initialized")
		if marker~=nil and marker~=root.namespace then error("Authority namespace differs from its initialization marker; restore the matching store") end
		if marker==nil then tern.kv.set("authority-initialized",root.namespace) end
		tern.kv.set("authority",root)
		if not equal(tern.kv.get("authority"),root) then error("Authority readback differs; preserve the saved state and reconcile before repeating") end
	end)
	if not ok then return false,"Authority save/readback was not confirmed; inspect saved state before repeating: "..tostring(why) end
	return true
end
-- Applies one Launch.classify result and keeps the job stage coupled to it:
-- Failed -> failed; Exited -> resolved (ended without provider completion
-- evidence, so a late real completion may still replace it); Running -> running.
local function settle_attempt(scope,id,phase,diagnostic)
	local accepted,why=Launch.settle(scope.launch,id,phase,diagnostic)
	if not accepted then return false,why end
	scope.jobs[id].stage=if phase=="Failed" then "failed" elseif phase=="Exited" then "resolved" else "running"
	return true
end
-- An unclaimed ticket past its deadline can never run: it settles to Failed.
local function expire_admissions(root,now)
	local candidate=nil
	for key,scope in pairs(root.sessions) do
		for id,job in pairs(scope.jobs) do
			if (job.stage=="admitted" or job.backend=="setup-default" and job.stage=="claimed") and now-job.admitted_at>=ADMISSION_SECONDS then
				candidate=candidate or clone(root)
				local next_scope=candidate.sessions[key]
				local phase,diagnostic=Launch.classify(attempt(next_scope,id),{ticket_expired=true})
				if phase~=nil then
					local settled,why=settle_attempt(next_scope,id,phase,diagnostic)
					if not settled then return nil,why end
				end
			end
		end
	end
	if candidate then local saved,why=persist(candidate);if not saved then return nil,why end;return candidate end
	return root
end
local function binding_for(root,key)
	local scope=root.sessions[key]
	return {session_key=key,authority_id=scope.authority_id,managed_authority_id=scope.managed_authority_id,host_key=root.host_key,native_session=scope.native_session}
end
local function records(root) return root.config.hosts[root.host_key].agents end
local function backup(key,raw)
	local ok,err=pcall(function()
		local old=tern.kv.get(key)
		if old~=nil and not equal(old,raw) then error("Original snapshot already exists with different content; preserve both before proceeding") end
		if old==nil then tern.kv.set(key,raw) end
	end)
	return ok,if ok then nil else "Could not preserve original configuration: "..tostring(err)
end
local function new_scope(root,key,native_session)
	if count(root.sessions)>=64 or root.next_authority>=MAX_INT then return nil,"Authority session capacity exhausted" end
	local scope={authority_id=root.namespace..":"..tostring(root.next_authority),native_session=native_session,launch=Launch.new(),jobs={},replies={},requests={},request_sequences={}}
	root.next_authority+=1;root.sessions[key]=scope
	return scope
end
local function absent_authority()
	for _,key in ipairs({"authority-initialized","dispatch-v1","dispatch-v1-initialized","migration-original","managed-v1-original"}) do
		local ok,value=pcall(tern.kv.get,key)
		if not ok then return false,"Could not inspect saved authority evidence: "..tostring(value) end
		if value~=nil then return false,"Saved authority is missing; restore its original state instead of resetting reservations" end
	end
	return true
end
local function empty_root(host_key,native_session,config,existing)
	-- Durable collision-resistant naming, not a credential or security token.
	-- Monotonic VM time alone repeats when a fresh host runtime starts.
	local namespace=string.format("host-%d-%08x-%08x-%08x-%s",os.time(),math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647),tostring(native_session))
	return {version=STORAGE_VERSION,namespace=namespace,next_authority=1,host_key=host_key,config=config,config_revision=0,
		sessions={},reviewed_sources={},setup=new_setup(0,existing),setup_adoption_required=if existing then true else nil}
end
function M.open(host_key,native_session,client_config,origin_scope)
	if not text(host_key,1024) or not integer(native_session,0) then return nil,"A verified execution host and native session are required" end
	local ok,raw=pcall(tern.kv.get,"authority")
	if not ok then return nil,tostring(raw) end
	local root,err
	if raw==nil then
		if origin_scope~=nil then return nil,"Saved authority is missing; restore its original state instead of resetting reservations" end
		local absent,why=absent_authority();if not absent then return nil,why end
		local got,original=pcall(tern.kv.get,"config")
		if not got then return nil,"Could not read original configuration: "..tostring(original) end
		local sources; sources,err=source_records(original,host_key,"Execution host")
		if not sources then return nil,err end
		local migrated=Config.migrate(original,host_key)
		local base=if migrated then migrated.store else {schema=2,hosts=clone(original.hosts)}
		if not migrated then base.hosts[host_key]={schema=2,agents=sources[1].records} end
		root=empty_root(host_key,native_session,base,original~=nil)
		if original~=nil then
			local backed,backup_error=backup("migration-original",original)
			if not backed then return nil,backup_error end
			root.review={sources=sources,choices={},reason="Review the preserved original settings and approve one launch configuration per account."}
		end
	else
		root,err=upgrade(raw)
		if not root then return nil,err end
		root=clone(root)
	end
	local key=root.namespace.."/session/"..tostring(native_session)
	if origin_scope~=nil and origin_scope~=key then return nil,"Host authority namespace or native session changed; the original scope was not rebound" end
	local scope=root.sessions[key]
	if not scope and origin_scope~=nil then return nil,"Original session authority is missing; restore it instead of creating an empty history" end
	if not scope then scope,err=new_scope(root,key,native_session); if not scope then return nil,err end end
	if client_config~=nil then
		local client_sources;client_sources,err=source_records(client_config,host_key,"Client copy")
		if not client_sources then return nil,"Client copy needs review: "..tostring(err) end
		local already=false
		for _, prior in pairs(root.reviewed_sources) do if prior.host_key==host_key and equal(prior.config,client_config) then already=true end end
		if not already then
			local differs=false
			for _, source in ipairs(client_sources) do if not equal(source.records,records(root)) then differs=true end end
			if differs then
				if count(root.reviewed_sources)>=64 then return nil,"Legacy source review capacity exhausted" end
				local index=count(root.reviewed_sources)+1
				local backed,why=backup("migration-client-"..tostring(index),client_config)
				if not backed then return nil,why end
				if not root.review then root.review={sources={{label="Execution host",records=clone(records(root))}},choices={},reason="Host and client copies differ. Select a source for each record; neither original is overwritten."} end
				for _, source in ipairs(client_sources) do
					local found=false
					for _, existing in ipairs(root.review.sources) do if equal(existing.records,source.records) then found=true end end
					if not found then source.label ..=" "..tostring(index);table.insert(root.review.sources,source);root.review.choices={} end
				end
				root.reviewed_sources[tostring(index)]={host_key=host_key,config=clone(client_config)}
				root.config_revision+=1
			end
		end
	end
	local saved,why=persist(root)
	if not saved then return nil,why end
	return binding_for(root,key),nil
end
-- Installation reads never create scopes, expire tickets, or persist migrations.
-- The native host is the writer; catalog callers only receive this projection.
local function setup_snapshot_value(root)
	return {namespace=root.namespace,host_key=root.host_key,config_revision=root.config_revision,
		records=clone(records(root)),setup=clone(root.setup),adoption_required=root.setup_adoption_required,
		ready=root.review==nil,migration=clone(root.review),
		host_os=tern.runtime.os,host_shell=tern.getenv("SHELL") or tern.getenv("ComSpec") or "unknown"}
end
function M.setup_snapshot(host_key)
	if host_key~=nil and not text(host_key,1024) then return nil,"Invalid execution host" end
	local ok,raw=pcall(tern.kv.get,"authority")
	if not ok then return nil,"Could not read authority: "..tostring(raw) end
	if raw~=nil then
		local root,why=upgrade(raw,true);if not root then return nil,why end
		local got,marker=pcall(tern.kv.get,"authority-initialized")
		if not got or marker~=nil and marker~=root.namespace then return nil,"Authority initialization evidence is unreadable or differs; restore the matching store" end
		return setup_snapshot_value(root),nil
	end
	local absent,why=absent_authority();if not absent then return nil,why end
	local got,original=pcall(tern.kv.get,"config")
	if not got then return nil,"Could not read original configuration: "..tostring(original) end
	if original~=nil then return nil,"Existing configuration requires Review existing setup in Config before managed setup" end
	return {host_key=host_key,config_revision=0,records={},setup=new_setup(0,false),ready=true,
		host_os=tern.runtime.os,host_shell=tern.getenv("SHELL") or tern.getenv("ComSpec") or "unknown"},nil
end
-- A diagnostic owns its record across every native session until positive cleanup.
-- Old obligations without a record ID conservatively fence all new launches.
local function setup_launch_error(root,id)
	local probe=root.setup_probe
	if probe and (probe.record_id==nil or probe.record_id==id) then return "This agent is being prepared; wait for its owned diagnostic cleanup before starting work" end
	return nil
end
local function preparation_error(root,id)
	if not text(id,96) then return "A valid saved agent identity is required before preparation" end
	for _,record in ipairs(records(root)) do
		if record.id==id then
			if not record.enabled then return "Enable this agent in Agent settings before preparation; it has not been enabled automatically" end
			if record.review_required then return "Review and approve this agent's saved launch settings before preparation" end
		end
	end
	for _,scope in pairs(root.sessions) do
		for _,attempt in ipairs(scope.launch.attempts) do
			if attempt.record_id==id and (attempt.unresolved or attempt.phase~="Exited" and attempt.phase~="Failed") then return "This agent has active or uncertain work in a session on this execution machine; settle that work before preparation" end
		end
	end
	local busy,why=require("./dispatch").record_preparation_busy(id)
	if busy~=false then return why or "Managed work for this agent cannot be established as settled; preserve it before preparation" end
	return nil
end
function M.record_preparation_available(host_key,id)
	local root,why=read_root(true);if not root then return false,why end
	if root.host_key~=host_key then return false,"Execution host differs from the configuration authority" end
	local problem=preparation_error(root,id)
	return problem==nil,problem
end
-- Size-only preflight for the exact prepared record's eventual saved shape.
-- It publishes no probe, readiness evidence, history deletion or model permission.
function M.setup_capacity_available(host_key,expected,value,probe)
	local root,why=read_root(true);if not root then return false,why end
	if root.host_key~=host_key or root.config_revision~=expected then return false,"Setup host or revision changed before capacity preflight" end
	local canonical,problem=Config.validate_record(value)
	if not canonical or not canonical.mailbox or type(probe)~="table" or not text(probe.bundle_digest,64) or #probe.bundle_digest~=64 or not text(probe.provision_handle,256)
		or probe.record_sha256~=require("./wire/codec").sha256(tern.json.encode(value)) then return false,problem or "The exact prepared resource record is required for capacity preflight" end
	canonical.mailbox.verified=true
	canonical.mailbox.evidence_ref="setup:"..probe.bundle_digest..":"..probe.provision_handle
	local candidate=clone(root);local combined=records(candidate);local found=false
	for index,record in ipairs(combined) do if record.id==canonical.id then combined[index]=canonical;found=true;break end end
	if not found then table.insert(combined,canonical) end
	candidate.config.hosts[candidate.host_key].agents=combined
	candidate.config_revision+=1;candidate.setup.config_revision=candidate.config_revision
	if candidate.setup.state=="in_progress" then candidate.setup.state=if found then "adopted_existing" else "completed" end
	candidate.setup_adoption_required=nil
	return capacity(candidate)
end
local function probed_record(data,root)
	if not fields(data,{record=true,probe=true,verified=true}) or data.verified~=true then return nil,"Complete machine-observed setup evidence is required" end
	local canonical,why=Config.validate_records({data.record});if not canonical or #canonical~=1 then return nil,why or "One managed record is required" end
	local record=canonical[1];local probe=data.probe
	if not fields(probe,{schema=true,passed=true,record_sha256=true,observations=true,bundle_digest=true,worker_identity=true,provision_handle=true})
		or probe.schema~=1 or probe.passed~=true or not array(probe.observations,64) or #probe.observations==0
		or not text(probe.worker_identity,4096) or not text(probe.provision_handle,256)
		or type(probe.bundle_digest)~="string" or #probe.bundle_digest~=64 or not probe.bundle_digest:match("^[0-9a-f]+$") then return nil,"Successful prerequisite and provisioning probe required" end
	local seen={}
	for _,observation in ipairs(probe.observations) do
		if not fields(observation,{id=true,state=true,summary=true}) or not text(observation.id,96) or seen[observation.id]
			or observation.state~="passed" or not text(observation.summary,1024) then return nil,"Every prerequisite observation must have passed" end
		seen[observation.id]=true
	end
	for _,id in ipairs({"launch-construction","account-cli-folder-dependencies","serializer-argv","helper-provision","provision-readback","native-route"}) do
		if not seen[id] then return nil,"Successful setup observation required: "..id end
	end
	local Codec=require("./wire/codec")
	local encoded_ok,bytes=pcall(tern.json.encode,data.record)
	if not encoded_ok or probe.record_sha256~=Codec.sha256(bytes) then return nil,"Probe does not match the exact approved record" end
	if not record.mailbox or record.mailbox.verified~=false or record.mailbox.worker_identity~=probe.worker_identity then return nil,"Probe worker identity or unverified record differs" end
	record.mailbox.verified=true
	record.mailbox.evidence_ref="setup:"..probe.bundle_digest..":"..probe.provision_handle
	local eligible,_,reasons=require("./mailbox_capabilities").eligibility(record,{
		host_key=root.host_key,host_os=tern.runtime.os,host_shell=tern.getenv("SHELL") or tern.getenv("ComSpec") or "unknown"})
	if not eligible then return nil,table.concat(reasons,"; ") end
	return record
end
-- Expected configuration revision is captured before prompts/probes, not refreshed
-- on delivery. A stale callback may inspect current state but never replay a write.
function M.setup_edit(host_key,expected,operation,data)
	if not text(host_key,1024) or not integer(expected,0) then return false,"Verified host and expected configuration revision required" end
	local view,why=M.setup_snapshot(host_key);if not view then return false,why end
	if expected~=view.config_revision then return false,"stale-config: settings were reloaded; review and repeat your edit" end
	local root
	if view.namespace==nil then
		if operation~="begin" and operation~="dismiss" then return false,"Begin managed setup before saving configuration" end
		local migrated,err=Config.migrate(nil,host_key);if not migrated then return false,err end
		root=empty_root(host_key,"setup",migrated.store,false)
	else
		local err;root,err=read_root();if not root then return false,err end
		if root.host_key~=host_key then return false,"Execution host differs from the configuration authority" end
		root=clone(root)
	end
	if root.review then return false,"Complete migration/source review first" end
	if root.config_revision>=MAX_INT then return false,"Configuration revision capacity exhausted" end
	local state=root.setup.state
	local complete=state=="completed" or state=="adopted_existing"
	if operation=="begin" or operation=="dismiss" then
		if not fields(data,{}) then return false,"Invalid setup lifecycle edit" end
		if complete then return false,"Setup is already complete; use the managed record editor without reopening first-install setup" end
		root.setup.state=if operation=="begin" then "in_progress" else "dismissed"
	elseif operation=="commit" or operation=="adopt" then
		if root.setup_probe~=nil then return false,"Verify native diagnostic cleanup before completing managed setup" end
		local busy=preparation_error(root,if type(data)=="table" and type(data.record)=="table" then data.record.id else nil)
		if busy then return false,busy end
		if state~="in_progress" and not complete then return false,"Begin managed setup before saving configuration" end
		local record,err=probed_record(data,root);if not record then return false,err end
		local combined=records(root);local found=false
		for index,old in ipairs(combined) do if old.id==record.id then combined[index]=record;found=true;break end end
		if operation=="commit" and found and root.setup_adoption_required then return false,"Review and adopt this existing record explicitly" end
		if operation=="adopt" and not found and #combined>0 then return false,"Adoption requires an existing record selected for review" end
		if not found then table.insert(combined,record) end
		local canonical,problem=Config.validate_records(combined);if not canonical then return false,problem end
		root.config.hosts[root.host_key].agents=canonical
		if not complete then root.setup.state=if operation=="adopt" then "adopted_existing" else "completed" end
		root.setup_adoption_required=nil
	elseif operation=="readiness" then
		if not complete then return false,"Complete or adopt setup before the optional readiness exercise" end
		if not fields(data,{state=true,summary=true}) then return false,"Invalid readiness result" end
		local result={state=data.state,summary=data.summary,config_revision=root.config_revision+1}
		if not readiness_valid(result,result.config_revision) then return false,"Invalid readiness result" end
		root.setup.readiness=result
	else return false,"Unknown setup operation" end
	root.config_revision+=1
	return persist(root)
end
-- Only host-native cleanup consumes this record. Reload never grants another
-- launch, and neither pane binding nor cleanup changes configuration approval.
function M.setup_probe_read(host_key)
	if not text(host_key,1024) then return nil,"Verified execution host required" end
	local view,why=M.setup_snapshot(host_key);if not view then return nil,why end
	if view.namespace==nil then return nil,nil end
	local root,err=read_root(true);if not root then return nil,err end
	if root.host_key~=host_key then return nil,"Execution host differs from the configuration authority" end
	return clone(root.setup_probe),nil
end
function M.setup_probe_claim(host_key,expected,route)
	if not text(host_key,1024) or not integer(expected,0) or not setup_probe_valid(route,expected)
		or route.config_revision~=expected or route.pane~=nil or route.window_pane~=nil or not text(route.record_id,96) or not text(route.native_namespace,96) or not text(route.window_consent,256) then return false,"Invalid initial setup probe obligation" end
	local root,err=read_root();if not root then return false,err end
	if root.host_key~=host_key then return false,"Execution host differs from the configuration authority" end
	if root.config_revision~=expected then return false,"stale-config: native diagnostic was not admitted" end
	local scope=root.sessions[root.namespace.."/session/"..tostring(route.native_session)]
	if not scope or scope.authority_id~=route.authority_id then return false,"stale-authority: native diagnostic origin changed" end
	if root.review then return false,"Complete migration/source review first" end
	if root.setup_probe~=nil then return false,"An unfinished native setup probe requires cleanup before another diagnostic" end
	local busy=preparation_error(root,route.record_id);if busy then return false,busy end
	local candidate=clone(root);candidate.setup_probe=clone(route)
	return persist(candidate)
end
local function setup_probe_owner(host_key,nonce)
	if not text(host_key,1024) or not text(nonce,256) then return nil,"Verified host and setup probe nonce required" end
	local root,err=read_root();if not root then return nil,err end
	if root.host_key~=host_key then return nil,"Execution host differs from the configuration authority" end
	if not root.setup_probe or root.setup_probe.nonce~=nonce then return nil,"Setup probe obligation no longer matches this diagnostic" end
	return root
end
function M.setup_probe_bind(host_key,nonce,pane,window_pane)
	if not integer(pane,1) or window_pane~=nil and not integer(window_pane,1) then return false,"Verified native and desktop probe panes required" end
	local root,err=setup_probe_owner(host_key,nonce);if not root then return false,err end
	local probe=root.setup_probe
	if probe.pane~=nil and probe.pane~=pane then return false,"Setup probe pane identity is immutable" end
	if window_pane~=nil and probe.window_pane~=nil and probe.window_pane~=window_pane then return false,"Setup probe desktop pane identity is immutable" end
	if probe.pane==pane and (window_pane==nil or probe.window_pane==window_pane) then return true end
	local candidate=clone(root);candidate.setup_probe.pane=pane
	if window_pane~=nil then candidate.setup_probe.window_pane=window_pane end
	return persist(candidate)
end
function M.setup_probe_clear(host_key,nonce)
	local root,err=setup_probe_owner(host_key,nonce);if not root then return false,err end
	local candidate=clone(root);candidate.setup_probe=nil
	return persist(candidate)
end

-- This context comes only from the host's twice-checked native inventory, not
-- from request JSON. SDK IDs are retained separately from native host pane IDs.
local function setup_context(scope,context)
	if type(context)~="table" or not integer(context.config_pane,1) or type(context.window)~="string"
		or #context.window>256 or context.window:find("%c") or type(context.inventory)~="table"
		or type(context.inventory.sessions)~="table" or type(context.inventory.clients)~="table"
		or context.epoch~=nil and not text(context.epoch,4096) then return nil,"Fresh native setup context is unavailable" end
	-- context.window is the CLIENT's key (an echo compared with saved requests); the
	-- host daemon's own inventory is keyed by context.host_window when the host is remote.
	local host_window=if context.host_window~=nil then context.host_window else context.window
	if type(host_window)~="string" or #host_window>256 or host_window:find("%c") then return nil,"Fresh native setup context is unavailable" end
	local client=nil
	for _,value in ipairs(context.inventory.clients) do
		if (value.kind=="window" or value.kind=="remote") and value.window==host_window then
			if client or not integer(value.conn,0) or not integer(value.since,0) then return nil,"Native setup window incarnation is ambiguous" end
			client=value
		end
	end
	if not client then return nil,"Original native setup window is unavailable" end
	local panes,seen,config_count,config_cwd={}, {}, 0, nil
	for _,session in ipairs(context.inventory.sessions) do
		for _,tab in ipairs(session.tabs or {}) do for _,block in ipairs(tab.blocks or {}) do
			if not integer(block.id,1) or seen[block.id] then return nil,"Native setup pane membership is ambiguous" end
			seen[block.id]=true
			if #panes>=4096 then return nil,"Native setup pane inventory exceeds its bounded size" end
			table.insert(panes,{id=block.id,session=session.id,command=block.command,cwd=block.cwd})
			if block.id==context.config_pane then
				if session.id~=scope.native_session then return nil,"Config moved from its original native session" end
				config_count+=1
				config_cwd=block.cwd
			end
		end end
	end
	if config_count~=1 then return nil,"Original Config pane is missing from its native session" end
	return {client=client,panes=panes,config_cwd=config_cwd},nil
end
local function setup_source(root,scope,job,context,require_pane)
	if not job or job.backend~="setup-default" or job.pane_reused then return nil,"Setup attempt is missing or inactive" end
	local s=job.setup
	if root.review or root.config_revision~=job.config_revision or scope.authority_id~=s.authority_id then return nil,"Setup configuration or authority changed; review again" end
	local native,why=setup_context(scope,context);if not native then return nil,why end
	if context.window~=s.window or context.config_pane~=s.host_config_pane
		or native.client.conn~=s.native_conn or native.client.since~=s.native_since
		or context.epoch~=s.origin_epoch then return nil,"Original setup host, Config pane or window incarnation changed" end
	if require_pane then
		if not job.native then return nil,"Setup native pane has not been bound" end
		local found=nil
		for _,pane in ipairs(native.panes) do if pane.id==job.native.pane then found=pane end end
		-- The folder is deliberately not compared here: bind already matched the exact launch folder, and
		-- a helper (OMP) may leave it afterwards. Pane id, session, command and window incarnation are the identity.
		if not found or found.session~=scope.native_session or found.command~=s.command then
			return nil,"Setup native source closed, moved or changed; automatic import was refused"
		end
	end
	return native,nil
end
local function result_records(bytes,run_id)
	local value,problem=Config.decode_setup_json(bytes)
	if not value then return nil,problem end
	local review,why=require("./setup_review").prepare(value,run_id)
	if not review then return nil,why end
	return review.records,nil,review.paid_checks
end
-- Only untrusted Guided/manual proposals need this guard. Owner-validated paired
-- migration gates preserve already verified identities through managed_import.
local function untrusted_records(root,source)
	local canonical,problem=Config.validate_records(source);if not canonical then return nil,problem end
	for _,record in ipairs(canonical) do
		if record.mailbox and (record.mailbox.verified==true or record.mailbox.evidence_ref~=nil) then
			local identical=false
			for _,old in ipairs(records(root)) do if equal(old,record) then identical=true;break end end
			if not identical then return nil,"Managed readiness cannot be imported for a new record or changed saved configuration. Use ordinary launch settings, then SPAWN Required resources and capabilities." end
		end
	end
	return canonical,nil
end
local function import_records(root,source)
	local validated,err=Config.validate_records(source);if not validated then return nil,err end
	local combined=clone(records(root));local added=0
	for _,record in ipairs(validated) do
		local found=nil
		for _,old in ipairs(combined) do if old.id==record.id then found=old end end
		if found and not equal(found,record) then return nil,"record-conflict: "..record.id.."; edit or review the saved record explicitly" end
		if not found then table.insert(combined,record);added+=1 end
	end
	local canonical,why=Config.validate_records(combined);if not canonical then return nil,why end
	root.config.hosts[root.host_key].agents=canonical
	if added>0 then root.config_revision+=1 end
	return {imported=added}
end
local function dispatch(root,key,r,now,context)
	local scope=root.sessions[key];local d=r.data
	-- Acknowledged before any fence: there is nothing left to execute.
	if OBSOLETE[r.op] then return clone(OBSOLETE_RESULT) end
	if r.expected_config_revision~=root.config_revision then return nil,"stale-config" end
	if root.review then return nil,"migration-review-required" end
	if r.op=="refresh" then return {} end
	if r.op=="discard_setup_result" then
		local native,why=setup_context(scope,context);if not native then return nil,why end
		local job=scope.jobs[d.attempt_id]
		if not job or not job.setup or job.setup_run_id~=d.setup_run_id or not job.pending or job.pending.consumed or job.pending.digest~=d.pending_digest then return nil,"Pending setup result changed, was consumed or belongs to another review; discard nothing" end
		if scope.launch.revision>=MAX_INT then return nil,"capacity" end
		job.pending.consumed=true;job.pending.discarded=true;job.pending.bytes=nil
		scope.launch.revision+=1
		return {discarded=true}
	end
	if r.op=="import_records" then
		if d.manual==true then
			local native,why=setup_context(scope,context);if not native then return nil,why end
			local recovery=nil
			local records=d.records
			if d.attempt_id~=nil then
				recovery=scope.jobs[d.attempt_id]
				if not recovery or recovery.setup_run_id~=d.setup_run_id or not recovery.pending
					or recovery.pending.consumed or recovery.pending.digest~=d.pending_digest then
					return nil,"Retained manual recovery is inactive, consumed or differs from this review"
				end
				local problem
				records,problem=result_records(recovery.pending.bytes,d.setup_run_id)
				if not records then return nil,problem end
			else
				for _,job in pairs(scope.jobs) do
					if job.setup_run_id==d.setup_run_id and job.pending and not job.pending.consumed then
						local original,problem=result_records(job.pending.bytes,d.setup_run_id)
						local reviewed=Config.validate_records(d.records)
						if not original or not equal(original,reviewed) then return nil,problem or "Manual recovery differs from this run's immutable submitted records" end
						if recovery then return nil,"Manual recovery run is ambiguous" end
						recovery=job
					end
				end
			end
			if recovery and scope.launch.revision>=MAX_INT then return nil,"capacity" end
			local validated,claim_error=untrusted_records(root,records);if not validated then return nil,claim_error end
			local result,problem=import_records(root,validated);if not result then return nil,problem end
			if recovery then recovery.pending.consumed=true;recovery.pending.bytes=nil;scope.launch.revision+=1 end
			return result
		end
		local job=scope.jobs[d.attempt_id]
		local native,why=setup_source(root,scope,job,context,true);if not native then return nil,why end
		if job.observer_id~=r.observer_id or job.setup_run_id~=d.setup_run_id or job.stage~="submitted"
			or not job.pending or job.pending.consumed or job.pending.digest~=d.pending_digest then return nil,"Setup result is inactive, consumed or belongs to another review" end
		if scope.launch.revision>=MAX_INT then return nil,"capacity" end
		local validated,err,paid=result_records(job.pending.bytes,d.setup_run_id);if not validated then return nil,err end
		local ordinary,claim_error=untrusted_records(root,validated);if not ordinary then return nil,claim_error end
		local result,problem=import_records(root,ordinary);if not result then return nil,problem end
		if d.preparation then
			local preparation=d.preparation
			if preparation.revision~=root.config_revision or preparation.window~=context.window then return nil,"The reviewed preparation revision/window differs from the exact saved roster" end
			local index=0
			local begin=root.setup.state=="not_started" or root.setup.state=="dismissed"
			-- Only what the helper's retained result discloses may be prepared: terminal accounts and the
			-- native accounts listed in its paid_checks. Other enabled records are saved, never prepared.
			for _,record in ipairs(ordinary) do
				if record.enabled and (record.backend~="native-agent" or (paid and paid[record.id]==true)) then
					index+=1
					local entry=preparation.entries[index]
					if record.review_required or not entry or entry.record_id~=record.id or entry.label~=record.provider.." — "..record.account_label or entry.backend~=record.backend or entry.revision~=root.config_revision+(if begin then 1 else 0)+index-1 then return nil,"Preparation approval differs from the exact reviewed enabled accounts" end
				end
			end
			if index~=#preparation.entries then return nil,"Preparation includes accounts outside the reviewed settings" end
		end
		job.pending.consumed=true;job.pending.bytes=nil;scope.launch.revision+=1
		return result
	elseif r.op:sub(1,6)=="setup_" then
		local job=scope.jobs[d.attempt_id]
		local native,why=setup_source(root,scope,job,context,false);if not native then return nil,why end
		if job.setup_run_id~=d.setup_run_id or job.observer_id~=r.observer_id
			or r.request_sequence<=job.setup.request_sequence then return nil,"Setup request belongs to another run or observer" end
		if r.op=="setup_claim" or r.op=="setup_begin" then
			local expected=if r.op=="setup_claim" then "admitted" else "claimed"
			if job.stage~=expected or now-job.admitted_at>=ADMISSION_SECONDS then return nil,"Setup admission expired or was already claimed" end
			if r.op=="setup_begin" then
				job.setup.before_panes={}
				for _,pane in ipairs(native.panes) do table.insert(job.setup.before_panes,pane.id) end
			end
			job.stage=if r.op=="setup_claim" then "claimed" else "submission_intent"
			local accepted,err=Launch.observe(scope.launch,job.id,{phase="Starting",scope=key})
			if not accepted then return nil,err end
		elseif r.op=="setup_bind" then
			if job.stage~="submission_intent" or job.native~=nil then return nil,"Setup native effect was already bound or is uncertain; never start it again" end
			local before={};for _,pane in ipairs(job.setup.before_panes) do before[pane]=true end
			local found=nil
			for _,pane in ipairs(native.panes) do
				if not before[pane.id] and pane.command==job.setup.command and pane.cwd==job.cwd and pane.session==scope.native_session then
					if found then return nil,"New setup native source is ambiguous; preserve the uncertain attempt" end
					found=pane
				end
			end
			if not found then return nil,"New setup native source is unavailable; preserve the uncertain attempt" end
			local accepted,err=Launch.observe(scope.launch,job.id,{phase="Running",pane=found.id,scope=key})
			if not accepted then return nil,err end
			job.native={pane=found.id,window_key=job.setup.window};job.setup.agent_pane=d.pane;job.stage="submitted"
		else
			if job.stage~="submission_intent" and job.stage~="submitted" then return nil,"Setup native effect is not awaiting settlement" end
			local accepted,err=Launch.observe(scope.launch,job.id,{phase="Unknown",scope=key,error_category="unknown",diagnostic="Native setup start outcome is uncertain; never replay this run"})
			if not accepted then return nil,err end
			job.stage="unknown"
		end
		return {job=public_job(job)}
	elseif r.op=="launch_record" or r.op=="start_setup" then
		local setup=r.op=="start_setup"
		local record,initial_prompt,bootstrap=nil,nil,nil
		if setup then
			for _,other_scope in pairs(root.sessions) do
				for _,prior in pairs(other_scope.jobs) do
					if prior.setup and (not prior.pending or not prior.pending.consumed) then
						local prior_attempt=attempt(other_scope,prior.id)
						if prior.pending or prior_attempt and prior_attempt.phase~="Exited" and prior_attempt.phase~="Failed" then return nil,"Guided setup is already active; finish or review its original run before starting another helper" end
					end
				end
			end
			for _,prior in pairs(scope.jobs) do if prior.setup_run_id==d.setup_run_id then return nil,"Setup run ID is already retained; never replay it" end end
			local native,why=setup_context(scope,context);if not native then return nil,why end
			if context.window~=d.window then return nil,"Setup request belongs to another native window" end
			if native.config_cwd~=d.cwd then return nil,"The execution-host working folder changed before setup; nothing started" end
			local route,route_error=require("./launch_resolution").setup_default(d.command,d.cwd,tern.runtime.os)
			if not route then return nil,route_error end
			local config_dir=tern.getenv("TERN_CONFIG_DIR")
			if config_dir~=nil and not text(config_dir,8192) then return nil,"Explicit native Tern configuration directory is invalid" end
			local nonce=Codec.sha256(root.namespace..":"..key..":"..tostring(scope.launch.next_attempt)..":"..d.setup_run_id..":"..tostring(math.random(1,2147483647)))
			bootstrap={command=route.command,cwd=route.cwd,window=d.window,config_pane=d.config_pane,host_config_pane=context.config_pane,
				result_path=tern.plugin.data.."/setup-result-"..nonce..".json",binding=nonce,host_key=root.host_key,
				authority_id=scope.authority_id,request_sequence=r.request_sequence,native_session=scope.native_session,
				native_conn=native.client.conn,native_since=native.client.since,origin_epoch=context.epoch,config_dir=config_dir}
			local ok,skill=pcall(tern.fs.read,tern.plugin.dir.."/skills/setup/SKILL.md",32001)
			if not ok or type(skill)~="string" or #skill>32000 then return nil,"Packaged provider-neutral setup skill is unavailable" end
			local prompt_context=clone(bootstrap)
			-- The helper runs `tern send --window` on the host daemon: use the host's own key.
			if context.host_window~=nil then prompt_context.window=context.host_window end
			prompt_context.glitch_installation=SetupDiscovery.glitch(route.cwd)
			initial_prompt,why=Backend.setup_prompt(records(root),d.setup_run_id,root.host_key,key,prompt_context,skill,route.shell)
			if not initial_prompt then return nil,why end
			record={id="setup-default",provider="Tern default",account_label="Guided setup",backend="setup-default",placement="tab",cwd=route.cwd}
		else
			for _,value in ipairs(records(root)) do if value.id==d.record_id then record=value end end
			if not record then return nil,"missing-record" end
			local preparing=setup_launch_error(root,record.id);if preparing then return nil,preparing end
			if record.backend=="native-agent" and (not record.prompt or not record.prompt:find("%S")) then return nil,"review: approve this account's startup prompt in Config" end
		end
		local purpose=if setup then "setup" else "launch"
		local a,err=Launch.reserve(scope.launch,record,key,execution_observer(root),purpose)
		if not a then return nil,if err=="skip" then "disabled" else err end
		local token=key..":"..a.id
		local job={id=a.id,attempt_id=a.id,record_id=record.id,purpose=purpose,
			config_revision=root.config_revision,observer_id=r.observer_id,session_key=key,native_session=scope.native_session,
			token=token,ticket=if setup then nil else "exit 125 # SPAWN:"..token,stage="admitted",
			admitted_at=now,pane_reused=false,setup_run_id=if setup then d.setup_run_id else nil,initial_prompt=initial_prompt,setup=bootstrap}
		for name,value in pairs(display(record,purpose)) do job[name]=value end
		scope.jobs[job.id]=job
		return {attempt=clone(a),job=public_job(job)}
	end
	return nil,"unsupported-operation"
end
function M.request(binding,input,context)
	if not request_valid(input) then return false,"Invalid authority request; nothing executed" end
	local now=os.time()
	local ok,result,reason=pcall(function()
		local root,err=read_root();if not root then return false,err end
		local key=binding.session_key;local scope=root.sessions[key]
		if not scope or scope.authority_id~=binding.authority_id or input.authority_id~=scope.authority_id then return false,"stale-authority" end
		local prior=scope.requests[input.request_id]
		if prior then return equal(prior,input),if equal(prior,input) then nil else "changed-request-reuse" end
		if input.request_sequence<=(scope.request_sequences[input.observer_id] or 0) then return false,"stale-request-sequence" end
		local base=clone(root);scope=base.sessions[key]
		for _,id in ipairs(input.acknowledged_requests) do
			local reply=scope.replies[id]
			if reply and reply.observer_id~=input.observer_id then return false,"acknowledgment-observer-mismatch" end
			if reply then scope.replies[id]=nil;scope.requests[id]=nil end
		end
		if count(scope.replies)>=64 or (scope.request_sequences[input.observer_id]==nil and count(scope.request_sequences)>=64) then
			-- Never evict a watermark in the same generation: that could replay an
			-- acknowledged launch. Fence every old request before reclaiming space.
			if base.next_authority>=MAX_INT then return false,"Authority identity capacity exhausted" end
			scope.authority_id=base.namespace..":"..tostring(base.next_authority)
			base.next_authority+=1
			scope.replies={};scope.requests={};scope.request_sequences={}
			local saved,why=persist(base)
			return false,if saved then "stale-authority" else why
		end
		-- Change, reply and watermark commit together in one atomic write.
		local candidate=clone(base)
		local value,dispatch_err=dispatch(candidate,key,input,now,context)
		-- A rejected operation must not retain any candidate mutation.
		if value==nil then candidate=clone(base) end
		scope=candidate.sessions[key]
		scope.request_sequences[input.observer_id]=input.request_sequence
		scope.requests[input.request_id]=clone(input)
		scope.replies[input.request_id]={request_id=input.request_id,observer_id=input.observer_id,request_sequence=input.request_sequence,ok=value~=nil,error=dispatch_err,config_revision=candidate.config_revision,attempt_revision=scope.launch.revision,result=value}
		return persist(candidate)
	end)
	if not ok then return false,"Authority processing failed; nothing was admitted: "..tostring(result) end
	return result,reason
end
function M.snapshot(binding,host_epoch)
	local root,err=read_root();if not root then return nil,err end
	local scope=root.sessions[binding.session_key]
	if not scope or scope.authority_id~=binding.authority_id then return nil,"stale-authority; reopen Config" end
	root,err=expire_admissions(root,os.time());if not root then return nil,err end
	return snapshot_value(root,binding.session_key,host_epoch),nil
end
-- A small explicit envelope is the only automatic result ingress. The file is
-- read once after binding checks; neither review nor confirmation rereads it.
function M.setup_submission(binding,envelope,context)
	if not fields(envelope,{schema=true,kind=true,setup_run_id=true,binding=true,path=true})
		or envelope.schema~=1 or envelope.kind~="spawn-setup-result" or not text(envelope.setup_run_id,256)
		or not text(envelope.binding,256) or not text(envelope.path,8192) then return false,"Invalid setup submission envelope" end
	local root,why=read_root();if not root then return false,why end
	local scope=root.sessions[binding.session_key]
	if not scope or scope.authority_id~=binding.authority_id then return false,"stale-authority" end
	local job=nil
	for _,value in pairs(scope.jobs) do
		if value.setup_run_id==envelope.setup_run_id and value.setup and value.setup.binding==envelope.binding then
			if job then return false,"Ambiguous setup submission binding" end
			job=value
		end
	end
	local native,err=setup_source(root,scope,job,context,true);if not native then return false,err end
	if job.stage~="submitted" or job.pending~=nil or envelope.path~=job.setup.result_path then return false,"Setup submission is inactive, already accepted or names another path" end
	local ok,bytes=pcall(tern.fs.read,job.setup.result_path,MAX_SETUP_BYTES+1)
	if not ok or not bounded(bytes,MAX_SETUP_BYTES) then return false,"Setup result could not be read completely within 120000 bytes; nothing was accepted" end
	local canonical,problem=result_records(bytes,job.setup_run_id);if not canonical then return false,problem end
	local ordinary,claim_error=untrusted_records(root,canonical)
	if not ordinary then return false,claim_error.." No submission was accepted; correct the proposed result and obtain fresh explicit approval." end
	local candidate=clone(root);local target=candidate.sessions[binding.session_key]
	if target.launch.revision>=MAX_INT then return false,"capacity" end
	target.jobs[job.id].pending={bytes=bytes,length=#bytes,digest=Codec.sha256(bytes),consumed=false}
	target.launch.revision+=1
	return persist(candidate)
end
function M.setup_pending(binding,id)
	if not text(id,96) then return nil,"Invalid setup attempt" end
	local root,why=read_root();if not root then return nil,why end
	local scope=root.sessions[binding.session_key]
	if not scope or scope.authority_id~=binding.authority_id then return nil,"stale-authority" end
	local job=scope.jobs[id]
	if not job or job.backend~="setup-default" or not job.pending then return nil,"No submitted setup result is retained for this attempt" end
	return {attempt_id=job.id,setup_run_id=job.setup_run_id,binding=job.setup.binding,
		bytes=job.pending.bytes,digest=job.pending.digest,consumed=job.pending.consumed},nil
end
-- The original successful immutable import request is the preparation receipt.
-- No new store, transcript or second human approval can broaden its account scope.
function M.reviewed_setup_preparation(binding,request_id,attempt_id,digest)
	local root,why=read_root(true);if not root then return nil,why end
	local scope=root.sessions[binding.session_key]
	if not scope or scope.authority_id~=binding.authority_id or root.host_key~=binding.host_key then return nil,"The original setup authority changed" end
	local request,reply=scope.requests[request_id],scope.replies[request_id]
	local job=scope.jobs[attempt_id]
	if not request or request.op~="import_records" or not reply or not reply.ok or request.data.manual~=nil or not request.data.preparation
		or request.data.attempt_id~=attempt_id or request.data.pending_digest~=digest or not job or job.observer_id~=request.observer_id
		or not job.pending or not job.pending.consumed or job.pending.discarded or job.pending.digest~=digest
		or root.config_revision~=request.data.preparation.revision then return nil,"The exact saved settings and preparation approval are unavailable; no checks were accepted" end
	return clone(request.data.preparation),nil
end

-- Native UI operations share the same writer and optimistic revision fence.
function M.edit(binding,expected,operation,data)
	local root,err=read_root();if not root then return false,err end
	local scope=root.sessions[binding.session_key]
	if not scope or scope.authority_id~=binding.authority_id then return false,"stale-authority" end
	if expected~=root.config_revision then return false,"stale-config: settings were reloaded; review and repeat your edit" end
	root=clone(root);scope=root.sessions[binding.session_key]
	if operation=="review-choice" then
		if not root.review or type(data.id)~="string" or not integer(data.source,0) or data.source>#root.review.sources then return false,"Invalid review selection" end
		local found=false
		for index,source in ipairs(root.review.sources) do
			for _,record in ipairs(source.records) do if record.id==data.id and (data.source==0 or data.source==index) then found=true end end
		end
		if not found then return false,"Record is missing from the selected source" end
		root.review.choices[data.id]=data.source;root.config_revision+=1
	elseif operation=="review-confirm" then
		if not root.review then return false,"No pending migration review" end
		local ids={};local selected={}
		for _,source in ipairs(root.review.sources) do for _,record in ipairs(source.records) do ids[record.id]=true end end
		for id in pairs(ids) do
			local choice=root.review.choices[id]
			if choice==nil then return false,"Choose a source or explicitly omit record "..id end
			if choice~=0 then
				local found=nil
				for _,record in ipairs(root.review.sources[choice].records) do if record.id==id then found=record end end
				if not found then return false,"Selected source does not contain "..id end
				table.insert(selected,found)
			end
		end
		table.sort(selected,function(a,b)return a.id<b.id end)
		local canonical,why=Config.validate_records(selected);if not canonical then return false,why end
		root.config.hosts[root.host_key].agents=canonical;root.review=nil;root.config_revision+=1
	elseif root.review then return false,"Complete migration/source review first"
	elseif operation=="replace-records" then
		local canonical,why=Config.validate_records(data.records);if not canonical then return false,why end
		root.config.hosts[root.host_key].agents=canonical;root.config_revision+=1
	elseif operation=="clear-history" then
		if data.attempt_revision~=scope.launch.revision then return false,"Launch history changed; inspect the refreshed history before clearing it" end
		local registry,registry_error=managed_registry();if registry==nil then return false,registry_error end
		local removed,why=Launch.clear_history(scope.launch,settled_managed(registry,binding.session_key,scope));if removed==nil then return false,why end
		retain_jobs(scope)
	elseif operation=="review-reply" then
		if not scope.replies[data.id] then return false,"Result is no longer retained" end
		scope.replies[data.id]=nil;scope.requests[data.id]=nil
	elseif operation=="reset-transport" then
		local registry,registry_error=managed_registry()
		if registry==nil then return false,registry_error end
		if managed_references(registry,binding.session_key,scope,true) then return false,"Recover managed controllers, consumed authorizations and import gates before resetting transport" end
		if next(scope.replies)~=nil then return false,"Review every retained result before resetting transport" end
		-- Ordinary attempts settle themselves; only live work and managed
		-- reservations still owe a result to the current transport.
		for _,a in ipairs(scope.launch.attempts) do
			if a.phase=="Starting" or a.phase=="Running" or a.phase=="Waiting for input" or a.purpose=="managed" and a.unresolved then
				return false,"Wait until every live or managed attempt has ended before resetting transport"
			end
		end
		if root.next_authority>=MAX_INT then return false,"Authority identity capacity exhausted" end
		scope.authority_id=root.namespace..":"..tostring(root.next_authority);root.next_authority+=1;scope.request_sequences={}
	else return false,"Unknown settings operation" end
	local saved,why=persist(root)
	if saved and operation=="reset-transport" then binding.authority_id=scope.authority_id end
	return saved,why
end
-- Only a complete host-wide inventory can establish absence. Preview captures
-- eligible scopes before inspection; apply additionally requires those exact
-- scopes to remain unchanged. The caller's bound session is never removed.
function M.forget_sessions(binding,live,apply,captured)
	if type(live)~="table" or next(live)==nil then return nil,"Live host session inventory is unavailable; nothing was forgotten" end
	for id,present in pairs(live) do if not integer(id,0) or present~=true then return nil,"Live host session inventory is invalid; nothing was forgotten" end end
	if apply and type(captured)~="table" then return nil,"Pre-inspection session evidence is missing; nothing was forgotten" end
	local root,err=read_root();if not root then return nil,err end
	local scope=root.sessions[binding.session_key]
	if not scope or scope.authority_id~=binding.authority_id then return nil,"stale-authority" end
	local candidate=clone(root);local result={sessions=0,attempts=0,bytes=0,kept=0}
	local capture=if apply then nil else {}
	local ACTIVE={Starting=true,Running=true,["Waiting for input"]=true}
	local IN_FLIGHT={admitted=true,claimed=true,submission_intent=true,submitted=true,running=true}
	local registry,registry_error=managed_registry();if registry==nil then return nil,registry_error end
	for key,other in pairs(root.sessions) do
		if key~=binding.session_key and other.native_session~=binding.native_session and not live[other.native_session] then
			local busy=managed_references(registry,key,other,false)
			local settled=settled_managed(registry,key,other)
			for _,a in ipairs(other.launch.attempts) do if ACTIVE[a.phase] or a.unresolved or a.purpose=="managed" and not settled[a.id] then busy=true end end
			for _,job in pairs(other.jobs) do if IN_FLIGHT[job.stage] or job.pending and not job.pending.consumed then busy=true end end
			if busy or apply and not equal(captured[key],other) then result.kept+=1
			else
				if capture then capture[key]=candidate.sessions[key] end
				candidate.sessions[key]=nil;result.sessions+=1;result.attempts+=#other.launch.attempts
			end
		end
	end
	if result.sessions==0 then return result,nil,capture end
	local before,after=encoded(root,MAX_STORE_BYTES),encoded(candidate,MAX_STORE_BYTES)
	result.bytes=if before and after then #before-#after else 0
	if not apply then return result,nil,capture end
	local saved,why=persist(candidate);if not saved then return nil,why end
	return result,nil
end
-- Host execution is scoped to the durable namespace/session, not the UI transport
-- generation. Rotating request fences must never detach a running completion.
-- Native execution reads always return detached values from the validated store.
local function execution_scope(binding)
	local root,err=read_root();if not root then return nil,nil,err end
	local scope=if type(binding)=="table" then root.sessions[binding.session_key] else nil
	if not scope or root.host_key~=binding.host_key
		or scope.native_session~=binding.native_session then return nil,nil,"stale-authority" end
	return root,scope,nil
end
function M.record_launch_available(binding,id)
	local root,_,why=execution_scope(binding);if not root then return false,why end
	local problem=setup_launch_error(root,id)
	return problem==nil,problem
end
function M.execution_bindings()
	local ok,raw=pcall(tern.kv.get,"authority")
	if not ok then return nil,"Could not read authority: "..tostring(raw) end
	if raw==nil then return {} end
	local root,err=upgrade(raw);if not root then return nil,err end
	local result={}
	for key in pairs(root.sessions) do table.insert(result,binding_for(root,key)) end
	return result,nil
end
function M.execution_jobs(binding)
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	local result={}
	for _,a in ipairs(scope.launch.attempts) do if a.purpose~="managed" then
		local job=scope.jobs[a.id]
		if job.backend=="setup-default" then local value=public_job(job);value.admitted_at=job.admitted_at;table.insert(result,value)
		else table.insert(result,clone(job)) end
	end end
	return result,nil
end
function M.execution_job(binding,id)
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	return clone(scope.jobs[id]),nil
end
local function approved(root,job)
	return root.review==nil and root.config_revision==job.config_revision
end
-- The approved record is read from current configuration, never a job copy.
function M.execution_record(binding,id)
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	local job=scope.jobs[id];if not job then return nil,"missing-execution-job" end
	if job.backend=="setup-default" then return nil,"Setup defaults are not ordinary saved records" end
	if not approved(root,job) then return nil,"approval-revision-changed" end
	for _,record in ipairs(records(root)) do if record.id==job.record_id then return clone(record),nil end end
	return nil,"missing-record"
end
function M.claim_execution(binding,id,native)
	if not native_valid(native) then return nil,"invalid-native-binding" end
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	root,err=expire_admissions(root,os.time());if not root then return nil,err end
	scope=root.sessions[binding.session_key]
	local job=scope.jobs[id];local a=attempt(scope,id)
	if not job then return nil,"missing-execution-job" end
	if job.backend=="setup-default" then return nil,"Setup defaults require native API claim/begin/bind, never shell tickets" end
	if job.stage~="admitted" or a.phase~="Starting" or not a.unresolved then return nil,"stage-race" end
	if not approved(root,job) then return nil,"approval-revision-changed" end
	local candidate=clone(root);scope=candidate.sessions[binding.session_key];job=scope.jobs[id]
	local accepted,why=Launch.observe(scope.launch,id,{
		phase="Starting",pane=native.pane,scope=binding.session_key,
	})
	if not accepted then return nil,why end
	job.native=clone(native);job.stage="claimed"
	local saved,problem=persist(candidate);if not saved then return nil,problem end
	return clone(job),nil
end
-- "resolved" is entered only by the sweep (settle_attempt), never by the executor.
local PROGRESS={
	admitted={failed=true,unknown=true},
	claimed={submission_intent=true,failed=true,unknown=true},
	submission_intent={submitted=true,running=true,completed=true,unknown=true},
	submitted={running=true,completed=true,unknown=true},
	running={completed=true,unknown=true},
	unknown={running=true,completed=true},
	resolved={completed=true},completed={},failed={},
}
function M.update_execution(binding,id,expected_stage,patch,observation)
	if not fields(patch,{stage=true,native_tab=true,epoch=true,process_identity=true,command=true,pane_reused=true}) then return nil,"invalid-execution-patch" end
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	local job=scope.jobs[id];if not job then return nil,"missing-execution-job" end
	if job.backend=="setup-default" then return nil,"Setup defaults require their native API lifecycle" end
	if expected_stage~=job.stage then return nil,"stage-race" end
	local stage=patch.stage or job.stage
	if stage~=job.stage and not PROGRESS[job.stage][stage] then return nil,"illegal-execution-transition" end
	if patch.pane_reused~=nil and patch.pane_reused~=true then return nil,"pane-reused-is-monotonic" end
	for _,name in ipairs({"native_tab","epoch","process_identity"}) do
		local value=patch[name]
		if value~=nil then
			if job.native==nil or (name=="native_tab" and not integer(value,0))
				or (name~="native_tab" and not text(value,4096)) then return nil,"invalid-execution-metadata" end
			if job[name]~=nil and job[name]~=value then return nil,"immutable-execution-metadata" end
		end
	end
	local entering_submission=stage=="submission_intent" and job.stage~="submission_intent"
	if patch.command~=nil then
		if job.stage~="claimed" or stage~="submission_intent" or job.command~=nil or not bounded(patch.command,64000) then return nil,"immutable-execution-command" end
	end
	if entering_submission then
		local preparing=setup_launch_error(root,job.record_id);if preparing then return nil,preparing end
		if not approved(root,job) then return nil,"approval-revision-changed" end
		if patch.command==nil or job.pane_reused or patch.pane_reused then return nil,"submission-not-permitted" end
	end
	local candidate=clone(root);scope=candidate.sessions[binding.session_key];job=scope.jobs[id]
	local a=attempt(scope,id);local previous_revision=scope.launch.revision
	if observation~=nil then
		if type(observation)~="table" or (observation.pane~=nil and (not job.native or observation.pane~=job.native.pane))
			or (observation.scope~=nil and observation.scope~=binding.session_key) then return nil,"native-observation-mismatch" end
		local accepted,why=Launch.observe(scope.launch,id,observation)
		if not accepted then return nil,why end
	end
	for name,value in pairs(patch) do job[name]=clone(value) end
	-- Completed evidence cannot be replaced by wrapper liveness. Validation also
	-- couples every other stage to its matching Launch phase and native binding.
	if not job_valid(candidate,binding.session_key,scope,job,a) then return nil,"execution-observation-stage-mismatch" end
	if scope.launch.revision==previous_revision then
		if scope.launch.revision>=MAX_INT then return nil,"capacity" end
		scope.launch.revision+=1
	end
	local saved,why=persist(candidate);if not saved then return nil,why end
	return clone(job),nil
end
-- Ordinary attempts settle themselves from host-native evidence: this host's pane
-- inventory, its daemon epoch and the admission deadline. Managed attempts keep
-- their bridge rules. Settlement only rewrites SPAWN's records; it never closes a
-- pane or stops a program. panes maps pane id -> { title = PaneInfo.title }.
-- A claimed, not-yet-submitted job still has bounded native checks in flight;
-- only those checks or native lifecycle evidence can end it without a restart.
function M.sweep(binding,panes,epoch,now)
	if type(panes)~="table" then return nil,"Live pane inventory is unavailable; nothing was settled" end
	for pane,info in pairs(panes) do
		if not integer(pane,0) or type(info)~="table" or (info.title~=nil and type(info.title)~="string") then return nil,"Live pane inventory is invalid; nothing was settled" end
	end
	if epoch~=nil and not text(epoch,4096) then return nil,"Host epoch is invalid; nothing was settled" end
	if not integer(now,0) then return nil,"Sweep time is invalid; nothing was settled" end
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	local candidate=clone(root);scope=candidate.sessions[binding.session_key]
	local changed=0
	for _,a in ipairs(scope.launch.attempts) do
		local job=scope.jobs[a.id]
		if job and job.backend=="setup-default" then
			if a.phase=="Exited" or a.phase=="Failed" then continue end
			if job.native==nil and (job.stage=="admitted" or job.stage=="claimed") and now-job.admitted_at>=ADMISSION_SECONDS then
				local settled,why=settle_attempt(scope,a.id,"Failed","Never started (setup admission expired)")
				if not settled then return nil,why end
				changed+=1
			elseif job.native~=nil and panes[job.native.pane]==nil then
				local settled,why=settle_attempt(scope,a.id,"Exited","Setup native pane closed; automatic import is unavailable")
				if not settled then return nil,why end
				changed+=1
			elseif epoch~=nil and job.setup.origin_epoch~=nil and epoch~=job.setup.origin_epoch and job.stage~="unknown" then
				local accepted,why=Launch.observe(scope.launch,a.id,{phase="Unknown",scope=binding.session_key,error_category="unknown",
					diagnostic="Setup host restarted; native prompt delivery is not replayable"})
				if not accepted then return nil,why end
				job.stage="unknown";changed+=1
			end
			-- An unbound submission_intent is an unresolved native effect, NOT
			-- an expired ticket. No shell readoption or automatic retry exists.
			continue
		end
		if a.purpose~="managed" and a.phase~="Exited" and a.phase~="Failed" then
			local info=if a.pane~=nil then panes[a.pane] else nil
			local present=if a.pane~=nil then info~=nil else nil
			-- An unverifiable host epoch (nil) never counts as a restart.
			local restarted=epoch~=nil and job.epoch~=nil and job.epoch~=epoch
			local readopt=restarted and info~=nil and job.command~=nil and info.title==job.command
			local graced=restarted and job.restart_grace==epoch
			local phase,diagnostic=Launch.classify(a,{pane_present=present,epoch_changed=restarted,readopt=readopt,
				submission_pending=job.stage=="claimed",
				ticket_expired=job.native==nil and now-job.admitted_at>=ADMISSION_SECONDS,
				grace_used=graced and (job.restart_grace_at==nil or now-job.restart_grace_at>=RESTART_GRACE_SECONDS)})
			-- Recovery never resubmits, so a claim whose provider command was never
			-- submitted cannot become a running provider.
			if phase=="Running" and job.command==nil then phase,diagnostic="Failed","Never started (provider command was not submitted)" end
			if phase~=nil then
				local settled,why=settle_attempt(scope,a.id,phase,diagnostic);if not settled then return nil,why end
				-- A re-adopted pane runs a new provider process under the new daemon.
				if phase=="Running" and readopt then job.epoch=epoch;job.process_identity=nil end
				-- Kept on an attempt the restart ended, for the informational notice.
				if restarted and phase=="Exited" then
					if not graced then job.restart_grace_at=now end
					job.restart_grace=epoch
				else job.restart_grace=nil;job.restart_grace_at=nil end
				changed+=1
			elseif restarted and not graced then
				-- Restored panes and reruns appear after the host loads: the first
				-- sweep that sees the new epoch only starts the grace period.
				job.restart_grace=epoch;job.restart_grace_at=now;changed+=1
			end
		end
	end
	if changed==0 then return 0,nil end
	local saved,why=persist(candidate);if not saved then return nil,why end
	return changed,nil
end
-- Bridge effect identity is the immutable host/namespace/native-session tuple.
-- Reply transport rotation cannot invalidate an already granted native result.
function M.binding(native_session)
	local root,err=read_root();if not root then return nil,err end
	return M.open(root.host_key,native_session,nil,nil)
end
function M.managed_snapshot(binding)
	local root,_,err=execution_scope(binding);if not root then return nil,err end
	return snapshot_value(root,binding.session_key),nil
end
function M.managed_reserve(binding,revision,record_id,observer_id)
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	if not text(observer_id,256) or observer_id==execution_observer(root) then return nil,"invalid-managed-observer" end
	for _,a in ipairs(scope.launch.attempts) do
		if a.observer_id==observer_id then
			if a.purpose~="managed" or a.record_id~=record_id then return nil,"content_conflict" end
			return clone(a)
		end
	end
	if root.config_revision~=revision or root.review then return nil,"stale-config or migration-review-required" end
	local preparing=setup_launch_error(root,record_id);if preparing then return nil,preparing end
	local record=nil;for _,r in ipairs(records(root)) do if r.id==record_id then record=r end end
	if not record then return nil,"missing-record" end
	local candidate=clone(root)
	local a,why=Launch.reserve(candidate.sessions[binding.session_key].launch,record,binding.session_key,observer_id,"managed")
	if not a then return nil,why end
	local saved,save_error=persist(candidate);if not saved then return nil,save_error end
	return clone(a)
end
function M.managed_observe(binding,attempt_id,observer_id,observation)
	local root,scope,err=execution_scope(binding);if not root then return false,err end
	local prior=attempt(scope,attempt_id)
	if not prior or prior.purpose~="managed" or prior.observer_id~=observer_id then return false,"managed-observer-mismatch" end
	if type(observation)~="table" or observation.scope~=nil and observation.scope~=binding.session_key then return false,"scope-mismatch" end
	local candidate=clone(root)
	observation=clone(observation);observation.scope=binding.session_key
	local accepted,why=Launch.observe(candidate.sessions[binding.session_key].launch,attempt_id,observation)
	if not accepted then return false,why end
	return persist(candidate)
end
-- Only the bridge's exact stopped + retired journal invokes this settlement.
function M.managed_retire(binding,attempt_id,observer_id,record_id,pane)
	local root,scope,err=execution_scope(binding);if not root then return false,err end
	local prior=attempt(scope,attempt_id)
	if not prior or prior.purpose~="managed" or prior.observer_id~=observer_id or prior.record_id~=record_id or prior.scope~=binding.session_key or prior.pane~=pane then return false,"retirement-binding-mismatch" end
	if prior.phase=="Exited" and not prior.unresolved then return true end
	if prior.phase~="Starting" and prior.phase~="Running" and prior.phase~="Waiting for input" then return false,"retirement-reservation-uncertain" end
	local candidate=clone(root)
	local accepted,why=Launch.observe(candidate.sessions[binding.session_key].launch,attempt_id,{phase="Exited",scope=binding.session_key,pane=pane})
	if not accepted then return false,why end
	return persist(candidate)
end
-- Forget (SKILLS-205): the exact managed reservations a journal names, matched by observer identity and then by record, scope,
-- purpose and (when recorded) attempt id. A reservation held in any other shape is a conflict, never removed. Never settles or
-- retires an attempt and never touches the monotonic attempt counter.
local function forget_find(scope,key,item)
	for index,a in ipairs(scope.launch.attempts) do
		if a.observer_id==item.observer_id then
			if a.purpose~="managed" or a.record_id~=item.record_id or a.scope~=key or item.attempt_id~=nil and a.id~=item.attempt_id then return index,"conflict" end
			return index,"match"
		end
	end
	return nil,nil
end
function M.forget_reservation_conflicts(binding,journal)
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	local conflicts=0
	for _,item in ipairs(journal) do local _,kind=forget_find(scope,binding.session_key,item);if kind=="conflict" then conflicts+=1 end end
	return conflicts
end
function M.forget_reservations(binding,journal)
	local root,scope,err=execution_scope(binding);if not root then return false,err end
	if type(journal)~="table" then return false,"invalid-forget-journal" end
	local remove={}
	for _,item in ipairs(journal) do
		if type(item)~="table" or not text(item.observer_id,256) or not text(item.record_id,96) then return false,"invalid-forget-journal" end
		local index,kind=forget_find(scope,binding.session_key,item)
		if kind=="conflict" then return false,"forget-reservation-conflict" end
		if index then remove[index]=true end
	end
	if next(remove)==nil then return true end
	local candidate=clone(root)
	local launch=candidate.sessions[binding.session_key].launch
	local kept={}
	for index,a in ipairs(launch.attempts) do if not remove[index] then kept[#kept+1]=a end end
	if launch.revision>=9007199254740991 then return false,"capacity" end
	launch.attempts=kept;launch.revision+=1
	retain_jobs(candidate.sessions[binding.session_key])
	return persist(candidate)
end
function M.managed_import(binding,revision,request_id,source_records)
	if not text(request_id,256) then return nil,"invalid-import-request" end
	local canonical,why=Config.validate_records(source_records);if not canonical then return nil,why end
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	local prior=scope.managed_imports[request_id]
	if prior then
		if equal(prior,canonical) then return {imported=0,replayed=true} end
		return nil,"content_conflict"
	end
	if count(scope.managed_imports)>=64 then return nil,"managed-import-receipt-capacity" end
	if root.config_revision~=revision or root.review then return nil,"stale-config or migration-review-required" end
	local candidate=clone(root)
	local result,problem=import_records(candidate,canonical)
	if not result then return nil,problem end
	candidate.sessions[binding.session_key].managed_imports[request_id]=clone(canonical)
	local saved,save_error=persist(candidate);if not saved then return nil,save_error end
	return result
end
-- Legacy declarations enter through the current admitted SPAWN writer only.
function M.managed_declare_provider_families(binding,revision,declarations)
	local root,_,err=execution_scope(binding);if not root then return nil,err end
	if root.config_revision~=revision or root.review then return nil,"stale-config or migration-review-required" end
	if type(declarations)~="table" or #declarations<1 or #declarations>32 then return nil,"Invalid declarations" end
	if count(declarations)~=#declarations then return nil,"Declarations must be a dense array" end
	for index in pairs(declarations) do if not integer(index,1) or index>#declarations then return nil,"Declarations must be a dense array" end end
	local candidate=clone(root)
	local by_id={};for _,record in ipairs(records(candidate)) do by_id[record.id]=record end
	local seen,applied,families={},0,tern.json.array()
	for _,declaration in ipairs(declarations) do
		if not fields(declaration,{record_id=true,provider_family=true}) or not text(declaration.record_id,96) or not text(declaration.provider_family,96) then return nil,"Invalid provider declaration" end
		local record=by_id[declaration.record_id]
		if not record or seen[record.id] then return nil,"Missing or duplicate declared record" end
		seen[record.id]=true
		local family,why=Config.provider_family(record.provider,declaration.provider_family)
		if not family or why then return nil,why or "Underlying provider required" end
		if record.provider_family and record.provider_family~=family then return nil,"Conflicting underlying provider for "..record.id end
		if not record.provider_family then record.provider_family=family;applied+=1 end
		table.insert(families,{record_id=record.id,provider_family=record.provider_family})
	end
	if applied>0 then
		candidate.config_revision+=1
		local saved,why=persist(candidate);if not saved then return nil,why end
	end
	return {config_revision=candidate.config_revision,applied=applied,families=families}
end
return M
