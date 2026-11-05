-- Host-only single writer. Admission is one atomic write; execution claims are explicit.
local Config = require("./config")
local Launch = require("./launch_state")
local M = {}
local MAX_BYTES = 120000
local STORAGE_VERSION = 3
local SNAPSHOT_PREFIX = "SPAWN_STATE_V2 "
local ADMISSION_SECONDS = 30
M.ADMISSION_SECONDS = ADMISSION_SECONDS
local KEEP_FINISHED = 26
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
local function encoded(value)
	local ok, json = pcall(tern.json.encode, value)
	if not ok or #json > MAX_BYTES then return nil, "capacity: encoded state exceeds 120000 bytes" end
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
	local checked,valid,why=pcall(function() return require("./dispatch").validate_registry(registry) end)
	if not checked or not valid then return nil,if checked then why else "Managed dispatch registry is invalid; preserve it" end
	for _,owner in pairs(registry.owners) do
		if not text(owner.authority,256) or not integer(owner.host_session,0) then return nil,"Managed owner identity is invalid; preserve it" end
	end
	for _,entry in pairs(registry.requests) do
		for _,binding in ipairs({entry.binding or false,entry.authorization and entry.authorization.binding or false}) do
			if binding~=false and (type(binding)~="table" or not text(binding.session_key,2048) or not text(binding.authority_id,256) or not text(binding.host_key,1024) or not integer(binding.native_session,0)) then return nil,"Managed request authority binding is invalid; preserve it" end
		end
	end
	return registry
end
local function unsettled(entry)
	local status=entry.body.status
	if entry.retirement_result~=nil or status=="pending" or status=="uncertain" or status=="claimed" or status=="launching" then return true end
	if status=="resolved" and (entry.request.op=="launch" or entry.request.op=="adopt" or entry.request.op=="stop" or entry.request.op=="native_wake") then return true end
	local wake=entry.wake
	return wake~=nil and (wake.request_id~=nil and wake.phase~="submitted" or wake.phase~="resolved" and wake.phase~="submitted")
end
local function linked_launch(registry,entry)
	-- Native wake may reference a publication which in turn names its launch.
	for _=1,3 do
		if entry.request.op=="launch" or entry.request.op=="adopt" then return entry end
		local r=entry.request
		local id=r.launch_request_id or r.target_request_id
		if not id then return nil end
		entry=registry.requests[r.origin_binding.logical_session_id.."/"..id]
		if not entry then return nil end
	end
	return nil
end
local function settled_managed(registry,key,scope)
	local settled={}
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
	for _,entry in pairs(registry.requests) do
		if unsettled(entry) then
			protect(linked_launch(registry,entry))
		end
	end
	for _,generation in pairs(registry.mailboxes.generations) do
		if generation.status~="retired" or generation.active~=nil then
			local b=generation.binding
			protect(registry.requests[b.logical_session_id.."/"..b.launch_request_id])
		end
	end
	return settled
