-- Native Tern runner; only KV durability and the identity clock are injected.
local root, section = ...
assert(type(root) == "string", "pass the package directory")
assert(type(section) == "string", "pass an explicit test section")
local runtime, environment = tern, getfenv()
local checks = 0
local function check(condition, message)
	assert(condition, message)
	checks += 1
end
local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = copy(item) end
	return result
end
local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, item in pairs(left) do if not equal(item, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end
local function same(left, right, message) check(equal(left, right), message) end
local function count(value)
	local n = 0
	for _ in pairs(value) do n += 1 end
	return n
end
local function record(id, fields)
	local value = {
		id = id, provider = "custom", account_label = id, backend = "local-terminal",
		command = "ordinary-cli", arguments = {}, enabled = true, include_all = true, placement = "tab",
	}
	for key, item in pairs(fields or {}) do value[key] = item end
	return value
end
local function boundary(seed)
	local saved = copy(seed or {})
	local db = { writes = 0, authority_writes = 0, now = 1700000000 }
	db.kv = {
		get = function(key)
			if db.fail_get == key then error("injected read failure") end
			return copy(saved[key])
		end,
		set = function(key, value)
			db.writes += 1
			if key == "authority" then
				db.authority_writes += 1
				if db.fail_authority_at == db.authority_writes then error("injected atomic write failure") end
			end
			if db.fail_set == key then error("injected atomic write failure") end
			saved[key] = copy(value)
		end,
	}
	function db.peek(key) return copy(saved[key]) end
	function db.image() return copy(saved) end
	function db.fail_after(n) db.fail_authority_at = db.authority_writes + n end
	return db
end
local function modules(db)
	local injected = setmetatable({ kv = db.kv }, { __index = runtime })
	local clock = setmetatable({ time = function() return db.now end }, { __index = os })
	local loaded = {}
	local function load(name)
		name = name:gsub("^%./", "")
		if loaded[name] ~= nil then return loaded[name] end
		local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
		setfenv(chunk, setmetatable({ require = load, tern = injected, os = clock }, { __index = environment }))
		local result = chunk()
		loaded[name] = result
		return result
	end
	return load("authority"), load("config"), load("launch_state"), load
end
local function snapshot(authority, binding)
	local value, err = authority.snapshot(binding)
	assert(value, tostring(err))
	return value
end
local function edit(authority, binding, operation, data)
	local view = snapshot(authority, binding)
	local ok, err = authority.edit(binding, view.config_revision, operation, data or {})
	check(ok, "accept deliberate " .. operation .. ": " .. tostring(err))
end
local function fresh(records)
	local db = boundary()
	local authority, config, launch, load = modules(db)
	local binding, err = authority.open("host-A", 4)
	assert(binding, tostring(err))
	if records then edit(authority, binding, "replace-records", { records = records }) end
	return db, authority, binding, config, launch, load
end
local function request(binding, observer, sequence, revision, op, data, acknowledged)
	return {
		version = 2, request_id = observer .. "/" .. tostring(sequence), authority_id = binding.authority_id,
		observer_id = observer, request_sequence = sequence, acknowledged_requests = acknowledged or {},
		expected_config_revision = revision, op = op or "refresh", data = data or {},
	}
end
local function reserve_request(binding, observer, sequence, revision, id)
	return request(binding, observer, sequence, revision, "launch_record", { record_id = id })
end
local function submit(authority, binding, value)
	local ok, err = authority.request(binding, value)
	check(ok, "request admitted and committed: " .. tostring(err))
	local reply = snapshot(authority, binding).replies[value.request_id]
	check(reply ~= nil, "committed request retains its reply")
	return reply
end
local function refused_unchanged(db, action, message, reason)
	local before = db.image()
	local ok, err = action()
	check(not ok and type(err) == "string" and #err > 0, message .. " refuses with an error")
	if reason then check(err == reason, message .. " reports its domain reason") end
	same(db.image(), before, message .. " preserves every durable value")
end
local function native(pane)
	return { pane = pane or 42, window_key = "", program = "/bin/bash", executable = "/opt/tern", socket = "/tmp/tern.sock" }
end
local function claim(authority, binding, id, pane)
	local job, err = authority.claim_execution(binding, id, native(pane))
	check(job ~= nil, "host claims immutable native pane: " .. tostring(err))
	return job
end
local function update(authority, binding, id, stage, patch, observation)
	local job, err = authority.update_execution(binding, id, stage, patch, observation)
	check(job ~= nil, "host commits execution evidence: " .. tostring(err))
	return job
end
-- Admits launches from one observer, acknowledging each previous reply.
local function admitter(authority, binding, observer)
	observer = observer or "window"
	local sequence = 0
	return function(record_id)
		sequence += 1
		local acks = if sequence > 1 then { observer .. "/" .. tostring(sequence - 1) } else {}
		local revision = snapshot(authority, binding).config_revision
		local reply = submit(authority, binding, request(binding, observer, sequence, revision, "launch_record", { record_id = record_id }, acks))
		check(reply.ok, "admit " .. record_id .. ": " .. tostring(reply.error))
		return reply.result.attempt.id
	end
end
-- Claims a pane, records the daemon epoch, submits and observes the provider running.
local function run_job(authority, binding, id, pane, epoch)
	claim(authority, binding, id, pane)
	if epoch then update(authority, binding, id, "claimed", { epoch = epoch }) end
	update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	update(authority, binding, id, "submission_intent", { stage = "running" }, { phase = "Running" })
end
local function by_id(view)
	local attempts, jobs = {}, {}
	for _, a in view.attempts do attempts[a.id] = a end
	for _, job in view.jobs do jobs[job.id] = job end
	return attempts, jobs
end
local OBSOLETE_NOTICE = "An old Mark-no-longer-running request was cleared; SPAWN now does this automatically"
local sections = {}

sections.managed_coexistence=function()
	local db,authority,binding,_,_,load=fresh({record("shared"),record("ordinary")})
	local managed=assert(authority.managed_reserve(binding,1,"shared","bridge-observer"))
	check(managed.purpose=="managed","managed reservation has explicit purpose")
	local ordinary=submit(authority,binding,reserve_request(binding,"window",1,1,"ordinary")).result.attempt
	local view=snapshot(authority,binding)
	check(#view.attempts==2 and #view.jobs==1 and view.jobs[1].attempt_id==ordinary.id,"mixed snapshot exposes only ordinary ticket")
	check(#authority.execution_jobs(binding)==1,"host executor inventory excludes managed reservations")
	refused_unchanged(db,function()return authority.claim_execution(binding,managed.id,native())end,"ordinary executor cannot claim managed reservation")
	refused_unchanged(db,function()return authority.managed_observe(binding,ordinary.id,"bridge-observer",{phase="Running",pane=55})end,"bridge cannot observe ordinary job")
	refused_unchanged(db,function()return authority.managed_observe(binding,managed.id,"another-observer",{phase="Running",pane=55})end,"managed observer identity is immutable")
	local again=submit(authority,binding,reserve_request(binding,"window",2,1,"shared"))
	check(again.ok and again.result.attempt.id~=managed.id,"a managed reservation never blocks an ordinary launch of the same record")
	db.now+=31
	view=snapshot(authority,binding)
	check(view.attempts[1].phase=="Starting" and view.attempts[2].phase=="Failed" and view.attempts[3].phase=="Failed","admission expiry fails unclaimed tickets but never expires managed reservations")
	check(authority.managed_observe(binding,managed.id,"bridge-observer",{phase="Starting",pane=55}),"managed result remains independently bindable")
	local changed=copy(binding);changed.native_session=999
	refused_unchanged(db,function()return authority.managed_observe(changed,managed.id,"bridge-observer",{phase="Exited",pane=55})end,"native-session change rejects delayed result")
	local image=db.image();local corrupt=image.authority.sessions[binding.session_key]
	corrupt.jobs[managed.id]=copy(corrupt.jobs[ordinary.id])
	local invalid=modules(boundary(image))
	check(invalid.snapshot(binding)==nil,"managed attempt with ordinary job fails authority validation")
	check(load("launch_state").validate(db.peek("authority").sessions[binding.session_key].launch)~=nil,"coexisting ledger is canonical")
end

sections.managed_rotation=function()
	local db,authority,binding=fresh({record("managed")})
	local a=assert(authority.managed_reserve(binding,1,"managed","bridge-observer"))
	for i=1,64 do check(submit(authority,binding,request(binding,"window",i,1)).ok,"fill released reply transport") end
	local ok,why=authority.request(binding,request(binding,"window",65,1))
	check(not ok and why=="stale-authority","released capacity rotates only reply transport")
	local current=assert(authority.binding(4))
	check(current.authority_id~=binding.authority_id and current.managed_authority_id==binding.managed_authority_id,"bridge authority identity survives transport rotation")
	check(authority.snapshot(binding)==nil and authority.managed_snapshot(binding)~=nil,"old UI epoch is rejected while exact managed session remains bound")
	check(authority.managed_observe(binding,a.id,"bridge-observer",{phase="Starting",pane=77}),"granted delayed result settles through original binding")
	check(authority.managed_retire(binding,a.id,"bridge-observer","managed",77),"original managed binding can retire exact native pane")
	same(authority.managed_reserve(current,1,"managed","bridge-observer"),authority.managed_snapshot(current).attempts[1],"reservation replay preserves original attempt identity")
	refused_unchanged(db,function()return authority.managed_observe(binding,a.id,"bridge-observer",{phase="Running",pane=77})end,"late activity cannot resurrect completed attempt")
end

sections.managed_retention=function()
	local db,authority,binding=fresh({record("managed"),record("ordinary"),record("uncertain")})
	local held=assert(authority.managed_reserve(binding,1,"uncertain","uncertain-observer"))
	check(authority.managed_observe(binding,held.id,held.observer_id,{phase="Unknown"}),"unknown managed effect remains unresolved")
	for i=1,140 do
		local observer="retired-"..tostring(i)
		local a=assert(authority.managed_reserve(binding,1,"managed",observer))
		check(authority.managed_observe(binding,a.id,observer,{phase="Starting",pane=100+i}),"sequential managed worker binds its own pane")
		check(authority.managed_retire(binding,a.id,observer,"managed",100+i),"sequential managed worker retires exactly")
	end
	local view=snapshot(authority,binding)
	check(#view.attempts==27 and view.attempts[1].id==held.id,"more than 128 sequential retirees remain bounded beside unknown evidence")
	local ordinary=submit(authority,binding,reserve_request(binding,"ordinary",1,1,"ordinary"))
	check(ordinary.ok and ordinary.result.job.ticket~=nil,"ordinary ticket admission still works after 140 retired workers")
	view=snapshot(authority,binding)
	edit(authority,binding,"clear-history",{attempt_revision=view.attempt_revision})
	view=snapshot(authority,binding)
	check(#view.attempts==2 and view.attempts[1].id==held.id and view.attempts[1].unresolved,"history clear reclaims settled managed attempts but preserves unknown and active work")
	refused_unchanged(db,function()return authority.edit(binding,view.config_revision,"resolve-attempt",{id=held.id,attempt_revision=view.attempt_revision})end,"manual release no longer exists","Unknown settings operation")
	check(authority.sweep(binding,{},"daemon:1",db.now)==0,"a sweep with no panes leaves managed and unexpired ordinary work alone")
	view=snapshot(authority,binding)
	check(view.attempts[1].id==held.id and view.attempts[1].phase=="Unknown" and view.attempts[1].unresolved,"managed Unknown keeps its reservation; only bridge evidence settles it")
end

sections.managed_import=function()
	local db,authority,binding=fresh()
	local records={record("imported")}
	local result=assert(authority.managed_import(binding,0,"bridge-import",records))
	check(result.imported==1,"managed import commits canonical roster and exact receipt together")
	edit(authority,binding,"replace-records",{records={record("imported",{command="owner-edited"})}})
	local before=db.image()
	local replay=assert(authority.managed_import(binding,-1,"bridge-import",records))
	check(replay.replayed and replay.imported==0,"exact import receipt survives later configuration revision")
	same(db.image(),before,"replay never restores stale imported settings")
	refused_unchanged(db,function()return authority.managed_import(binding,2,"bridge-import",{record("different")})end,"changed managed import id cannot be reused")
	db.fail_after(1)
	refused_unchanged(db,function()return authority.managed_import(binding,2,"bridge-failed",{record("second")})end,"failed atomic import retains neither mutation nor receipt")
	db.fail_authority_at=nil
	check(authority.managed_import(binding,2,"bridge-failed",{record("second")}).imported==1,"uncommitted import may be reconciled once")
end

local function managed_fixture()
	local db,authority,binding,_,_,load=fresh({record("managed")})
	local P,Codec=load("bridge_protocol"),load("codec")
	local origin={logical_session_id="logical",owner_id="owner",owner_generation=1,host_pane_id="12",alias_nonce="alias",window_key="",window_epoch="epoch",native_session_id="4",window_host_id="7"}
	local r={schema=1,origin="orchplus",op="launch",request_id="launch",action_id="action-launch",controller_pane="44",controller_generation=1,origin_binding=origin,
		record_id="managed",record_revision=1,work_id="work",prompt="assignment",cwd="/work",placement="tab",fresh=true,mailbox_handle="mailbox",
		enrolment={worker_id="worker",worker_generation=1,enrolment_token="aaaaaaaaaaaaaaaa",assignment_sha256=Codec.sha256("assignment")}}
	check(P.decode(runtime.json.encode(r))~=nil,"migration fixture is a real bridge launch request")
	local observer="managed-"..Codec.sha256("logical/launch")
	local a=assert(authority.managed_reserve(binding,1,"managed",observer))
	check(authority.managed_observe(binding,a.id,observer,{phase="Starting",pane=55}),"fixture records exact native observation")
	local launch={command="'ordinary-cli'",cwd="/work",placement="tab",backend="local-terminal",capabilities={}}
	local registry={version=1,revision=0,namespace="dispatch-fixture",next_id=1,owners={logical={binding=copy(origin),authority=binding.managed_authority_id,host_session=4}},
		tombstones={},request_fences={},mailboxes=load("mailbox").empty(),gates={},requests={}}
	registry.requests["logical/launch"]={request=r,body=P.body(r,"awaiting_acceptance"),binding=copy(binding),observer_id=observer,attempt_id=a.id,
		launch=launch,launch_sha256=P.fingerprint(launch),pane_binding={pane_id="55",window_epoch="epoch",window_key="",native_session_id="4",window_host_id="7"}}
	check(load("dispatch").validate_registry(registry)~=nil,"fixture bridge evidence validates without side effects")
	db.kv.set("dispatch-v1",registry);db.kv.set("dispatch-v1-initialized",registry.namespace)
	return db,authority,binding,a,registry
end

sections.managed_unbound_mailbox_retention=function()
	for _,status in ipairs({"provisioned","uncertain"}) do
		for _,launch_status in ipairs({"absent","rejected"}) do
			local db,authority,binding,a,registry=managed_fixture()
			local _,_,_,load=modules(db)
			local P,Mailbox=load("bridge_protocol"),load("mailbox")
			local launch=copy(registry.requests["logical/launch"].request)
			launch.request_id="unbound";launch.action_id="action-unbound"
			launch.mailbox_handle="unbound-mailbox"
			if launch_status=="rejected" then
				registry.requests["logical/unbound"]={request=launch,body=P.reject(launch,"stale_revision","Record changed before launch")}
			end
			local provision={schema=1,origin="orchplus",op="mailbox_provision",request_id="provision",action_id="action-provision",
				origin_binding=copy(launch.origin_binding),controller_pane=launch.controller_pane,controller_generation=launch.controller_generation,
				logical_session_id="logical",worker_id="worker",worker_generation=1,launch_request_id="unbound",work_id="work",
				enrolment_token=launch.enrolment.enrolment_token,record_id="managed",record_revision=1,capability="report-files-v1"}
			local configured=record("managed",{mailbox={permitted_root="/private/mailboxes",helper_path="/private/tools/mailbox_target.sh",
				producer_helper_path="/private/tools/mailbox_worker.sh",worker_identity="worker",verified=true,evidence_ref="fixture-only",
				wake="worker-poll-v1",producer={read=true,write=true,hash=true,journal=true,poll=true},
				capabilities={"report-files-v1","worker-poll-v1","argv-v1"}}})
			local operation,intent=Mailbox.prepare(registry.mailboxes,provision,configured,
				{operation_id="provision-op",handle="unbound-mailbox",host_os="linux",host_shell="sh"})
			check(operation~=nil and intent~=nil,"unbound mailbox fixture prepares a real generation")
			registry.mailboxes=assert(Mailbox.settle(intent,operation,{status=status}))
			registry.requests["logical/provision"]={request=provision,body=P.body(provision,status)}
			check(load("dispatch").validate_registry(registry)~=nil,"unbound mailbox registry remains valid")
			db.kv.set("dispatch-v1",registry)
			check(authority.managed_retire(binding,a.id,a.observer_id,"managed",55),"original fixture worker settles")
			edit(authority,binding,"replace-records",{records={record("managed"),record("ordinary")}})
			for i=1,140 do
				local observer="retired-"..tostring(i)
				local worker=assert(authority.managed_reserve(binding,2,"managed",observer))
				check(authority.managed_observe(binding,worker.id,observer,{phase="Starting",pane=100+i}),"worker binds its exact pane")
				check(authority.managed_retire(binding,worker.id,observer,"managed",100+i),"worker settles beside unbound mailbox")
			end
			local view=snapshot(authority,binding)
			check(#view.attempts==26,status.." mailbox with "..launch_status.." launch cannot pin unrelated history")
			local ordinary=submit(authority,binding,reserve_request(binding,"ordinary",1,2,"ordinary"))
			check(ordinary.ok and ordinary.result.job.ticket~=nil,"ordinary launch admits after 140 workers beside unbound mailbox")
			view=snapshot(authority,binding)
			edit(authority,binding,"clear-history",{attempt_revision=view.attempt_revision})
			check(#snapshot(authority,binding).attempts==1,"unbound mailbox cannot prevent explicit settled-history cleanup")
			same(db.peek("dispatch-v1"),registry,"history maintenance preserves unbound mailbox evidence")
		end
	end
end

sections.managed_settlement_replay=function()
	local db,authority,binding,a,registry=managed_fixture()
	local _,_,_,load=modules(db);local P,Codec=load("bridge_protocol"),load("codec")
	local launched=registry.requests["logical/launch"]
	local r=launched.request
	local retirement={schema=1,origin="orchplus",op="mailbox_retire",request_id="retire",action_id="action-retire",origin_binding=copy(r.origin_binding),
		controller_pane=r.controller_pane,controller_generation=r.controller_generation,logical_session_id="logical",worker_id="worker",worker_generation=1,
		launch_request_id="launch",work_id="work",enrolment_token=r.enrolment.enrolment_token,handle="mailbox",expected_generation=1,mode="retire",
		settlement_revision=1,report_floor=1,report_chain_sha256=Codec.sha256("settled"),reply_floor=0,grant_id="retirement-grant"}
	check(P.decode(runtime.json.encode(retirement))~=nil,"interrupted settlement uses a valid exact retirement request")
	local pending={request=retirement,body=P.body(retirement,"pending"),retirement_result=P.body(retirement,"retired")}
	registry.requests["logical/retire"]=pending
	db.kv.set("dispatch-v1",registry)
	check(authority.managed_retire(binding,a.id,a.observer_id,"managed",55),"authority settles while bridge retirement-result commit remains interrupted")
	edit(authority,binding,"replace-records",{records={record("managed"),record("ordinary")}})
	for i=1,35 do
		local value=request(binding,"ordinary",i,2,"launch_record",{record_id="ordinary"},if i>1 then {"ordinary/"..tostring(i-1)} else {})
		local id=submit(authority,binding,value).result.attempt.id
		update(authority,binding,id,"admitted",{stage="failed"},{phase="Failed"})
	end
	local view=snapshot(authority,binding)
	check(#view.attempts==27 and view.attempts[1].id==a.id,"interrupted retirement_result pins exact attempt through trimming")
	edit(authority,binding,"clear-history",{attempt_revision=view.attempt_revision})
	check(#snapshot(authority,binding).attempts==1,"explicit clearing also preserves interrupted settlement")
	local before=db.image()
	check(authority.managed_retire(binding,a.id,a.observer_id,"managed",55),"exact interrupted retirement still replays after history maintenance")
	same(db.image(),before,"interrupted settlement replay is idempotent")
	pending.retirement_result=nil;pending.body=P.body(retirement,"retired")
	registry.owners={}
	registry.tombstones={{binding=copy(r.origin_binding),revision=1,authority=binding.managed_authority_id,host_session=4,evidence="operator_attested_controller_and_launch_executors_stopped_or_retired"}}
	db.kv.set("dispatch-v1",registry)
	local other=assert(authority.open("host-A",8))
	local fences=db.peek("dispatch-v1")
	local result=assert(authority.forget_sessions(other,{[8]=true},true))
	check(result.sessions==1 and db.peek("authority").sessions[binding.session_key]==nil,"settled absent scope is reclaimable despite retained launch receipts and tombstone")
	same(db.peek("dispatch-v1"),fences,"forgetting settled ledger never erases bridge replay fences")
end

sections.managed_maintenance=function()
	local db,authority,binding,a,registry=managed_fixture()
	check(authority.managed_retire(binding,a.id,a.observer_id,"managed",55),"settled managed ledger alone does not clear controller")
	refused_unchanged(db,function()return authority.edit(binding,1,"reset-transport",{})end,"controller reference prevents reset after settlement")
	local other=assert(authority.open("host-A",8))
	check(authority.forget_sessions(other,{[8]=true},true).kept==1,"owner and launch references protect absent session")
	registry.owners={}
	local entry=registry.requests["logical/launch"]
	entry.authorization={nonce="nonce",boot="boot",bridge=77,binding=copy(binding),session=4,deadline=1,new=false,phase="consumed"}
	db.kv.set("dispatch-v1",registry)
	refused_unchanged(db,function()return authority.edit(binding,1,"reset-transport",{})end,"consumed native authorization prevents reset independently of owner")
	db.kv.set("dispatch-v1",nil)
	refused_unchanged(db,function()return authority.edit(binding,1,"reset-transport",{})end,"missing initialized bridge never permits reset")
	refused_unchanged(db,function()return authority.forget_sessions(other,{[8]=true},true)end,"missing bridge never permits forgetting")
end

sections.managed_migration=function()
	local db,_,binding,a=managed_fixture()
	local image=db.image();local old=image.authority
	old.version=1
	local scope=old.sessions[binding.session_key]
	scope.native_session=nil;scope.jobs=nil;scope.managed_authority_id=nil;scope.managed_imports=nil
	scope.inbox={};scope.imports={};scope.launch.attempts[1].purpose=nil
	local restored_db=boundary(image);local restored=modules(restored_db)
	local current=assert(restored.open("host-A",4,nil,binding.session_key))
	local migrated=restored_db.peek("authority")
	check(migrated.version==3 and migrated.namespace==old.namespace and migrated.config_revision==old.config_revision,"exact v1 migration preserves roster and namespace identity")
	local result=migrated.sessions[binding.session_key].launch.attempts[1]
	local expected=copy(scope.launch.attempts[1]);expected.purpose="managed"
	same(result,expected,"migration changes only explicit purpose, never observer/attempt/pane evidence")
	same(restored_db.peek("managed-v1-original"),old,"old managed authority is preserved before conversion")
	same(restored_db.peek("dispatch-v1"),image["dispatch-v1"],"migration never rewrites immutable bridge grants")
	check(#snapshot(restored,current).jobs==0,"migrated managed attempt cannot become an ordinary ticket")
	for _,mutate in ipairs({
		function(seed)seed["dispatch-v1"].requests["logical/launch"].observer_id="managed-not-the-exact-request"end,
		function(seed)seed.authority.sessions[binding.session_key].launch.attempts[1].record_id="ordinary"end,
		function(seed)seed["dispatch-v1"].requests["logical/launch"].pane_binding.pane_id="56"end,
		function(seed)seed.authority.sessions[binding.session_key].inbox={{version=1}}end,
	}) do
		local broken=copy(image);mutate(broken)
		local bad_db=boundary(broken);local bad=modules(bad_db)
		refused_unchanged(bad_db,function()return bad.open("host-A",4,nil,binding.session_key)end,"unmatched old evidence is never adopted")
	end
	local failed_db=boundary(image);failed_db.fail_set="managed-v1-original"
	local failed=modules(failed_db)
	refused_unchanged(failed_db,function()return failed.open("host-A",4,nil,binding.session_key)end,"migration cannot proceed without preserved original")
	local no_evidence=copy(image)
	no_evidence["dispatch-v1"]=nil;no_evidence["dispatch-v1-initialized"]=nil
	local absent_db=boundary(no_evidence);local absent=modules(absent_db)
	refused_unchanged(absent_db,function()return absent.open("host-A",4,nil,binding.session_key)end,"never-created registry cannot justify a real saved attempt")

	local function legacy_image(database,b,receipts)
		local seed=database.image();seed.authority.version=1
		local s=seed.authority.sessions[b.session_key]
		s.native_session=nil;s.jobs=nil;s.managed_authority_id=nil;s.managed_imports=nil
		s.inbox={};s.imports=copy(receipts or {})
		return seed
	end
	local clean_db,_,clean_binding,config=fresh()
	local receipts={["ordinary-observer:setup:1"]=assert(config.validate_records({record("obsolete-setup")}))}
	local clean_seed=legacy_image(clean_db,clean_binding,receipts)
	local empty_db=boundary(clean_seed);local empty=modules(empty_db)
	local empty_binding=assert(empty.open("host-A",4,nil,clean_binding.session_key))
	check(empty_db.peek("authority").version==3 and #snapshot(empty,empty_binding).records==0,"clean v1 without any bridge registry migrates without replaying obsolete ordinary setup")
	same(empty_db.peek("managed-v1-original"),clean_seed.authority,"obsolete ordinary receipts remain in exact original backup")
	same(empty_db.peek("authority").sessions[clean_binding.session_key].managed_imports,{},"ordinary receipts do not become managed replay grants")
	check(empty_db.peek("dispatch-v1")==nil,"clean migration does not invent a bridge registry")
	for _,change in ipairs({
		function(seed)seed["dispatch-v1-initialized"]="lost-registry"end,
		function(seed)seed["dispatch-v1"]={version=99}end,
		function(seed)seed.authority.sessions[clean_binding.session_key].imports.bad={record("same"),record("same")}end,
	}) do
		local broken=copy(clean_seed);change(broken)
		local bad_db=boundary(broken);local bad=modules(bad_db)
		refused_unchanged(bad_db,function()return bad.open("host-A",4,nil,clean_binding.session_key)end,"empty migration preserves corrupt or missing initialized evidence")
	end
	local unreadable_db=boundary(clean_seed);unreadable_db.fail_get="dispatch-v1"
	local unreadable=modules(unreadable_db)
	refused_unchanged(unreadable_db,function()return unreadable.open("host-A",4,nil,clean_binding.session_key)end,"empty migration distinguishes registry read failure from never-created")

	local imported_db,importer,import_binding,import_config,_,load=fresh()
	local Dispatch,Codec=load("dispatch"),load("codec")
	local imported_records=assert(import_config.validate_records({record("imported")}))
	local bytes=runtime.json.encode(imported_records)
	local preview={schema=1,origin="spawn-migration",op="import_config",request_id="receipt",source_client="legacy-source",target_host=import_binding.host_key,
		source_revision=1,source_sha256=Codec.sha256(bytes),records_json=bytes}
	local gate_id=assert(Dispatch.open_import(import_binding,runtime.json.encode(preview)))
	preview.migration_gate_id=gate_id
	check(Dispatch.import_config(preview).status=="imported","fixture commits a real consumed managed import gate")
	local old_transport=import_binding.authority_id
	edit(importer,import_binding,"reset-transport",{})
	check(import_binding.authority_id~=old_transport,"consumed settled gate survives deliberate transport reset")
	local imported_receipts=copy(imported_db.peek("authority").sessions[import_binding.session_key].managed_imports)
	imported_receipts["ordinary-observer:setup:1"]=receipts["ordinary-observer:setup:1"]
	local reset_seed=legacy_image(imported_db,import_binding,imported_receipts)
	local reset_db=boundary(reset_seed);local reset_authority=modules(reset_db)
	local migrated_binding=assert(reset_authority.open("host-A",4,nil,import_binding.session_key))
	same(snapshot(reset_authority,migrated_binding).records,imported_records,"receipt migration does not replay imports or restore obsolete ordinary records")
	check(reset_authority.managed_import(migrated_binding,-1,"bridge-receipt",imported_records).replayed,"consumed bridge receipt matches stable host/session after transport rotation")
	same(reset_db.peek("dispatch-v1"),reset_seed["dispatch-v1"],"receipt migration preserves exact consumed gate binding and outcome")
	same(reset_db.peek("managed-v1-original"),reset_seed.authority,"rotated old authority is backed up exactly")
	for _,field in ipairs({"host_key","native_session","session_key"}) do
		local changed=copy(reset_seed);local gate=changed["dispatch-v1"].gates[gate_id]
		gate.binding[field]=if field=="native_session" then 9 else "different"
		local bad_db=boundary(changed);local bad=modules(bad_db)
		refused_unchanged(bad_db,function()return bad.open("host-A",4,nil,import_binding.session_key)end,"managed receipt rejects changed stable "..field)
	end
end

sections.managed_retirement = function()
	local db, authority, binding = fresh({ record("coordinator"), record("unrelated") })
	local revision = snapshot(authority, binding).config_revision
	local first = assert(authority.managed_reserve(binding, revision, "coordinator", "managed-first"))
	check(authority.managed_observe(binding, first.id, "managed-first", {phase="Starting",pane=55}), "managed launch binds its exact native pane")
	local other = assert(authority.managed_reserve(binding, revision, "unrelated", "managed-other"))
	check(authority.managed_observe(binding, other.id, "managed-other", {phase="Starting",pane=56}), "unrelated launch remains independently reserved")
	for _,args in ipairs({
		{first.id,"wrong-observer","coordinator",55},
		{first.id,"managed-first","unrelated",55},
		{first.id,"managed-first","coordinator",56},
		{other.id,"managed-first","coordinator",55},
	}) do
		refused_unchanged(db,function()return authority.managed_retire(binding,table.unpack(args))end,"nonmatching retirement")
	end
	db.fail_after(1)
	refused_unchanged(db,function()return authority.managed_retire(binding,first.id,"managed-first","coordinator",55)end,"failed retirement commit")
	db.fail_authority_at=nil
	check(authority.managed_retire(binding,first.id,"managed-first","coordinator",55),"exact retired mailbox/native stop releases only matching reservation")
	local before=db.image()
	check(authority.managed_retire(binding,first.id,"managed-first","coordinator",55),"exact reservation retirement is idempotent")
	same(db.image(),before,"retirement replay does not advance unrelated counters")
	local successor=assert(authority.managed_reserve(binding,revision,"coordinator","managed-successor"))
	check(successor.id~=first.id,"a new managed generation of the same record gets a distinct attempt")
	check(authority.managed_observe(binding,successor.id,"managed-successor",{phase="Starting",pane=57}),"new generation binds its own pane")
	check(authority.managed_retire(binding,first.id,"managed-first","coordinator",55),"old retirement remains a no-op after successor")
	local held=by_id(snapshot(authority,binding))
	check(held[successor.id].phase=="Starting" and held[successor.id].unresolved,"old retirement cannot clear successor reservation")
	check(held[other.id].phase=="Starting" and held[other.id].unresolved,"retirement cannot clear unrelated record")
	check(authority.managed_observe(binding,successor.id,"managed-successor",{phase="Unknown",pane=57}),"lost successor observation stays uncertain")
	refused_unchanged(db,function()return authority.managed_retire(binding,successor.id,"managed-successor","coordinator",57)end,"uncertain reservation cannot be silently settled")
end

-- Two observers interleave reservations and acknowledgments without a last-reply slot.
sections.interleaving = function()
	local db, authority, binding, _, launch = fresh({ record("first"), record("second") })
	local revision = snapshot(authority, binding).config_revision
	local a = reserve_request(binding, "A", 1, revision, "first")
	local b = reserve_request(binding, "B", 1, revision, "second")
	local reply_a, reply_b = submit(authority, binding, a), submit(authority, binding, b)
	check(reply_a.ok and reply_b.ok, "independent accounts both reserve")
	check(reply_a.result.attempt.id ~= reply_b.result.attempt.id, "interleaved reservations have distinct identities")
	local view = snapshot(authority, binding)
	check(count(view.replies) == 2 and #view.attempts == 2, "A and B results and attempts coexist")
	same(view.replies[a.request_id], reply_a, "B cannot replace A's retained result")
	check(launch.validate(db.peek("authority").sessions[binding.session_key].launch) ~= nil, "authority persists a real valid launch ledger")
	local before = db.image()
	check(authority.request(binding, a), "identical retained request is idempotent")
	same(db.image(), before, "identical retry creates no attempt or reply mutation")
	local changed = copy(a)
	changed.data.record_id = "second"
	refused_unchanged(db, function() return authority.request(binding, changed) end, "changed request ID reuse", "changed-request-reuse")
	local cross_ack = request(binding, "A", 2, revision, nil, nil, { a.request_id, b.request_id })
	refused_unchanged(db, function() return authority.request(binding, cross_ack) end, "acknowledging another observer", "acknowledgment-observer-mismatch")
	local a2 = request(binding, "A", 2, revision, nil, nil, { a.request_id })
	check(submit(authority, binding, a2).ok, "A acknowledges its own result")
	view = snapshot(authority, binding)
	check(view.replies[a.request_id] == nil and view.replies[a2.request_id] ~= nil, "A's old reply alone is pruned")
	same(view.replies[b.request_id], reply_b, "A's acknowledgment preserves B's reply exactly")
	check(view.request_sequences.A == 2 and view.request_sequences.B == 1, "watermarks remain observer scoped")
	refused_unchanged(db, function() return authority.request(binding, a) end, "acknowledged request replay", "stale-request-sequence")
	local renamed_replay = copy(a)
	renamed_replay.request_id = "A/new-id-old-sequence"
	refused_unchanged(db, function() return authority.request(binding, renamed_replay) end, "old sequence with fresh request ID", "stale-request-sequence")
	-- Snapshot tables are not writable aliases into durable state.
	before = db.image()
	view.records[1].command = "tampered"
	view.attempts[1].phase = "Exited"
	view.replies[b.request_id].ok = false
	same(db.image(), before, "consumer snapshot mutation cannot change durable state")
end

-- Stale configuration mutations may retain an error reply, never stale roster data.
sections.stale_config = function()
	local db, authority, binding = fresh({ record("first") })
	local old_revision = snapshot(authority, binding).config_revision
	edit(authority, binding, "replace-records", { records = { record("first", { command = "approved-command", arguments = { "two words", "" } }), record("second") } })
	local before = snapshot(authority, binding)
	refused_unchanged(db, function()
		return authority.edit(binding, old_revision, "replace-records", { records = { record("stale") } })
	end, "stale form edit")
	local stale = request(binding, "importer", 1, old_revision, "import_records", { setup_run_id = "old-setup", records = { record("stale") } })
	local reply = submit(authority, binding, stale)
	check(not reply.ok and reply.error == "stale-config", "stale import returns a retained rejection")
	local after = snapshot(authority, binding)
	same(after.records, before.records, "stale import leaves roster exact")
	check(after.config_revision == before.config_revision, "stale import does not advance configuration revision")
	local imported = { record("third", { prompt = "Keep exact prompt.\nNo automatic launch." }) }
	local add = request(binding, "importer", 2, after.config_revision, "import_records", { setup_run_id = "approved-setup", records = imported })
	check(submit(authority, binding, add).result.imported == 1, "review-confirmed import adds the intended record")
	after = snapshot(authority, binding)
	check(#after.attempts == 0, "import does not reserve or execute a launch")
	local replay = request(binding, "importer", 3, after.config_revision, "import_records", add.data)
	local replay_reply = submit(authority, binding, replay)
	check(replay_reply.ok and replay_reply.result.imported == 0, "identical import is idempotent under a new request")
	local conflict = request(binding, "importer", 4, after.config_revision, "import_records", { setup_run_id = "approved-setup", records = { record("third", { command = "different" }) } })
	check(not submit(authority, binding, conflict).ok, "conflicting import of an existing record is rejected")
	same(snapshot(authority, binding).records, after.records, "setup replay and conflict preserve exact roster")
end

-- One atomic write commits the mutation, reply and watermark together.
sections.recovery = function()
	local db, authority, binding = fresh({ record("fault") })
	local revision = snapshot(authority, binding).config_revision
	local value = reserve_request(binding, "fault-observer", 1, revision, "fault")
	db.fail_after(1)
	refused_unchanged(db, function() return authority.request(binding, value) end, "failed atomic admission")
	local scope = db.peek("authority").sessions[binding.session_key]
	check(#scope.launch.attempts == 0 and next(scope.replies) == nil and next(scope.request_sequences) == nil, "failed admission creates no attempt, reply, or watermark")
	local writes = db.authority_writes
	local reply = submit(authority, binding, value)
	check(db.authority_writes == writes + 1, "admission commits with exactly one atomic write")
	local committed = snapshot(authority, binding)
	check(#committed.attempts == 1 and count(committed.replies) == 1 and reply.ok, "one reservation and one successful reply")
	same(reply.result.attempt, committed.attempts[1], "reply identifies the actual committed attempt")
	check(committed.request_sequences["fault-observer"] == 1, "admission commits the replay watermark")
	local durable = db.image()
	for _ = 1, 3 do
		same(snapshot(authority, binding), committed, "repeated snapshot retains the same reply and attempt")
		check(authority.request(binding, value), "same request ID retry is accepted idempotently")
	end
	same(db.image(), durable, "retries never recommit the request")
end

-- Capacity rotates the transport generation, never drops replay fences in place.
sections.reply_capacity = function()
	local db, authority, binding = fresh({ record("kept") })
	local captured = reserve_request(binding, "captured", 1, 1, "kept")
	local admitted = submit(authority, binding, captured)
	local id = admitted.result.attempt.id
	claim(authority, binding, id)
	update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	for sequence = 1, 63 do check(submit(authority, binding, request(binding, "full", sequence, 1)).ok, "retain bounded reply") end
	local before = db.peek("authority").sessions[binding.session_key]
	local trigger = reserve_request(binding, "overflow", 1, 1, "kept")
	db.fail_after(1)
	refused_unchanged(db, function() return authority.request(binding, trigger) end, "failed generation rotation")
	local ok, err = authority.request(binding, trigger)
	check(not ok and err == "stale-authority", "capacity trigger is refused, never executed")
	local after = db.peek("authority").sessions[binding.session_key]
	check(after.authority_id ~= before.authority_id and next(after.replies) == nil and next(after.request_sequences) == nil, "rotation atomically retires old transport")
	same(after.launch, before.launch, "rotation preserves active history")
	same(after.jobs, before.jobs, "rotation preserves execution jobs")
	refused_unchanged(db, function() return authority.request(binding, captured) end, "captured old launch cannot reexecute", "stale-authority")
	refused_unchanged(db, function() return authority.request(binding, trigger) end, "overflow launch cannot auto-replay", "stale-authority")
	check(authority.snapshot(binding) == nil, "old UI binding must explicitly reopen")
	-- Host execution is session-scoped, independent of the retired UI generation.
	update(authority, binding, id, "submission_intent", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
	refused_unchanged(db, function() return authority.claim_execution(binding, id, native()) end, "retired binding cannot claim the job twice")
	local reopened = assert(authority.open("host-A", 4, nil, binding.session_key))
	refused_unchanged(db, function() return authority.request(reopened, captured) end, "captured request rejected with refreshed binding", "stale-authority")
	local view = snapshot(authority, reopened)
	check(#view.attempts == 1 and view.jobs[1].stage == "completed", "one admitted job completes across generation rotation")
	check(submit(authority, reopened, request(reopened, "fresh", 1, 1)).ok, "explicit refreshed observer can continue")
end
sections.observer_capacity = function()
	local db, authority, binding = fresh()
	local captured = request(binding, "observer-1", 1, 0)
	for index = 1, 130 do
		local value = request(binding, "observer-" .. tostring(index), 1, 0)
		if index == 65 or index == 129 then
			local ok, err = authority.request(binding, value)
			check(not ok and err == "stale-authority", "reconnect capacity requires explicit refresh")
			local previous = binding
			binding = assert(authority.open("host-A", 4, nil, previous.session_key))
			refused_unchanged(db, function() return authority.request(previous, value) end, "retired reconnect request", "stale-authority")
			refused_unchanged(db, function() return authority.request(binding, captured) end, "captured old observer after recovery", "stale-authority")
			value = request(binding, "observer-" .. tostring(index), 1, 0)
		end
		check(submit(authority, binding, value).ok, "admit reconnect observer after explicit refresh")
		edit(authority, binding, "review-reply", { id = value.request_id })
	end
	check(count(snapshot(authority, binding).request_sequences) == 2, "130 reconnects reclaim bounded watermarks safely")
end
sections.byte_capacity = function()
	local db, authority, binding, config = fresh({ record("kept") })
	local large = {}
	for index = 1, 3 do large[index] = record("large-" .. tostring(index), { prompt = string.rep("x", 30000) }) end
	check(config.validate_records(large) ~= nil, "large import is individually schema-valid")
	local value = request(binding, "large", 1, 1, "import_records", { setup_run_id = "large-setup", records = large })
	refused_unchanged(db, function() return authority.request(binding, value) end, "encoded durable state capacity")
	check(#snapshot(authority, binding).attempts == 0, "oversized request has no side effects")
end

-- Review preserves both originals and requires a choice for every record, including omissions.
sections.review_conflict = function()
	local original = { schema = 1, agents = { record("shared", { command = "host-command" }), record("host-only") } }
	local client = { schema = 1, agents = { record("shared", { command = "client-command", arguments = { "approved" } }), record("client-only") } }
	local db = boundary({ config = original })
	local authority, config = modules(db)
	local binding = assert(authority.open("host-A", 4, client))
	local view = snapshot(authority, binding)
	check(not view.ready and view.migration ~= nil and #view.migration.sources == 2, "conflicting host and client rosters require visible review")
	same(db.peek("config"), original, "opening review preserves the original config key")
	same(db.peek("migration-original"), original, "host original is durably backed up")
	same(db.peek("migration-client-1"), client, "client original is durably backed up separately")
	same(view.records, original.agents, "opening conflict does not overwrite host roster with client copy")
	refused_unchanged(db, function() return authority.edit(binding, view.config_revision, "review-confirm", {}) end, "review without per-record choices")
	local blocked = reserve_request(binding, "review-observer", 1, view.config_revision, "shared")
	check(not submit(authority, binding, blocked).ok, "review-pending configuration cannot reserve")
	check(#snapshot(authority, binding).attempts == 0, "review block creates no launch attempt")
	edit(authority, binding, "review-choice", { id = "shared", source = 2 })
	view = snapshot(authority, binding)
	refused_unchanged(db, function() return authority.edit(binding, view.config_revision, "review-confirm", {}) end, "partially selected review")
	refused_unchanged(db, function() return authority.edit(binding, view.config_revision, "review-choice", { id = "host-only", source = 2 }) end, "source missing selected record")
	edit(authority, binding, "review-choice", { id = "host-only", source = 1 })
	edit(authority, binding, "review-choice", { id = "client-only", source = 0 })
	edit(authority, binding, "review-confirm", {})
	view = snapshot(authority, binding)
	check(view.ready and view.migration == nil, "explicit complete review makes the authority ready")
	local expected = assert(config.validate_records({ original.agents[2], client.agents[1] }))
	same(view.records, expected, "review keeps selected source per account and explicit omission")
	same(db.peek("config"), original, "review confirmation never alters legacy original")
	same(db.peek("migration-original"), original, "review confirmation preserves host backup")
	same(db.peek("migration-client-1"), client, "review confirmation preserves client backup")
	local reopened = assert(authority.open("host-A", 4, client, binding.session_key))
	check(snapshot(authority, reopened).ready, "already reviewed client copy does not reopen conflict")
	same(snapshot(authority, reopened).records, expected, "reopening reviewed source retains deliberate decisions")

	-- A client's bucket key is an alias, not the authority's durable roster key.
	local alias_db, alias_authority, origin, canonical = fresh()
	local client_blob = { schema = 2, hosts = {
		["client-alias-A"] = { schema = 2, agents = { record("alias-a", { command = "/usr/bin/true" }) } },
		["client-alias-B"] = { schema = 2, agents = { record("alias-b", { command = "/usr/bin/true" }) } },
		["unrelated-host"] = { schema = 2, agents = { record("unrelated", { command = "/usr/bin/true" }) } },
	} }
	local expected_a = assert(canonical.validate_records(client_blob.hosts["client-alias-A"].agents))
	local expected_b = assert(canonical.validate_records(client_blob.hosts["client-alias-B"].agents))
	local first = assert(alias_authority.open("client-alias-A", 4, client_blob, origin.session_key))
	local first_view = snapshot(alias_authority, first)
	check(not first_view.ready and #first_view.migration.sources == 2, "incoming client alias exposes its legacy bucket for explicit review")
	same(first_view.migration.sources[1].records, {}, "opening alias review preserves empty authoritative roster")
	same(first_view.migration.sources[2].records, expected_a, "only alias A's bucket is offered, not B or unrelated buckets")
	same(alias_db.peek("migration-client-1"), client_blob, "alias review preserves the entire client original including unrelated buckets")
	refused_unchanged(alias_db, function()
		return alias_authority.edit(first, first_view.config_revision, "review-confirm", {})
	end, "alias source review without an explicit per-record choice")
	edit(alias_authority, first, "review-choice", { id = "alias-a", source = 2 })
	edit(alias_authority, first, "review-confirm", {})
	same(snapshot(alias_authority, first).records, expected_a, "explicit alias A selection enters the canonical roster")
	local settled_a = alias_db.image()
	local repeated_a = assert(alias_authority.open("client-alias-A", 4, client_blob, origin.session_key))
	check(snapshot(alias_authority, repeated_a).ready, "same-alias reviewed copy remains ready")
	same(alias_db.image(), settled_a, "same-alias review replay does not change revisions, decisions or saved originals")

	local second = assert(alias_authority.open("client-alias-B", 4, client_blob, origin.session_key))
	local second_view = snapshot(alias_authority, second)
	check(not second_view.ready and #second_view.migration.sources == 2, "the identical whole client blob under alias B needs a distinct source review")
	same(second_view.migration.sources[1].records, expected_a, "alias B review retains the deliberate canonical roster")
	same(second_view.migration.sources[2].records, expected_b, "alias B exposes B's distinct record without offering unrelated buckets")
	same(second.authority_id, origin.authority_id, "changing client source alias does not replace the native authority")
	same(second.session_key, origin.session_key, "changing client source alias does not rebind its durable namespace")
	same(second.host_key, origin.host_key, "canonical roster key is independent of incoming client aliases")
	refused_unchanged(alias_db, function()
		return alias_authority.edit(second, second_view.config_revision, "review-confirm", {})
	end, "alias B cannot bypass per-record review using alias A's receipt")
	edit(alias_authority, second, "review-choice", { id = "alias-a", source = 1 })
	edit(alias_authority, second, "review-choice", { id = "alias-b", source = 2 })
	edit(alias_authority, second, "review-confirm", {})
	local expected_both = assert(canonical.validate_records({ expected_a[1], expected_b[1] }))
	same(snapshot(alias_authority, second).records, expected_both, "both explicitly selected accounts are saved under the canonical host")
	same(alias_db.peek("authority").config.hosts[origin.host_key].agents, expected_both, "only the original canonical roster bucket receives reviewed records")
	check(alias_db.peek("authority").config.hosts["client-alias-A"] == nil
		and alias_db.peek("authority").config.hosts["client-alias-B"] == nil, "client aliases never create authoritative roster buckets")
	same(alias_db.peek("migration-client-1"), client_blob, "first alias original remains untouched after later review")
	same(alias_db.peek("migration-client-2"), client_blob, "second alias original retains all unrelated client buckets")
	local settled_b = alias_db.image()
	for _, alias in ipairs({ "client-alias-A", "client-alias-B" }) do
		local replay = assert(alias_authority.open(alias, 4, client_blob, origin.session_key))
		check(snapshot(alias_authority, replay).ready, "each settled alias receipt remains independently idempotent")
	end
	same(alias_db.image(), settled_b, "replaying either reviewed alias preserves later deliberate selections")
end

-- Reset needs no retained replies; it never erases reservations.
sections.transport_reset = function()
	local db, authority, binding = fresh({ record("reset") })
	local revision = snapshot(authority, binding).config_revision
	local value = reserve_request(binding, "reset-observer", 1, revision, "reset")
	check(submit(authority, binding, value).ok, "prepare an admitted request with a retained reply")
	local view = snapshot(authority, binding)
	refused_unchanged(db, function() return authority.edit(binding, revision, "reset-transport", {}) end, "reset with retained reply")
	edit(authority, binding, "review-reply", { id = value.request_id })
	refused_unchanged(db, function() return authority.edit(binding, revision, "reset-transport", {}) end, "reset with active attempt", "Wait until every live or managed attempt has ended before resetting transport")
	update(authority, binding, view.jobs[1].id, "admitted", { stage = "unknown" }, { phase = "Unknown" })
	-- An ordinary Unknown settles itself, so it no longer holds transport.
	view = snapshot(authority, binding)
	local before = db.peek("authority")
	local old_binding = copy(binding)
	local old_scope = before.sessions[binding.session_key]
	edit(authority, binding, "reset-transport", {})
	local after = db.peek("authority")
	local new_scope = after.sessions[binding.session_key]
	check(binding.authority_id ~= old_binding.authority_id, "transport reset rotates authority identity")
	check(new_scope.authority_id == binding.authority_id, "binding follows committed rotated identity")
	same(new_scope.launch, old_scope.launch, "transport reset preserves full attempt ledger and identity counter")
	same(new_scope.jobs, old_scope.jobs, "transport reset preserves execution jobs")
	same(after.config, before.config, "transport reset preserves roster")
	same(new_scope.request_sequences, {}, "explicit reset clears observer watermarks")
	check(next(new_scope.replies) == nil and next(new_scope.requests) == nil, "reset leaves transport empty")
	refused_unchanged(db, function() return authority.request(old_binding, value) end, "old authority request after reset", "stale-authority")
	check(authority.snapshot(old_binding) == nil, "old authority binding cannot read as the new identity")
	same(snapshot(authority, binding).attempts, view.attempts, "reset preserves history")
	local next_launch = reserve_request(binding, "new-observer", 1, revision, "reset")
	check(submit(authority, binding, next_launch).ok, "a new launch is admitted after reset")
	local managed_db, managed_authority, managed_binding = fresh({ record("managed") })
	local held = assert(managed_authority.managed_reserve(managed_binding, 1, "managed", "bridge-observer"))
	check(managed_authority.managed_observe(managed_binding, held.id, "bridge-observer", { phase = "Unknown" }), "managed effect becomes uncertain")
	refused_unchanged(managed_db, function() return managed_authority.edit(managed_binding, 1, "reset-transport", {}) end, "reset with an unresolved managed attempt", "Wait until every live or managed attempt has ended before resetting transport")
end

-- An explicitly empty client roster is still a conflicting source, not an absent copy.
sections.empty_client = function()
for index, client in ipairs({
	{ schema = 1, agents = {} },
	{ schema = 2, hosts = { ["host-A"] = { schema = 2, agents = {} } } },
}) do
	local host_records = { record("host-kept") }
	local db, authority, binding = fresh(host_records)
	local original_config = db.peek("authority").config
	local reopened = assert(authority.open("host-A", 4, client, binding.session_key))
	local view = snapshot(authority, reopened)
	check(not view.ready and view.migration ~= nil, "explicit empty client roster requires deliberate conflict review")
	check(#view.migration.sources == 2, "empty client source is retained beside populated host source")
	same(view.migration.sources[1].records, host_records, "empty client conflict preserves populated host review source")
	same(view.migration.sources[2].records, {}, "empty client source remains explicitly represented")
	same(view.records, host_records, "opening empty client conflict never silently replaces host roster")
	same(db.peek("authority").config, original_config, "opening empty client conflict preserves canonical host config")
	same(db.peek("migration-client-1"), client, "explicit empty client original is backed up exactly")
	refused_unchanged(db, function()
		return authority.edit(reopened, view.config_revision, "review-confirm", {})
	end, "empty client conflict without a per-record decision")
	local choice = if index == 1 then 1 else 0
	edit(authority, reopened, "review-choice", { id = "host-kept", source = choice })
	edit(authority, reopened, "review-confirm", {})
	view = snapshot(authority, reopened)
	check(view.ready and view.migration == nil, "deliberate empty-source conflict decision completes review")
	same(view.records, if choice == 1 then host_records else {}, "only explicit selection or omission determines final roster")
	same(db.peek("migration-client-1"), client, "empty client original survives review confirmation")
	local again = assert(authority.open("host-A", 4, client, binding.session_key))
	check(snapshot(authority, again).ready, "reviewed empty source does not reopen settled conflict")
end
end

-- Minimal current migration fixtures: empty flat and host-scoped, plus a real legacy record.
sections.migration = function()
for _, original in ipairs({
	{ schema = 1, agents = {} },
	{ schema = 2, hosts = { ["host-A"] = { schema = 2, agents = { record("current") } } } },
	{ schema = 1, agents = { { id = "legacy", provider = "custom", backend = "local-terminal", command = "ordinary-cli", arguments = { "two words", "" } } } },
}) do
	local db = boundary({ config = original })
	local authority, config = modules(db)
	local expected = assert(config.migrate(original, "host-A")).records
	local binding = assert(authority.open("host-A", 4))
	local view = snapshot(authority, binding)
	check(not view.ready, "existing configuration needs deliberate migration review")
	for _, item in ipairs(expected) do edit(authority, binding, "review-choice", { id = item.id, source = 1 }) end
	edit(authority, binding, "review-confirm", {})
	view = snapshot(authority, binding)
	check(view.ready and #view.attempts == 0, "migration review never starts agents")
	same(view.records, expected, "authority migration uses canonical config transformation")
	same(db.peek("config"), original, "minimal fixture remains exact at original key")
	same(db.peek("migration-original"), original, "minimal fixture remains exact in backup")
end
end

-- Missing saved scope, future formats and corruption fail closed instead of resetting history.
sections.invalid_authority = function()
	local db, authority, binding = fresh({ record("preserved") })
	local original = db.image()
	local absent = boundary()
	local missing = modules(absent)
	refused_unchanged(absent, function() return missing.open("host-A", 4, nil, binding.session_key) end, "missing saved authority on reopen")
	refused_unchanged(absent, function() return missing.snapshot(binding) end, "snapshot of missing saved authority")
	refused_unchanged(absent, function() return missing.request(binding, request(binding, "missing", 1, 1)) end, "request against missing saved authority")
	local mutations = {
		function(value) value.version = 99 end,
		function(value) value.version = 1 end,
		function(value) value.reviewed_sources["1"] = { schema = 1, agents = {} } end,
		function(value) value.reviewed_sources["1"] = { config = { schema = 1, agents = {} } } end,
		function(value) value.reviewed_sources["1"] = { host_key = "", config = { schema = 1, agents = {} } } end,
		function(value) value.reviewed_sources["1"] = { host_key = "client-alias", config = { schema = 99 } } end,
		function(value) value.reviewed_sources["1"] = { host_key = "client-alias", config = { schema = 1, agents = "corrupt" } } end,
		function(value) value.reviewed_sources["1"] = { host_key = "client-alias", config = { schema = 1, agents = {} }, unexpected = true } end,
		function(value) value.config.hosts["host-A"].agents = "corrupt" end,
		function(value) value.sessions[binding.session_key].launch.version = 99 end,
		function(value) value.sessions[binding.session_key].request_sequences.bad = -1 end,
		function(value) value.sessions[binding.session_key] = nil end,
	}
	for index, mutate in ipairs(mutations) do
		local seed = copy(original)
		mutate(seed.authority)
		local broken_db = boundary(seed)
		local broken = modules(broken_db)
		refused_unchanged(broken_db, function() return broken.open("host-A", 4, nil, binding.session_key) end, "invalid saved authority reopen " .. tostring(index))
		refused_unchanged(broken_db, function() return broken.snapshot(binding) end, "invalid saved authority snapshot " .. tostring(index))
		refused_unchanged(broken_db, function() return broken.request(binding, request(binding, "broken", 1, 1)) end, "invalid saved authority request " .. tostring(index))
	end
	db.fail_get = "authority"
	refused_unchanged(db, function() return authority.snapshot(binding) end, "failed authority read")
end
sections.invalid_migration = function()
for _, original in ipairs({ { schema = 99, agents = {} }, { schema = 2, hosts = false }, { schema = 1, agents = { record("same"), record("same") } } }) do
	local db = boundary({ config = original })
	local authority = modules(db)
	refused_unchanged(db, function() return authority.open("host-A", 4) end, "future or corrupt migration source")
end
end
sections.backup_failure = function()
	local original = { schema = 1, agents = { record("backup") } }
	local db = boundary({ config = original })
	local authority = modules(db)
	db.fail_set = "migration-original"
	refused_unchanged(db, function() return authority.open("host-A", 4) end, "failed original preservation")
	check(db.peek("authority") == nil, "failed migration backup cannot initialize authority")
end

sections.execution_lifecycle = function()
	local empty = modules(boundary())
	same(empty.execution_bindings(), {}, "uninitialized host has no execution bindings")
	local db, authority, binding = fresh({ record("native") })
	local old_wire = request(binding, "old-window", 1, 1); old_wire.version = 1
	refused_unchanged(db, function() return authority.request(binding, old_wire) end, "retired wire protocol")
	local old_observe = request(binding, "old-window", 1, 1, "observe_attempt", {})
	refused_unchanged(db, function() return authority.request(binding, old_observe) end, "window cannot publish execution evidence")
	local admitted = submit(authority, binding, reserve_request(binding, "window", 1, 1, "native"))
	local id = admitted.result.attempt.id
	check(admitted.result.job.stage == "admitted" and admitted.result.job.command == nil and admitted.result.job.record == nil, "wire admission exposes only inert public job")
	check(admitted.result.attempt.observer_id ~= "window", "host owns runtime observations")
	local bindings = assert(authority.execution_bindings())
	same(bindings, { binding }, "executor discovers durable native scope")
	local before = db.image()
	local jobs = assert(authority.execution_jobs(binding))
	jobs[1].provider = "tampered"
	same(db.image(), before, "private execution reads are detached")
	local wrong_scope = copy(binding); wrong_scope.native_session = 5
	refused_unchanged(db, function() return authority.execution_job(wrong_scope, id) end, "wrong native session")
	local invalid = native(); invalid.executable = "relative-tern"
	refused_unchanged(db, function() return authority.claim_execution(binding, id, invalid) end, "claim without absolute fresh executable")
	db.fail_after(1)
	refused_unchanged(db, function() return authority.claim_execution(binding, id, native()) end, "failed atomic claim")
	local job = claim(authority, binding, id)
	check(job.stage == "claimed" and snapshot(authority, binding).attempts[1].pane == 42, "claim binds job and attempt atomically")
	refused_unchanged(db, function() return authority.claim_execution(binding, id, native(43)) end, "duplicate claim")
	refused_unchanged(db, function() return authority.update_execution(binding, id, "admitted", { stage = "failed" }, { phase = "Failed" }) end, "expected-stage compare")
	refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { stage = "running" }, { phase = "Running" }) end, "cannot bypass persisted submission intent")
	local revision = snapshot(authority, binding).attempt_revision
	update(authority, binding, id, "claimed", { epoch = "daemon:1", native_tab = 7 })
	check(snapshot(authority, binding).attempt_revision > revision, "metadata-only change advances launch revision")
	refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { epoch = "daemon:2" }) end, "immutable native epoch")
	db.fail_after(1)
	refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" }) end, "intent persistence fails before permission")
	update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "submission_intent", { command = "other-cli" }) end, "immutable submitted command")
	update(authority, binding, id, "submission_intent", { stage = "submitted" })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "submitted", { stage = "running" }, { phase = "Running", pane = 43 }) end, "host pane evidence fence")
	update(authority, binding, id, "submitted", { stage = "running" }, { phase = "Running" })
	update(authority, binding, id, "running", { stage = "completed" }, { phase = "Failed", exit_status = 23 })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "submission_intent", { stage = "submitted" }) end, "late submitted callback loses completion race")
	refused_unchanged(db, function() return authority.update_execution(binding, id, "completed", { stage = "running" }, { phase = "Running" }) end, "wrapper alive cannot undo completion")
	update(authority, binding, id, "completed", {}, { phase = "Unknown", diagnostic = "wrapper disappeared" })
	local finished = snapshot(authority, binding)
	check(finished.attempts[1].phase == "Failed" and finished.attempts[1].exit_status == 23, "completion wins over shell disappearance")
	update(authority, binding, id, "completed", { pane_reused = true })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "completed", { pane_reused = false }) end, "pane reuse remains monotonic")
	check(snapshot(authority, binding).jobs[1].pane_reused, "public job preserves provider artwork invalidation")
end

sections.execution_approval = function()
	for _, claimed in ipairs({ false, true }) do
		local db, authority, binding = fresh({ record("approval") })
		local admitted = submit(authority, binding, reserve_request(binding, "window", 1, 1, "approval"))
		local id = admitted.result.attempt.id
		if claimed then claim(authority, binding, id) end
		edit(authority, binding, "replace-records", { records = { record("approval", { command = "changed" }) } })
		if claimed then
			refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" }) end, "approval changes before submission", "approval-revision-changed")
		else
			refused_unchanged(db, function() return authority.claim_execution(binding, id, native()) end, "approval changes before claim", "approval-revision-changed")
		end
		refused_unchanged(db, function() return authority.execution_record(binding, id) end, "approved record lookup after change", "approval-revision-changed")
	end
	local db, authority, binding = fresh({ record("reused") })
	local id = submit(authority, binding, reserve_request(binding, "window", 1, 1, "reused")).result.attempt.id
	claim(authority, binding, id)
	update(authority, binding, id, "claimed", { pane_reused = true })
	refused_unchanged(db, function() return authority.update_execution(binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" }) end, "pane reuse blocks provider submission")
end

sections.admission_expiry = function()
	for _, path in ipairs({ "snapshot", "claim" }) do
		local db, authority, binding = fresh({ record("expired") })
		local id = submit(authority, binding, reserve_request(binding, "window", 1, 1, "expired")).result.attempt.id
		check(authority.execution_job(binding, id).admitted_at == db.now, "drain forwards captured admission time")
		db.now += 29
		check(snapshot(authority, binding).jobs[1].stage == "admitted", "admission remains claimable before deadline")
		db.now += 1
		if path == "claim" then check(authority.claim_execution(binding, id, native()) == nil, "expired claim supplies no execution permission")
		else snapshot(authority, binding) end
		local view = snapshot(authority, binding)
		local a = view.attempts[1]
		check(view.jobs[1].stage == "failed" and a.phase == "Failed" and not a.unresolved and a.diagnostic == "Never started (ticket not claimed)", path .. ": 30 second expiry settles to Failed history")
		refused_unchanged(db, function() return authority.claim_execution(binding, id, native()) end, path .. ": an expired ticket is never claimable later")
		check(submit(authority, binding, reserve_request(binding, "window", 2, 1, "expired")).ok, path .. ": a new launch gets its own ticket")
	end
end

sections.clear_history = function()
	local helper = record("helper", { provider = "omp", backend = "native-agent", enabled = false, prompt = "Approved normal prompt" })
	local db, authority, binding = fresh({ helper, record("active") })
	local setup = request(binding, "window", 1, 1, "start_setup", { record_id = "helper", setup_run_id = "setup-once" })
	local reply = submit(authority, binding, setup)
	check(reply.ok and reply.result.job.initial_prompt ~= helper.prompt, "disabled reviewed helper has dedicated setup prompt")
	local helper_id = reply.result.attempt.id
	claim(authority, binding, helper_id)
	update(authority, binding, helper_id, "claimed", { stage = "submission_intent", command = "omp setup" })
	update(authority, binding, helper_id, "submission_intent", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
	local active_id = submit(authority, binding, reserve_request(binding, "window", 2, 1, "active")).result.attempt.id
	local before = db.peek("authority").sessions[binding.session_key]
	local view = snapshot(authority, binding)
	edit(authority, binding, "clear-history", { attempt_revision = view.attempt_revision })
	local after = db.peek("authority").sessions[binding.session_key]
	check(#after.launch.attempts == 1 and after.launch.attempts[1].id == active_id, "cleanup retains every unresolved attempt")
	check(count(after.jobs) == 1 and after.jobs[active_id] ~= nil and after.jobs[helper_id] == nil, "cleanup removes only corresponding released jobs")
	check(after.launch.next_attempt == before.launch.next_attempt, "history cleanup never reuses attempt IDs")
	check(authority.request(binding, setup), "redelivered setup request is answered from its retained reply")
	check(#snapshot(authority, binding).attempts == 1, "redelivery never starts the cleared setup run again")
	check(authority.execution_job(binding, helper_id) == nil, "removed private job cannot be recovered or claimed")
end

sections.late_completion = function()
	for _, settled in ipairs({ false, true }) do
		local db, authority, binding = fresh({ record("late") })
		local id = submit(authority, binding, reserve_request(binding, "window", 1, 1, "late")).result.attempt.id
		claim(authority, binding, id)
		update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
		update(authority, binding, id, "submission_intent", { stage = "unknown" }, { phase = "Unknown", diagnostic = "lost host observation" })
		refused_unchanged(db, function() return authority.update_execution(binding, id, "unknown", { stage = "submission_intent", command = "ordinary-cli" }) end, "unknown may never resend")
		if settled then
			check(authority.sweep(binding, {}, nil, db.now) == 1, "the sweep ends the attempt whose pane is gone")
			refused_unchanged(db, function() return authority.update_execution(binding, id, "resolved", { stage = "running" }, { phase = "Running" }) end, "settled attempt cannot regain liveness")
		else
			update(authority, binding, id, "unknown", { stage = "running" }, { phase = "Running" })
		end
		update(authority, binding, id, if settled then "resolved" else "running", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
		local view = snapshot(authority, binding)
		check(view.jobs[1].stage == "completed" and view.attempts[1].phase == "Exited" and view.attempts[1].exit_status == 0 and not view.attempts[1].unresolved, "late host completion supersedes uncertainty or automatic settlement")
	end
end

-- Stored jobs from before the record-copy removal stay valid and are stripped
-- on the next persist; a pending legacy inbox is refused rather than dropped.
sections.legacy_job = function()
	local db, authority, binding = fresh({ record("legacy") })
	local id = submit(authority, binding, reserve_request(binding, "window", 1, 1, "legacy")).result.attempt.id
	local image = db.image()
	local scope = image.authority.sessions[binding.session_key]
	local job = scope.jobs[id]
	job.record = record("legacy", { retired_field = "today's validator would reject this copy" })
	job.provider, job.account_label, job.backend, job.placement, job.cwd = nil, nil, nil, nil, nil
	scope.inbox, scope.imports, scope.setup_runs = {}, { old = {} }, { old = {} }
	local legacy_db = boundary(image)
	local legacy = modules(legacy_db)
	local view = snapshot(legacy, binding)
	check(view.jobs[1].provider == "custom" and view.jobs[1].account_label == "legacy" and view.jobs[1].cwd == "~", "legacy job keeps its admission display fields")
	claim(legacy, binding, id)
	local stored = legacy_db.peek("authority").sessions[binding.session_key]
	check(stored.jobs[id].record == nil and stored.jobs[id].provider == "custom", "next persist strips the record copy")
	check(stored.inbox == nil and stored.imports == nil and stored.setup_runs == nil, "next persist strips retired receipts")
	check(assert(legacy.execution_record(binding, id)).command == "ordinary-cli", "submission reads the approved record from current configuration")
	update(legacy, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	local pending = copy(image)
	pending.authority.sessions[binding.session_key].inbox = { reserve_request(binding, "window", 2, 1, "legacy") }
	local pending_db = boundary(pending)
	local blocked = modules(pending_db)
	refused_unchanged(pending_db, function() return blocked.snapshot(binding) end, "legacy pending request")
	refused_unchanged(pending_db, function() return blocked.request(binding, reserve_request(binding, "window", 3, 1, "legacy")) end, "request over legacy pending request")
end

-- Ended session buckets are forgotten only against a verified live inventory.
sections.forget_sessions = function()
	local db, authority, binding = fresh({ record("kept") })
	local ended = assert(authority.open("host-A", 5))
	local live = assert(authority.open("host-A", 6))
	for sequence = 1, 2 do
		local id = submit(authority, ended, reserve_request(ended, "window", sequence, 1, "kept")).result.attempt.id
		claim(authority, ended, id, 40 + sequence)
		update(authority, ended, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
		update(authority, ended, id, "submission_intent", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
	end
	local running = assert(authority.open("host-A", 7))
	local running_id = submit(authority, running, reserve_request(running, "window", 1, 1, "kept")).result.attempt.id
	claim(authority, running, running_id, 50)
	update(authority, running, running_id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	update(authority, running, running_id, "submission_intent", { stage = "running" }, { phase = "Running" })
	for _, inventory in ipairs({ false, {}, { [6] = "yes" }, { ["6"] = true } }) do
		refused_unchanged(db, function() return authority.forget_sessions(binding, inventory or nil, true) end, "forget without a verified inventory")
	end
	local before = db.image()
	local preview = assert(authority.forget_sessions(binding, { [6] = true }, false))
	check(preview.sessions == 1 and preview.attempts == 2 and preview.bytes > 0 and preview.kept == 1, "preview counts ended sessions, attempts, bytes and active absent sessions kept")
	same(db.image(), before, "preview changes nothing")
	local writes = db.authority_writes
	local result = assert(authority.forget_sessions(binding, { [6] = true }, true))
	same(result, preview, "forget reports what it removed")
	check(db.authority_writes == writes + 1, "forget is one atomic persist")
	local sessions = db.peek("authority").sessions
	check(sessions[ended.session_key] == nil, "ended session bucket is removed")
	check(sessions[binding.session_key] ~= nil and sessions[live.session_key] ~= nil, "bound and live sessions are kept")
	check(sessions[running.session_key] ~= nil, "an absent session with a Running attempt is kept")
	check(#runtime.json.encode(before.authority) > #runtime.json.encode(db.peek("authority")), "forgetting frees stored bytes")
	local kept = assert(authority.forget_sessions(live, { [4] = true }, true))
	check(kept.sessions == 0 and db.peek("authority").sessions[live.session_key] ~= nil, "the caller's bound session is never forgotten")
end

-- Each write keeps only the 26 newest finished attempts; blocking ones stay.
sections.trim_history = function()
	local db, authority, binding = fresh({ record("many") })
	local sequence = 0
	local function admit()
		sequence += 1
		local acks = if sequence > 1 then { "window/" .. tostring(sequence - 1) } else {}
		return submit(authority, binding, request(binding, "window", sequence, 1, "launch_record", { record_id = "many" }, acks)).result.attempt.id
	end
	local running = admit()
	claim(authority, binding, running, 200)
	update(authority, binding, running, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	update(authority, binding, running, "submission_intent", { stage = "running" }, { phase = "Running" })
	local unknown = admit()
	update(authority, binding, unknown, "admitted", { stage = "unknown" }, { phase = "Unknown" })
	local finished = {}
	for index = 1, 30 do
		local id = admit()
		claim(authority, binding, id, 300 + index)
		update(authority, binding, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
		local writes = db.authority_writes
		update(authority, binding, id, "submission_intent", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
		check(db.authority_writes == writes + 1, "completion and trimming commit in one atomic write")
		table.insert(finished, id)
	end
	local function kept()
		local stored = db.peek("authority").sessions[binding.session_key]
		local ids = {}
		for _, a in ipairs(stored.launch.attempts) do ids[a.id] = true end
		check(count(stored.jobs) == #stored.launch.attempts, "trimmed attempts take their jobs with them")
		return ids
	end
	local ids = kept()
	check(ids[running] and ids[unknown], "active and unresolved attempts are never trimmed")
	for index, id in ipairs(finished) do check((ids[id] == true) == (index > 4), "exactly the 26 newest finished attempts are kept") end
	check(authority.sweep(binding, { [200] = { title = "ordinary-cli" } }, nil, db.now + authority.ADMISSION_SECONDS) == 1, "the sweep settles the never-claimed Unknown")
	ids = kept()
	check(not ids[unknown] and ids[running] and ids[finished[5]], "a newly settled older attempt is trimmed in the same write")
end

-- Runs the real host Config block against the real authority; native
-- inspection reports session 4 holding the block unless `fail` is set.
local function host_block(db, authority, config)
	local _,_,_,load=modules(db)
	local pane, definition = 9, nil
	local harness = { fail = false }
	local native_cli = { inspect = function(_window, _options, callback)
		if harness.fail then callback({ status = 1, timed_out = false, stdout = "", stderr = "injected inspection failure" }, nil); return end
		callback({ status = 0, timed_out = false, stdout = runtime.json.encode({ sessions = { { id = 4, tabs = { { blocks = { { id = pane } } } } } } }) }, nil)
	end }
	local fake = setmetatable({
		kv = db.kv, on = function() end, timer = function() end, now = function() return 0 end,
		ui = { text = function(value) return { t = value } end, col = function(children) return children end, node = function() return {} end },
		block = { define = function(name, value) if name=="spawner" then definition = value end end },
	}, { __index = runtime })
	local chunk = assert(loadstring(runtime.fs.read(root .. "/host.luau"), "host"))
	setfenv(chunk, setmetatable({ tern = fake, require = function(name)
		if name == "./config" then return config end
		if name == "./authority" then return authority end
		if name == "./native_cli" then return native_cli end
		if name == "./host_executor" then return { install = function() end, attach = function() end, epoch = function() return nil end } end
		if name == "./dispatch" then return {recovery_view=function()return {}end,import_decode=function()return nil end} end
		if name == "./codec" then return load("codec") end
		error("Unexpected host dependency: " .. name)
	end }, { __index = environment }))
	chunk()
	harness.definition, harness.cx = definition, { pane = pane, save = function() end, render = function() end }
	harness.state = definition.init(harness.cx, { runtime.json.encode({ host = { name = "A" }, native_window = "w" }) }, nil)
	return harness
end

-- A freshly verified inventory forgets ended sessions automatically; failed
-- inspection and absent sessions with an active launch are left alone.
sections.auto_forget = function()
	local db = boundary()
	local authority, config = modules(db)
	local ended = assert(authority.open("host:a", 5))
	check(authority.edit(ended, 0, "replace-records", { records = { record("x") } }), "seed a launchable record")
	local active = assert(authority.open("host:a", 7))
	check(submit(authority, active, reserve_request(active, "window", 1, 1, "x")).ok, "absent session holds an active launch")
	local harness = host_block(db, authority, config)
	local state = harness.state
	check(state.binding ~= nil and state.binding.native_session == 4, "host block binds its verified session")
	local sessions = db.peek("authority").sessions
	check(sessions[ended.session_key] == nil, "verified inventory forgets the ended session automatically")
	check(sessions[active.session_key] ~= nil and sessions[state.binding.session_key] ~= nil, "bound session and absent session with an active launch are kept")
	check(state.forget.sessions == 1 and state.forget.kept == 1, "status reports what was forgotten and kept")
	local later = assert(authority.open("host:a", 8))
	harness.fail = true
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	check(db.peek("authority").sessions[later.session_key] ~= nil, "failed inspection forgets nothing")
	harness.fail = false
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	check(db.peek("authority").sessions[later.session_key] == nil, "the next verified inventory forgets it")
end

-- Refusals that admitted nothing reach their requester through the rendered
-- replies at once; they never shadow durable replies and stay bounded.
sections.transient_reply = function()
	local db = boundary()
	local authority, config = modules(db)
	local harness = host_block(db, authority, config)
	local definition, state, cx = harness.definition, harness.state, harness.cx
	local binding = assert(state.binding, "host block binds its authority")
	local function send(value) definition.event(state, { ev = "action", id = "main", act = "spawn.request", value = runtime.json.encode(value) }, cx) end
	local function replies()
		local text = definition.view(state, cx).main[2].t
		return runtime.json.decode(text:sub(#"SPAWN_STATE_V2 " + 1)).replies
	end
	send(request(binding, "A", 1, 0))
	check(replies()["A/1"].ok, "durable reply is rendered")
	local invalid = request(binding, "A", 2, 0); invalid.op = "bogus"
	send(invalid)
	local reply = replies()["A/2"]
	check(reply ~= nil and not reply.ok and reply.observer_id == "A" and reply.request_sequence == 2 and type(reply.error) == "string", "invalid request refusal reaches its requester at once")
	check(db.peek("authority").sessions[binding.session_key].replies["A/2"] == nil, "refusal reply is not persisted")
	local stale = request(binding, "A", 1, 0); stale.request_id = "A/stale"
	send(stale)
	check(replies()["A/stale"] ~= nil and not replies()["A/stale"].ok, "stale-sequence refusal reaches its requester")
	local reused = request(binding, "A", 1, 5)
	send(reused)
	check(replies()["A/1"].ok, "a refusal never shadows the durable reply for the same request ID")
	local foreign = request(binding, "B", 1, 0); foreign.authority_id = "other-generation"
	send(foreign)
	check(replies()["B/1"] == nil, "a refusal for another authority generation is not rendered")
	for _, item in pairs(replies()) do check(item.observer_id == "A", "only requests that were sent produce replies, each naming its requester") end
	send(request(binding, "A", 3, 0, nil, nil, { "A/1", "A/2", "A/stale" }))
	check(replies()["A/2"] == nil and replies()["A/stale"] == nil, "acknowledged refusals are released")
	for index = 1, 20 do local value = request(binding, "D", index, 0); value.op = "bogus"; send(value) end
	local refused = 0
	for _, item in pairs(replies()) do if item.observer_id == "D" then refused += 1 end end
	check(refused == 16, "refusal replies are bounded")
end

-- R3: after a host restart every ordinary attempt first waits out a time-based
-- grace (Tern restores panes after the host loads). A pane in which Tern reran the
-- agent command is re-adopted at any sweep during grace; the rest end together in
-- one write once grace expires. Managed attempts are never touched.
sections.sweep_restart = function()
	local db, authority, binding = fresh({ record("agent"), record("rerun"), record("slow"), record("managed") })
	local admit = admitter(authority, binding)
	local a, b = admit("agent"), admit("agent")
	run_job(authority, binding, a, 41, "daemon:1"); run_job(authority, binding, b, 42, "daemon:1")
	local legacy = admit("agent"); run_job(authority, binding, legacy, 43, "daemon:1")
	update(authority, binding, legacy, "running", { stage = "unknown" }, { phase = "Unknown", error_category = "host-unavailable", diagnostic = "Host restarted (daemon epoch changed): lost; execution will not be repeated" })
	local rerun = admit("rerun"); run_job(authority, binding, rerun, 44, "daemon:1")
	update(authority, binding, rerun, "running", { process_identity = "boot:100:old" })
	update(authority, binding, rerun, "running", { stage = "unknown" }, { phase = "Unknown", diagnostic = "Host restarted (daemon epoch changed): lost; execution will not be repeated" })
	local slow = admit("slow"); run_job(authority, binding, slow, 45, "daemon:1")
	local managed = assert(authority.managed_reserve(binding, 1, "managed", "bridge-observer"))
	check(authority.managed_observe(binding, managed.id, "bridge-observer", { phase = "Running", pane = 46 }), "managed attempt runs in its own pane")
	local function view_at(epoch) return assert(authority.snapshot(binding, epoch)) end
	local managed_before = by_id(view_at(nil))[managed.id]
	check(view_at("daemon:2").host_restart_notice == nil, "no notice before any sweep")
	local grace = authority.RESTART_GRACE_SECONDS
	local start = db.now
	local writes = db.authority_writes
	check(authority.sweep(binding, {}, "daemon:2", start) == 5, "the load-time sweep starts grace for every ordinary attempt")
	check(db.authority_writes == writes + 1, "starting grace commits in one persist")
	local attempts, jobs = by_id(view_at("daemon:2"))
	check(attempts[a].phase == "Running" and attempts[b].phase == "Running" and attempts[slow].phase == "Running" and attempts[legacy].phase == "Unknown" and attempts[rerun].phase == "Unknown", "no pane restored yet ends nothing during grace")
	local stored = db.peek("authority").sessions[binding.session_key].jobs
	for _, id in ipairs({ a, b, legacy, rerun, slow }) do
		check(stored[id].restart_grace == "daemon:2" and stored[id].restart_grace_at == start and stored[id].epoch == "daemon:1", id .. ": grace records only the epoch and its start")
	end
	check(view_at("daemon:2").host_restart_notice == nil, "grace raises no notice")
	local panes = { [44] = { title = "ordinary-cli" }, [45] = { title = "bash" } }
	writes = db.authority_writes
	check(authority.sweep(binding, panes, "daemon:2", start + 5) == 1 and db.authority_writes == writes + 1, "a later sweep during grace re-adopts the rerun agent")
	attempts, jobs = by_id(view_at("daemon:2"))
	check(attempts[rerun].phase == "Running" and attempts[rerun].unresolved and attempts[rerun].diagnostic == "Re-adopted after host restart (Tern reran the agent command)" and jobs[rerun].stage == "running", "a pane titled with the agent command is re-adopted")
	stored = db.peek("authority").sessions[binding.session_key].jobs
	check(stored[rerun].epoch == "daemon:2" and stored[rerun].process_identity == nil and stored[rerun].restart_grace == nil and stored[rerun].restart_grace_at == nil, "re-adoption records the new epoch and drops the dead process identity")
	check(attempts[slow].phase == "Running" and attempts[a].phase == "Running", "other attempts keep waiting")
	local waiting = db.image()
	check(authority.sweep(binding, panes, "daemon:2", start + grace - 1) == 0, "nothing ends before grace expires")
	same(db.image(), waiting, "no persist while waiting")
	writes = db.authority_writes
	check(authority.sweep(binding, panes, "daemon:2", start + grace) == 4 and db.authority_writes == writes + 1, "expired grace ends every unadopted attempt in one persist")
	local view = view_at("daemon:2")
	attempts, jobs = by_id(view)
	for _, id in ipairs({ a, b, legacy, slow }) do
		local ended = attempts[id]
		check(ended.phase == "Exited" and not ended.unresolved and ended.diagnostic == "Host restarted" and jobs[id].stage == "resolved", id .. ": an unadopted attempt moves to history as Host restarted")
	end
	check(attempts[rerun].phase == "Running", "a re-adopted attempt stays live under its new epoch")
	same(attempts[managed.id], managed_before, "the sweep never touches a managed attempt")
	local restart = view.host_restart_notice
	check(restart ~= nil and restart.count == 4 and type(restart.restart_id) == "string" and #restart.restart_id == 32 and restart.restart_id:find("daemon", 1, true) == nil, "the informational notice counts ended attempts under a digest of the epoch")
	check(count(restart) == 2, "the notice carries only restart_id and count")
	-- A pre-0.5.0 window validates host_restart only as blocking Unknown attempts.
	check(view.host_restart == nil, "the legacy host_restart key is never published")
	check(view_at("daemon:1").host_restart_notice == nil and view_at(nil).host_restart_notice == nil, "another or unknown epoch shows no notice")
	local settled = db.image()
	check(authority.sweep(binding, panes, "daemon:2", start + grace + 15) == 0, "a settled store has nothing to change")
	same(db.image(), settled, "no persist when nothing changed")
	same(by_id(view_at(nil))[managed.id], managed_before, "managed attempt is unchanged after every sweep")
end

-- R3 without a restart: a closed pane ends its attempt, an unclaimed ticket fails,
-- and an unverifiable host epoch (nil) falls back to the pane rule alone.
sections.sweep_pane = function()
	local db, authority, binding = fresh({ record("agent") })
	local admit = admitter(authority, binding)
	local closed = admit("agent"); run_job(authority, binding, closed, 61, "daemon:1")
	local kept = admit("agent"); run_job(authority, binding, kept, 62, "daemon:1")
	local starting = admit("agent"); claim(authority, binding, starting, 63)
	local ticket = admit("agent")
	local panes = { [62] = { title = "ordinary-cli" }, [63] = { title = "bash" } }
	local other = copy(binding); other.native_session = 5
	for _, case in ipairs({
		{ name = "missing pane inventory", run = function() return authority.sweep(binding, nil, "daemon:1", db.now) end },
		{ name = "string pane id", run = function() return authority.sweep(binding, { ["61"] = {} }, "daemon:1", db.now) end },
		{ name = "non-table pane entry", run = function() return authority.sweep(binding, { [61] = true }, "daemon:1", db.now) end },
		{ name = "invalid epoch", run = function() return authority.sweep(binding, panes, 7, db.now) end },
		{ name = "missing clock", run = function() return authority.sweep(binding, panes, "daemon:1", nil) end },
		{ name = "other native session", run = function() return authority.sweep(other, panes, "daemon:1", db.now) end },
	}) do refused_unchanged(db, case.run, "sweep with " .. case.name) end
	check(authority.sweep(binding, panes, nil, db.now) == 1, "with an unverifiable epoch only the closed pane settles")
	local attempts, jobs = by_id(snapshot(authority, binding))
	check(attempts[closed].phase == "Exited" and not attempts[closed].unresolved and attempts[closed].diagnostic == "Pane closed" and jobs[closed].stage == "resolved", "an absent pane moves to history as Pane closed")
	check(attempts[kept].phase == "Running" and attempts[kept].unresolved, "a present pane stays live")
	check(db.peek("authority").sessions[binding.session_key].jobs[kept].restart_grace == nil, "a nil epoch is never read as a restart")
	check(attempts[starting].phase == "Starting" and attempts[ticket].phase == "Starting" and jobs[ticket].stage == "admitted", "claims in flight and fresh tickets wait")
	check(authority.sweep(binding, { [63] = { title = "bash" } }, "daemon:1", db.now) == 1, "the same epoch applies the pane rule")
	attempts = by_id(snapshot(authority, binding))
	check(attempts[kept].phase == "Exited" and attempts[kept].diagnostic == "Pane closed", "a pane closed under the recording epoch is Pane closed, not Host restarted")
	check(assert(authority.snapshot(binding, "daemon:1")).host_restart_notice == nil, "pane closures never raise the restart notice")
	check(authority.sweep(binding, { [63] = { title = "bash" } }, "daemon:1", db.now + authority.ADMISSION_SECONDS) == 1, "the deadline settles only the unclaimed ticket")
	attempts, jobs = by_id(snapshot(authority, binding))
	check(attempts[ticket].phase == "Failed" and not attempts[ticket].unresolved and attempts[ticket].diagnostic == "Never started (ticket not claimed)" and jobs[ticket].stage == "failed", "an unclaimed ticket moves to history as Failed")
	check(authority.sweep(binding, {}, "daemon:1", db.now) == 1, "a claimed pane that closes before submission settles")
	attempts, jobs = by_id(snapshot(authority, binding))
	check(attempts[starting].phase == "Exited" and attempts[starting].diagnostic == "Pane closed" and jobs[starting].stage == "resolved", "a Starting attempt whose pane is gone is never shown live")
	for _, a in pairs(attempts) do check(not a.unresolved, a.id .. " is history") end
end

-- Cold start: a store written before automatic settlement holds blocking
-- Unknowns; the first host sweep settles every one of them in one write.
sections.sweep_legacy = function()
	local db, authority, binding = fresh({ record("agent") })
	local admit = admitter(authority, binding)
	local expired = admit("agent")
	update(authority, binding, expired, "admitted", { stage = "unknown" }, { phase = "Unknown", diagnostic = "The launch ticket was not claimed within 30 seconds." })
	local lost = admit("agent"); run_job(authority, binding, lost, 91, "daemon:1")
	update(authority, binding, lost, "running", { stage = "unknown" }, { phase = "Unknown", error_category = "host-unavailable", diagnostic = "Host restarted (daemon epoch changed): lost; execution will not be repeated" })
	local alive = admit("agent"); run_job(authority, binding, alive, 92, "daemon:1")
	update(authority, binding, alive, "running", { stage = "unknown" }, { phase = "Unknown", diagnostic = "The native pane does not retain its exact host ticket and shell" })
	local unsent = admit("agent"); claim(authority, binding, unsent, 93)
	update(authority, binding, unsent, "claimed", { stage = "unknown" }, { phase = "Unknown", diagnostic = "No verified provider process identity survived reload; execution will not be repeated" })
	local released = admit("agent"); run_job(authority, binding, released, 94, "daemon:1")
	update(authority, binding, released, "running", { stage = "unknown" }, { phase = "Unknown" })
	-- Older versions' manual release left a resolved Unknown in history.
	local image = db.image()
	local scope = image.authority.sessions[binding.session_key]
	for _, a in ipairs(scope.launch.attempts) do if a.id == released then a.unresolved = false end end
	scope.jobs[released].stage = "resolved"
	local cold_db = boundary(image)
	local cold = modules(cold_db)
	local unresolved = 0
	for _, a in snapshot(cold, binding).attempts do if a.phase == "Unknown" and a.unresolved then unresolved += 1 end end
	check(unresolved == 4, "the cold store holds four blocking legacy Unknowns")
	local panes = { [92] = { title = "bash" }, [93] = { title = "bash" } }
	local writes = cold_db.authority_writes
	check(cold.sweep(binding, panes, "daemon:1", db.now + cold.ADMISSION_SECONDS) == 5 and cold_db.authority_writes == writes + 1, "the first sweep settles every legacy Unknown in one write")
	local attempts, jobs = by_id(snapshot(cold, binding))
	check(attempts[expired].phase == "Failed" and attempts[expired].diagnostic == "Never started (ticket not claimed)" and jobs[expired].stage == "failed", "a legacy expired ticket fails")
	check(attempts[lost].phase == "Exited" and attempts[lost].diagnostic == "Pane closed" and jobs[lost].stage == "resolved", "a legacy Unknown without its pane ends")
	check(attempts[alive].phase == "Running" and attempts[alive].unresolved and attempts[alive].diagnostic == nil and jobs[alive].stage == "running", "a legacy Unknown whose submitted pane is present is live again")
	check(attempts[unsent].phase == "Failed" and attempts[unsent].diagnostic == "Never started (provider command was not submitted)" and jobs[unsent].stage == "failed", "a legacy claim that never submitted cannot become a provider")
	check(attempts[released].phase == "Exited" and attempts[released].diagnostic == "Pane closed" and jobs[released].stage == "resolved", "a manually released Unknown is settled into ordinary history")
	for _, a in pairs(attempts) do check(a.phase ~= "Unknown", a.id .. " is no longer Unknown") end
	local settled = cold_db.image()
	check(cold.sweep(binding, panes, "daemon:1", db.now + cold.ADMISSION_SECONDS) == 0, "the second sweep has nothing to settle")
	same(cold_db.image(), settled, "a settled cold store is not rewritten")
end

-- Upgrade boundary: manual release is gone. A retained or newly delivered old
-- request is acknowledged as obsolete and never executed; the authority stays readable.
sections.obsolete_release = function()
	local db, authority, binding = fresh({ record("agent") })
	local id = admitter(authority, binding, "launcher")("agent")
	run_job(authority, binding, id, 71, "daemon:1")
	update(authority, binding, id, "running", { stage = "unknown" }, { phase = "Unknown" })
	local image = db.image()
	local scope = image.authority.sessions[binding.session_key]
	local revision = scope.launch.revision
	local released = request(binding, "owner", 1, 1, "resolve_lost_attempts", { attempt_ids = { id }, attempt_revision = revision })
	local refused = request(binding, "owner", 2, 1, "resolve_attempt", { attempt_id = id, attempt_revision = 0 })
	scope.requests[released.request_id], scope.requests[refused.request_id] = released, refused
	scope.replies[released.request_id] = { request_id = released.request_id, observer_id = "owner", request_sequence = 1, ok = true, config_revision = 1, attempt_revision = revision, result = { released = 1 } }
	scope.replies[refused.request_id] = { request_id = refused.request_id, observer_id = "owner", request_sequence = 2, ok = false, error = "stale-attempt-revision", config_revision = 1, attempt_revision = revision }
	scope.request_sequences.owner = 2
	local old_db = boundary(image)
	local upgraded = modules(old_db)
	check(upgraded.validate(old_db.peek("authority")) ~= nil, "a store retaining old release requests validates")
	local view = snapshot(upgraded, binding)
	for _, old in ipairs({ released, refused }) do
		local reply = view.replies[old.request_id]
		check(reply.ok and reply.error == nil and equal(reply.result, { obsolete = true, notice = OBSOLETE_NOTICE }), old.op .. ": a retained old request is acknowledged as obsolete")
	end
	local ledger = old_db.peek("authority").sessions[binding.session_key].launch
	check(by_id(view)[id].phase == "Unknown" and by_id(view)[id].unresolved, "acknowledgement replays nothing")
	local before = old_db.image()
	check(upgraded.request(binding, released), "an identical redelivery is answered from the retained reply")
	same(old_db.image(), before, "redelivery changes nothing")
	local incoming = request(binding, "owner", 3, 0, "resolve_lost_attempts", { attempt_ids = { id }, attempt_revision = view.attempt_revision }, { released.request_id, refused.request_id })
	local reply = submit(upgraded, binding, incoming)
	check(reply.ok and equal(reply.result, { obsolete = true, notice = OBSOLETE_NOTICE }), "a newly delivered old request is acknowledged before any fence")
	local after = snapshot(upgraded, binding)
	check(after.replies[released.request_id] == nil and after.replies[refused.request_id] == nil, "acknowledged obsolete replies are released")
	same(old_db.peek("authority").sessions[binding.session_key].launch, ledger, "an obsolete request never touches the ledger")
	local malformed = request(binding, "owner", 4, 1, "resolve_attempt", { attempt_id = id, reason = "unexpected" })
	refused_unchanged(old_db, function() return upgraded.request(binding, malformed) end, "an obsolete op with unknown fields")
	for _, operation in ipairs({ "resolve-attempt", "resolve-lost-attempts" }) do
		refused_unchanged(old_db, function()
			return upgraded.edit(binding, after.config_revision, operation, { id = id, attempt_ids = { id }, attempt_revision = after.attempt_revision, epoch = "daemon:1" })
		end, operation .. " edit is removed", "Unknown settings operation")
	end
	check(upgraded.sweep(binding, {}, "daemon:1", old_db.now) == 1, "the sweep settles what manual release used to")
	check(by_id(snapshot(upgraded, binding))[id].phase == "Exited", "the attempt is history without any manual step")
end

-- R4: every Spawn is its own attempt. A second launch of a record is admitted
-- while the first is live, in steady state and after a cold start.
sections.repeat_launch = function()
	local db, authority, binding = fresh({ record("agent") })
	local admit = admitter(authority, binding)
	local first = admit("agent")
	local second = admit("agent")
	check(first ~= second, "a second launch while the first is Starting gets its own attempt")
	run_job(authority, binding, first, 81, "daemon:1")
	local third = admit("agent")
	local cold = modules(boundary(db.image()))
	local fourth = submit(cold, binding, request(binding, "cold", 1, 1, "launch_record", { record_id = "agent" }))
	check(fourth.ok, "a cold-started host admits another launch of a live record")
	local attempts = by_id(snapshot(cold, binding))
	local live = 0
	for _, a in pairs(attempts) do if a.unresolved and a.record_id == "agent" then live += 1 end end
	check(live == 4 and attempts[first].phase == "Running" and attempts[third].phase == "Starting", "every copy of the record is live at once")
	edit(authority, binding, "replace-records", { records = { record("agent", { enabled = false }) } })
	local disabled = submit(authority, binding, request(binding, "window", 4, 2, "launch_record", { record_id = "agent" }, { "window/3" }))
	check(not disabled.ok and disabled.error == "disabled", "only a disabled record is skipped")
end

-- Restore boundary: a store written while duplicate_policy existed stays readable;
-- the retired field is stripped from the roster and from managed import receipts.
sections.retired_fields = function()
	local db, authority, binding = fresh({ record("agent") })
	check(assert(authority.managed_import(binding, 1, "bridge-import", { record("imported") })).imported == 1, "seed a managed import receipt")
	local image = db.image()
	local stored = image.authority
	stored.config.hosts["host-A"].agents[1].duplicate_policy = "skip"
	stored.sessions[binding.session_key].managed_imports["bridge-import"][1].duplicate_policy = "allow"
	local old_db = boundary(image)
	local upgraded = modules(old_db)
	local view = snapshot(upgraded, binding)
	check(#view.records == 2 and view.records[1].id == "agent" and view.records[1].duplicate_policy == nil, "a stored record carrying duplicate_policy is read with it stripped")
	check(assert(upgraded.managed_import(binding, -1, "bridge-import", { record("imported") })).replayed, "an old receipt carrying duplicate_policy still replays exactly")
	check(submit(upgraded, binding, reserve_request(binding, "window", 1, view.config_revision, "agent")).ok, "the stripped record launches")
	local saved = old_db.peek("authority")
	check(saved.config.hosts["host-A"].agents[1].duplicate_policy == nil and saved.sessions[binding.session_key].managed_imports["bridge-import"][1].duplicate_policy == nil, "the next persist writes canonical values")
end

local run = assert(sections[section], "unknown authority test section: " .. section)
run()
return "PASS " .. section .. " " .. tostring(checks) .. " SPAWN authority checks"