end
local function managed_references(registry,key,scope,reset)
	if registry==false then return false end
	local identity=scope.managed_authority_id or scope.authority_id
	for _,owner in pairs(registry.owners) do if owner.authority==identity and owner.host_session==scope.native_session then return true end end
	-- Tombstones fence old origins in the bridge, but do not by themselves
	-- require an otherwise wholly settled native-session ledger.
	for _,entry in pairs(registry.requests) do
		local launch=if not reset and unsettled(entry) then linked_launch(registry,entry) else nil
		if not reset and unsettled(entry) and (entry.binding and entry.binding.session_key==key or launch and launch.binding and launch.binding.session_key==key) then return true end
		local a=entry.authorization
		if a and a.binding.session_key==key and (reset and a.phase=="consumed" or not reset and unsettled(entry)) then return true end
	end
	for _,gate in pairs(registry.gates) do
		if gate.binding.session_key==key and (not gate.consumed or not gate.outcome or gate.outcome.status=="uncertain") then return true end
	end
	for _,generation in pairs(registry.mailboxes.generations) do
		if generation.status~="retired" then
			local logical=generation.binding.logical_session_id
			local associated=false
			local owner=registry.owners[logical]
			if owner then
				associated=true
				if owner.authority==identity and owner.host_session==scope.native_session then return true end
			end
			for _,retired in ipairs(registry.tombstones) do
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
local function public_job(job)
	local value={
		id=job.id,attempt_id=job.attempt_id,record_id=job.record_id,purpose=job.purpose,
		config_revision=job.config_revision,observer_id=job.observer_id,session_key=job.session_key,
		native_session=job.native_session,token=job.token,ticket=job.ticket,stage=job.stage,
		provider=job.provider,account_label=job.account_label,backend=job.backend,placement=job.placement,cwd=job.cwd,
		pane_reused=job.pane_reused,setup_run_id=job.setup_run_id,initial_prompt=job.initial_prompt,
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
		pane_reused=true,setup_run_id=true,initial_prompt=true,native=true,native_tab=true,epoch=true,process_identity=true,command=true}) then
		return false
	end
	if job.id~=a.id or job.attempt_id~=a.id or job.record_id~=a.record_id
		or job.session_key~=key or job.native_session~=scope.native_session
		or a.observer_id~=execution_observer(root) or not integer(job.admitted_at,0)
		or job.token~=key..":"..job.id or not integer(job.config_revision,0) or job.config_revision>root.config_revision then return false end
	if (a.purpose or "launch")~=job.purpose then return false end
	if Launch.validate_execution_projection(public_job(job))==nil then return false end
	local mode=if job.backend=="native-agent" then "Native OMP" elseif job.backend=="ssh-command" then "SSH terminal" else "Terminal"
	if a.mode~=mode then return false end
	if job.native~=nil then
		if not native_valid(job.native) or a.pane~=job.native.pane then return false end
	elseif a.pane~=nil or job.native_tab~=nil or job.epoch~=nil or job.process_identity~=nil or job.command~=nil then return false end
	if job.epoch~=nil and not text(job.epoch,4096) then return false end
	if job.process_identity~=nil and not text(job.process_identity,4096) then return false end
	if job.command~=nil and not bounded(job.command,64000) then return false end
	local stage=job.stage
	if stage=="admitted" then return a.phase=="Starting" and job.native==nil and not job.pane_reused end
	if stage=="claimed" then return a.phase=="Starting" and job.native~=nil and job.command==nil end
	if stage=="submission_intent" or stage=="submitted" then return a.phase=="Starting" and job.native~=nil and job.command~=nil end
	if stage=="running" then return (a.phase=="Running" or a.phase=="Waiting for input") and job.native~=nil and job.command~=nil end
	if stage=="completed" then return (a.phase=="Exited" or a.phase=="Failed") and job.native~=nil and job.command~=nil end
	if stage=="failed" then return a.phase=="Failed" end
	if stage=="unknown" then return a.phase=="Unknown" and a.unresolved end
	if stage=="resolved" then return a.phase=="Unknown" and not a.unresolved end
	return false
end
local OPS = {refresh = {}, import_records = {setup_run_id=true, records=true}, launch_record = {record_id=true}, start_setup = {record_id=true,setup_run_id=true}, resolve_attempt = {attempt_id=true,attempt_revision=true}}
local function request_valid(r)
	if not fields(r, {version=true,request_id=true,authority_id=true,observer_id=true,request_sequence=true,acknowledged_requests=true,expected_config_revision=true,op=true,data=true}) or r.version ~= 2 then return false end
	if not text(r.request_id, 256) or not text(r.authority_id, 256) or not text(r.observer_id, 256) or not integer(r.request_sequence, 1) or not integer(r.expected_config_revision, 0) then return false end
	if not array(r.acknowledged_requests, 64) or type(r.op) ~= "string" or OPS[r.op] == nil or not fields(r.data, OPS[r.op]) then return false end
	local seen = {}
	for _, id in ipairs(r.acknowledged_requests) do if not text(id,256) or seen[id] then return false end seen[id]=true end
	local d = r.data
	if r.op == "import_records" then return text(d.setup_run_id,256) and Config.validate_records(d.records) ~= nil end
	if r.op == "launch_record" then return text(d.record_id,96) end
	if r.op == "start_setup" then return text(d.record_id,96) and text(d.setup_run_id,256) end
	if r.op == "resolve_attempt" then return text(d.attempt_id,96) and integer(d.attempt_revision,0) end
	return true
end
local function result_valid(reply,request,key,native_session)
	if not reply.ok then return type(reply.error)=="string" and #reply.error>0 and #reply.error<=4096 and reply.result==nil end
	if reply.error~=nil then return false end
	local result=reply.result
	if request.op=="refresh" then return fields(result,{}) end
	if request.op=="import_records" then return fields(result,{imported=true,replayed=true}) and integer(result.imported,0) and result.imported<=32 and (result.replayed==nil or type(result.replayed)=="boolean") end
	local is_launch=request.op=="launch_record" or request.op=="start_setup"
	local allowed=if is_launch then {attempt=true,job=true,replayed=true} else {attempt=true}
	if not fields(result,allowed) or type(result.attempt)~="table" then return false end
	local a=result.attempt
	local digits=if type(a.id)=="string" then a.id:match("^attempt%-(%d+)$") else nil
	local id=if digits then tonumber(digits) else nil
	if not integer(id,1) or a.scope~=key or Launch.validate({version=1,next_attempt=id+1,revision=reply.attempt_revision,attempts={a}})==nil then return false end
	if is_launch then
		local job=Launch.validate_execution_projection(result.job)
		if not job or job.id~=a.id or job.record_id~=request.data.record_id or a.record_id~=job.record_id
			or job.observer_id~=request.observer_id or job.session_key~=key or job.native_session~=native_session
			or job.config_revision>reply.config_revision or job.token~=key..":"..job.id
			or (result.replayed~=nil and result.replayed~=true) then return false end
		if request.op=="start_setup" then return job.purpose=="setup" and job.setup_run_id==request.data.setup_run_id end
		return job.purpose=="launch"
	end
	return a.id==request.data.attempt_id
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
	if not fields(root,{version=true,namespace=true,next_authority=true,host_key=true,config=true,config_revision=true,sessions=true,review=true,reviewed_sources=true}) or root.version ~= STORAGE_VERSION then return nil,"Unsupported or corrupt authority storage format; expected version 3. Preserve it and use a compatible version" end
	if not text(root.namespace,128) or not text(root.host_key,1024) or not integer(root.next_authority,1) or not integer(root.config_revision,0) or type(root.sessions)~="table" or type(root.reviewed_sources)~="table" then return nil,"Corrupt authority identity" end
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
			if not text(id,256) or Config.validate_records(receipt)==nil then return nil,"Corrupt managed import receipt" end
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
				if not job_valid(root,key,scope,job,a) then return nil,"Corrupt execution job or attempt association" end
			end
		end
		if count(scope.jobs)~=ordinary then return nil,"Execution job capacity mismatch" end
		if type(scope.replies)~="table" or type(scope.requests)~="table" or type(scope.request_sequences)~="table" then return nil,"Corrupt authority transport" end
		if count(scope.replies)>64 or count(scope.request_sequences)>64 or count(scope.requests)~=count(scope.replies) then return nil,"Transport capacity or result mismatch" end
		for observer, seq in pairs(scope.request_sequences) do if not text(observer,256) or not integer(seq,1) then return nil,"Corrupt request watermark" end end
		for id, reply in pairs(scope.replies) do
			local req=scope.requests[id]
			if not request_valid(req) or req.authority_id~=scope.authority_id or req.request_id~=id or not fields(reply,{request_id=true,observer_id=true,request_sequence=true,ok=true,error=true,config_revision=true,attempt_revision=true,result=true}) or reply.request_id~=id or reply.observer_id~=req.observer_id or reply.request_sequence~=req.request_sequence or type(reply.ok)~="boolean" or not integer(reply.config_revision,0) or not integer(reply.attempt_revision,0) or (scope.request_sequences[reply.observer_id] or 0)<reply.request_sequence then return nil,"Corrupt retained result" end
			if reply.config_revision>root.config_revision or reply.attempt_revision>scope.launch.revision or not result_valid(reply,req,key,scope.native_session) then return nil,"Corrupt result payload" end
		end
	end
	if root.review ~= nil then
		if not fields(root.review,{sources=true,choices=true,reason=true}) or not array(root.review.sources,64) or type(root.review.choices)~="table" or type(root.review.reason)~="string" then return nil,"Corrupt migration review" end
		for _, source in ipairs(root.review.sources) do if not fields(source,{label=true,records=true}) or not text(source.label,256) or Config.validate_records(source.records)==nil then return nil,"Corrupt migration source" end end
		local ids={}
		for _,source in ipairs(root.review.sources) do for _,record in ipairs(source.records) do ids[record.id]=true end end
		for id,choice in pairs(root.review.choices) do
			if not ids[id] or not integer(choice,0) or choice>#root.review.sources then return nil,"Corrupt migration selection" end
		end
	end
	local bytes, size_err=encoded(root)
	if not bytes then return nil,size_err end
	return root
end
M.validate=validate
-- Only exact immutable bridge references establish managed purpose in v1.
-- Unknown ordinary executions and pending old transport require their old writer.
local function upgrade(raw)
	if type(raw)~="table" or raw.version~=1 then return validate(raw) end
	local registry,why=managed_registry();if registry==nil then return nil,why end
	-- Never-created is distinct from lost initialized storage. Empty legacy
	-- scopes need no bridge evidence; actual attempts still require exact matches.
	if registry==false then registry={requests={},gates={}} end
	local candidate=clone(raw)
	if not fields(candidate,{version=true,namespace=true,next_authority=true,host_key=true,config=true,config_revision=true,sessions=true,review=true,reviewed_sources=true})
		or not text(candidate.namespace,128) or type(candidate.sessions)~="table" or type(candidate.reviewed_sources)~="table" then return nil,"Corrupt detached authority" end
	local Codec=require("./codec")
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
			for request_key,entry in pairs(registry.requests) do
				local b=entry.binding;local r=entry.request
				if r.op=="launch" and entry.launch and b and b.session_key==key and b.authority_id==scope.authority_id and b.host_key==candidate.host_key and b.native_session==native
					and entry.observer_id==a.observer_id and entry.observer_id=="managed-"..Codec.sha256(request_key)
					and r.record_id==a.record_id and (entry.attempt_id==a.id or entry.attempt_id==nil and entry.attempt_pending==true) then
					if entry.pane_binding and tonumber(entry.pane_binding.pane_id)~=a.pane then return nil,"Detached managed pane evidence differs from launch ledger" end
					matched+=1
				end
			end
			if matched~=1 or a.scope~=key or a.purpose~=nil then return nil,"Detached attempt lacks one exact managed launch reference; preserve and review with its original version" end
			a.purpose="managed"
		end
		if count(scope.imports)>64 then return nil,"Detached import receipt capacity exhausted" end
		for id,receipt in pairs(scope.imports) do
			if not text(id,256) or Config.validate_records(receipt)==nil then return nil,"Corrupt detached import receipt" end
			if id:sub(1,7)=="bridge-" then
				local matched=false
				for _,gate in pairs(registry.gates) do
					local b=gate.binding
					if id=="bridge-"..gate.request.request_id and b.session_key==key and b.host_key==candidate.host_key and b.native_session==native and equal(gate.records,receipt) and gate.consumed then matched=true end
				end
				if not matched then return nil,"Detached managed import receipt lacks an exact consumed gate; preserve it for review" end
				scope.managed_imports[id]=receipt
			end
			-- Settled ordinary setup receipts are obsolete under v2 identical-
			-- record imports. The exact original backup retains them; never replay.
		end
		scope.inbox=nil;scope.imports=nil
	end
	for id,source in pairs(candidate.reviewed_sources) do candidate.reviewed_sources[id]={host_key=candidate.host_key,config=source} end
	candidate.version=STORAGE_VERSION
	local valid,err=validate(candidate);if not valid then return nil,err end
	local saved,problem=pcall(function()
		local original=tern.kv.get("managed-v1-original")
		if original~=nil and not equal(original,raw) then error("Original detached authority backup differs; preserve both before upgrading") end
		if original==nil then tern.kv.set("managed-v1-original",clone(raw)) end
	end)
	if not saved then return nil,"Could not preserve detached authority: "..tostring(problem) end
	return candidate
end
local function read_root()
	local ok,value=pcall(tern.kv.get,"authority")
	if not ok then return nil,"Could not read authority: "..tostring(value) end
	if value==nil then return nil,"Authority has not been initialized" end
	return upgrade(value)
end
local function snapshot_value(root,key)
	local scope=root.sessions[key]
	return {version=2,namespace=root.namespace,host_key=root.host_key,authority_id=scope.authority_id,session_key=key,
		config_revision=root.config_revision,records=clone(root.config.hosts[root.host_key].agents),
		attempt_revision=scope.launch.revision,attempts=clone(scope.launch.attempts),jobs=public_jobs(scope),
		replies=clone(scope.replies),request_sequences=clone(scope.request_sequences),
		host_os=tern.runtime.os,host_shell=tern.getenv("SHELL") or tern.getenv("ComSpec") or "unknown",
		ready=root.review==nil,migration=clone(root.review),
		error=if root.review then "Migration or legacy source review required in Config" else nil}
end
local function capacity(root)
	local valid,err=validate(root)
	if not valid then return false,err end
	-- Snapshot overhead is checked as well as the larger durable value.
	for key, scope in pairs(root.sessions) do
		local value=snapshot_value(root,key)
		local json=encoded(value)
		if not json or #SNAPSHOT_PREFIX+#json>MAX_BYTES then return false,"Snapshot capacity exhausted; nothing saved" end
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
	local registry=managed_registry()
	for key,scope in pairs(root.sessions) do
		local removed,trim_err=Launch.trim_history(scope.launch,KEEP_FINISHED,settled_managed(registry,key,scope))
		if removed==nil then return false,trim_err end
		if removed>0 then retain_jobs(scope) end
	end
	local valid,err=capacity(root)
	if not valid then return false,err end
	local ok,why=pcall(tern.kv.set,"authority",root)
	if not ok then return false,"Could not save authority; previous state retained: "..tostring(why) end
	return true
end
local function expire_admissions(root,now)
	local candidate=nil
	for key,scope in pairs(root.sessions) do
		for id,job in pairs(scope.jobs) do
			if job.stage=="admitted" and now-job.admitted_at>=ADMISSION_SECONDS then
				candidate=candidate or clone(root)
				local next_scope=candidate.sessions[key]
				local accepted,why=Launch.observe(next_scope.launch,id,{
					phase="Unknown",error_category="unknown",
					diagnostic="The launch ticket was not claimed within 30 seconds. No provider submission is proven; inspect and explicitly resolve it. The ticket will not be allocated or sent again.",
				})
				if not accepted then return nil,why end
				next_scope.jobs[id].stage="unknown"
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
function M.open(host_key,native_session,client_config,origin_scope)
	if not text(host_key,1024) or not integer(native_session,0) then return nil,"A verified execution host and native session are required" end
	local ok,raw=pcall(tern.kv.get,"authority")
	if not ok then return nil,tostring(raw) end
	local root,err
	if raw==nil then
		if origin_scope~=nil then return nil,"Saved authority is missing; restore its original state instead of resetting reservations" end
		local got,original=pcall(tern.kv.get,"config")
		if not got then return nil,"Could not read original configuration: "..tostring(original) end
		local sources; sources,err=source_records(original,host_key,"Execution host")
		if not sources then return nil,err end
		local migrated=Config.migrate(original,host_key)
		local base=if migrated then migrated.store else {schema=2,hosts=clone(original.hosts)}
		if not migrated then base.hosts[host_key]={schema=2,agents=sources[1].records} end
		-- Durable collision-resistant naming, not a credential or security token.
		-- Monotonic VM time alone repeats when a fresh host runtime starts.
		local namespace=string.format("host-%d-%08x-%08x-%08x-%s",os.time(),math.random(1,2147483647),math.random(1,2147483647),math.random(1,2147483647),tostring(native_session))
		root={version=STORAGE_VERSION,namespace=namespace,next_authority=1,host_key=host_key,config=base,config_revision=0,sessions={},reviewed_sources={}}
		if original~=nil then
			local backed,why=backup("migration-original",original)
			if not backed then return nil,why end
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

local function dispatch(root,key,r,now)
	local scope=root.sessions[key];local d=r.data
	if r.expected_config_revision~=root.config_revision then return nil,"stale-config" end
	if root.review then return nil,"migration-review-required" end
	if r.op=="refresh" then return {} end
	if r.op=="import_records" then
		local validated,err=Config.validate_records(d.records);if not validated then return nil,err end
		-- Identical records are skipped, so a redelivered import is idempotent.
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
	elseif r.op=="launch_record" or r.op=="start_setup" then
		local setup=r.op=="start_setup"
		local record=nil
		for _,value in ipairs(records(root)) do if value.id==d.record_id then record=value end end
		if not record then return nil,"missing-record" end
		if setup and (record.backend~="native-agent" or string.lower(record.provider)~="omp") then return nil,"Guided setup requires a reviewed Native OMP account" end
		if not setup and record.backend=="native-agent" and (not record.prompt or not record.prompt:find("%S")) then return nil,"review: approve this account's startup prompt in Config" end
		local initial_prompt=nil
		if setup then
			local why;initial_prompt,why=Config.setup_prompt(records(root),d.setup_run_id,root.host_key,key)
			if not initial_prompt then return nil,why end
		end
		local purpose=if setup then "setup" else "launch"
		local a,err=Launch.reserve(scope.launch,record,key,execution_observer(root),purpose)
		if not a then return nil,if err=="skip" then (if record.enabled==false then "disabled" else "duplicate") else err end
		local token=key..":"..a.id
		local job={id=a.id,attempt_id=a.id,record_id=record.id,purpose=purpose,
			config_revision=root.config_revision,observer_id=r.observer_id,session_key=key,native_session=scope.native_session,
			token=token,ticket="exit 125 # SPAWN:"..token,stage="admitted",
			admitted_at=now,pane_reused=false,setup_run_id=if setup then d.setup_run_id else nil,initial_prompt=initial_prompt}
		for name,value in pairs(display(record,purpose)) do job[name]=value end
		scope.jobs[job.id]=job
		return {attempt=clone(a),job=public_job(job)}
	elseif r.op=="resolve_attempt" then
		if d.attempt_revision~=scope.launch.revision then return nil,"stale-attempt-revision" end
		local accepted,err=Launch.resolve(scope.launch,d.attempt_id)
		if not accepted then return nil,err end
		local a=attempt(scope,d.attempt_id)
		if a.phase=="Unknown" and scope.jobs[d.attempt_id] then scope.jobs[d.attempt_id].stage="resolved" end
		return {attempt=attempt(scope,d.attempt_id)}
	end
	return nil,"unsupported-operation"
end
function M.request(binding,input)
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
		local value,dispatch_err=dispatch(candidate,key,input,now)
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
function M.snapshot(binding)
	local root,err=read_root();if not root then return nil,err end
	local scope=root.sessions[binding.session_key]
	if not scope or scope.authority_id~=binding.authority_id then return nil,"stale-authority; reopen Config" end
	root,err=expire_admissions(root,os.time());if not root then return nil,err end
	return snapshot_value(root,binding.session_key),nil
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
	elseif operation=="resolve-attempt" then
		if data.attempt_revision~=scope.launch.revision then return false,"stale-attempt-revision: inspect the refreshed attempt before marking it no longer running" end
		local accepted,why=Launch.resolve(scope.launch,data.id);if not accepted then return false,why end
		if attempt(scope,data.id).phase=="Unknown" and scope.jobs[data.id] then scope.jobs[data.id].stage="resolved" end
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
		for _,a in ipairs(scope.launch.attempts) do
			if a.unresolved or (a.phase~="Exited" and a.phase~="Failed" and a.phase~="Unknown") then
				return false,"Resolve every active or unresolved attempt before resetting transport"
			end
		end
		if root.next_authority>=MAX_INT then return false,"Authority identity capacity exhausted" end
		scope.authority_id=root.namespace..":"..tostring(root.next_authority);root.next_authority+=1;scope.request_sequences={}
	else return false,"Unknown settings operation" end
	local saved,why=persist(root)
	if saved and operation=="reset-transport" then binding.authority_id=scope.authority_id end
	return saved,why
end
-- Forgets session buckets of this host whose native session is absent from the
-- host-verified live inventory. The caller's bound session is never removed.
-- With apply=false this only reports what would be forgotten.
function M.forget_sessions(binding,live,apply)
	if type(live)~="table" or next(live)==nil then return nil,"Live host session inventory is unavailable; nothing was forgotten" end
	for id,present in pairs(live) do if not integer(id,0) or present~=true then return nil,"Live host session inventory is invalid; nothing was forgotten" end end
	local root,err=read_root();if not root then return nil,err end
	local scope=root.sessions[binding.session_key]
	if not scope or scope.authority_id~=binding.authority_id then return nil,"stale-authority" end
	local candidate=clone(root);local result={sessions=0,attempts=0,bytes=0,kept=0}
	-- Inspection is per window: a session absent here may be live elsewhere, so
	-- any active attempt or in-flight execution keeps it.
	local ACTIVE={Starting=true,Running=true,["Waiting for input"]=true}
	local IN_FLIGHT={admitted=true,claimed=true,submission_intent=true,submitted=true,running=true}
	local registry,registry_error=managed_registry();if registry==nil then return nil,registry_error end
	for key,other in pairs(root.sessions) do
		if key~=binding.session_key and other.native_session~=binding.native_session and not live[other.native_session] then
			local busy=managed_references(registry,key,other,false)
			local settled=settled_managed(registry,key,other)
			for _,a in ipairs(other.launch.attempts) do if ACTIVE[a.phase] or a.unresolved or a.purpose=="managed" and not settled[a.id] then busy=true end end
			for _,job in pairs(other.jobs) do if IN_FLIGHT[job.stage] then busy=true end end
			if busy then result.kept+=1
			else candidate.sessions[key]=nil;result.sessions+=1;result.attempts+=#other.launch.attempts end
		end
	end
	if result.sessions==0 then return result,nil end
	local before,after=encoded(root),encoded(candidate)
	result.bytes=if before and after then #before-#after else 0
	if not apply then return result,nil end
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
	for _,a in ipairs(scope.launch.attempts) do if a.purpose~="managed" then table.insert(result,clone(scope.jobs[a.id])) end end
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
local PROGRESS={
	admitted={failed=true,unknown=true,resolved=true},
	claimed={submission_intent=true,failed=true,unknown=true,resolved=true},
	submission_intent={submitted=true,running=true,completed=true,unknown=true,resolved=true},
	submitted={running=true,completed=true,unknown=true,resolved=true},
	running={completed=true,unknown=true,resolved=true},
	unknown={running=true,completed=true,resolved=true},
	resolved={completed=true},completed={},failed={},
}
function M.update_execution(binding,id,expected_stage,patch,observation)
	if not fields(patch,{stage=true,native_tab=true,epoch=true,process_identity=true,command=true,pane_reused=true}) then return nil,"invalid-execution-patch" end
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
	local job=scope.jobs[id];if not job then return nil,"missing-execution-job" end
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
	if patch.command~=nil and (job.stage~="claimed" or stage~="submission_intent" or job.command~=nil or not bounded(patch.command,64000)) then return nil,"immutable-execution-command" end
	if stage=="submission_intent" and job.stage~="submission_intent" then
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
	if stage=="resolved" and job.stage~="resolved" then
		local accepted,why=Launch.resolve(scope.launch,id);if not accepted then return nil,why end
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
-- Bridge effect identity is the immutable host/namespace/native-session tuple.
-- Reply transport rotation cannot invalidate an already granted native result.
function M.binding(native_session)
	local root,err=read_root();if not root then return nil,err end
	return M.open(root.host_key,native_session,nil,nil)
end
function M.managed_snapshot(binding)
	local root,scope,err=execution_scope(binding);if not root then return nil,err end
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
	local candidate=clone(root)
	local result,problem=dispatch(candidate,binding.session_key,{op="import_records",expected_config_revision=revision,data={setup_run_id=request_id,records=canonical}},os.time())
	if not result then return nil,problem end
	candidate.sessions[binding.session_key].managed_imports[request_id]=clone(canonical)
	local saved,save_error=persist(candidate);if not saved then return nil,save_error end
	return result
end
return M
