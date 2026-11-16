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
		command = "ordinary-cli", arguments = {}, enabled = true, placement = "tab",
	}
	for key, item in pairs(fields or {}) do value[key] = item end
	return value
end
local function boundary(seed)
	local saved = copy(seed or {})
	local db = { writes = 0, authority_writes = 0, now = 1700000000, files = {}, file_reads = {} }
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
	local injected = setmetatable({
		kv=db.kv,plugin={dir=root,data=if runtime.runtime.os=="windows" then "C:/fixture-data" else "/fixture-data"},
		getenv=function(name)
			if name=="SHELL" then return if runtime.runtime.os=="windows" then "pwsh.exe" else "/bin/bash" end
			return runtime.getenv(name)
		end,
		fs=setmetatable({read=function(path,limit)
			if db.files[path]~=nil then
				db.file_reads[path]=(db.file_reads[path] or 0)+1
				local bytes=db.files[path]
				if limit and #bytes>limit then error("injected bounded read refusal") end
				return bytes
			end
			return runtime.fs.read(path,limit)
		end},{__index=runtime.fs}),
	}, { __index = runtime })
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
local function setup_context(binding)
	return {config_pane=10,window="fixture-window",epoch="fixture-host:1",inventory={
		clients={{kind="window",window="fixture-window",conn=1,since=10}},
		sessions={{id=binding.native_session,tabs={{blocks={{id=10,cwd=if runtime.runtime.os=="windows" then "C:/work" else "/work"}}}}}},
	}}
end
local function submit(authority, binding, value, context)
	local ok, err = authority.request(binding, value, context or (if value.data.manual then setup_context(binding) else nil))
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
-- The bytes below come from the real authority single writer, not a handwritten
-- authority fixture. Only its existing KV boundary is isolated; all accounts are dummy.
sections.usage_roster_fixture=function()
	local db=boundary({config={schema=2,hosts={
		["host-A"]={schema=2,agents={
			record("claude-demo",{provider="claude",account_label="Demo Claude Ω",command="claude",profile="demo-profile"}),
			record("codex-demo",{provider="codex",account_label="Demo Codex",command="codex",model="demo-model"}),
			record("omp-demo",{provider="omp",account_label="Demo OMP",backend="native-agent",command="omp",prompt="Open a conversation"}),
		}},
		["host-B"]={schema=2,agents={record("foreign-demo",{provider="claude",account_label="Other execution host",command="claude"})}},
	}}})
	local authority=modules(db)
	local binding,why=authority.open("host-A",4)
	check(binding~=nil,"real authority writer opens dummy current-host roster: "..tostring(why))
	local view=snapshot(authority,binding)
	check(#view.records==3,"ordinary authority projection contains only the current host's dummy accounts")
	check(not view.ready and view.migration ~= nil, "legacy roster requires deliberate source review")
	local expected_records = copy(view.records)
	for _, item in ipairs(expected_records) do
		local selected
		for index, source in ipairs(view.migration.sources) do
			for _, candidate in ipairs(source.records) do
				if equal(candidate, item) then selected = index; break end
			end
			if selected then break end
		end
		check(selected ~= nil, "current-host account is offered by a real review source")
		edit(authority, binding, "review-choice", { id = item.id, source = selected })
	end
	edit(authority, binding, "review-confirm", {})
	view = snapshot(authority, binding)
	check(view.ready and view.migration == nil, "source confirmation releases the settings writer")
	local reviewed = {}
	for _, item in ipairs(view.records) do reviewed[item.id] = item end
	for _, item in ipairs(expected_records) do same(reviewed[item.id], item, "source review preserves the selected account") end
	local reviewed_revision = view.config_revision
	edit(authority,binding,"replace-records",{records=view.records})
	local value=db.peek("authority")
	check(value.version==4 and value.host_key=="host-A" and value.config.schema==2,"writer emits its actual current authority and config schemas")
	check(#value.config.hosts["host-A"].agents==3 and #value.config.hosts["host-B"].agents==1,"writer preserves the other host without joining its accounts")
	check(next(value.sessions)~=nil and value.config_revision==reviewed_revision+1,
		"replacement advances the current host's real reviewed writer revision")
	return runtime.json.encode(value)
end
local function forget(authority,binding,live)
	local preview,why,captured=authority.forget_sessions(binding,live,false)
	if not preview then return nil,why end
	return authority.forget_sessions(binding,live,true,captured)
end
-- Probe fixtures exercise only the authority boundary, never claim runtime proof.
local function setup_record(id)
	local windows=runtime.runtime.os=="windows"
	return record(id,{cwd=if windows then "C:/work" else "/work",
		fresh_executable=if windows then "C:/tools/worker.exe" else "/usr/bin/worker",fresh_arguments={},task_argument_index=1,
		target_os=if windows then "windows" else runtime.runtime.os,argv_contract=if windows then "windows-crt" else nil,
		mailbox={permitted_root=if windows then "C:/mailboxes" else "/mailboxes",
			helper_path=if windows then "C:/helpers/mailbox_target.ps1" else "/helpers/mailbox_target.sh",
			producer_helper_path=if windows then "C:/helpers/mailbox_worker.ps1" else "/helpers/mailbox_worker.sh",
			worker_identity="fixture-worker",verified=false,wake="worker-poll-v1",
			producer={read=true,write=true,hash=true,journal=true,poll=true},capabilities={"report-files-v1","worker-poll-v1","argv-v1"}}})
end
local function setup_evidence(load,value)
	return {record=copy(value),verified=true,probe={schema=1,passed=true,
		record_sha256=load("wire/codec").sha256(runtime.json.encode(value)),bundle_digest=string.rep("a",64),
		worker_identity="fixture-worker",provision_handle="fixture-provision",
		observations={
			{id="launch-construction",state="passed",summary="Deterministic authority fixture, not an actual runtime probe"},
			{id="native-route",state="passed",summary="Deterministic authority fixture, not actual native route execution proof"},
			{id="account-cli-folder-dependencies",state="passed",summary="Deterministic authority fixture"},
			{id="serializer-argv",state="passed",summary="Deterministic authority fixture"},
			{id="helper-provision",state="passed",summary="Deterministic authority fixture"},
			{id="provision-readback",state="passed",summary="Deterministic authority fixture"},
		}}}
end
local function setup_view(authority)
	local view,why=authority.setup_snapshot("host-A")
	assert(view,tostring(why))
	return view
end
local function setup_write(authority,operation,data)
	local ok,why=authority.setup_edit("host-A",setup_view(authority).config_revision,operation,data or {})
	check(ok,"accept deliberate setup "..operation..": "..tostring(why))
end

sections.setup_lifecycle=function()
	local db=boundary();local authority=modules(db)
	local view=setup_view(authority)
	check(view.setup.schema==1 and view.setup.state=="not_started" and view.config_revision==0 and #view.records==0,"genuinely absent authority has explicit empty not-started setup")
	check(view.namespace==nil and view.setup.readiness.state=="not_run" and db.writes==0,"cold read allocates no namespace, scopes or persistence")
	view.setup.state="completed";view.records[1]=record("injected")
	check(setup_view(authority).setup.state=="not_started" and db.writes==0,"read-only projection is detached")
	setup_write(authority,"begin")
	view=setup_view(authority)
	check(view.setup.state=="in_progress" and view.config_revision==1 and view.setup.config_revision==1,"begin persists lifecycle and revision")
	check(next(db.peek("authority").sessions)==nil,"setup writer works without an ordinary scope")
	local namespace=view.namespace
	refused_unchanged(db,function()return authority.setup_edit("host-A",0,"dismiss",{})end,"second window cannot dismiss with stale setup revision")
	setup_write(authority,"dismiss")
	local reloaded=modules(db)
	check(setup_view(reloaded).setup.state=="dismissed" and setup_view(reloaded).namespace==namespace,"explicit dismissal survives reload")
	setup_write(reloaded,"begin")
	check(setup_view(reloaded).setup.state=="in_progress","explicit begin resumes dismissed setup")
	local binding=assert(reloaded.open("host-A",4))
	edit(reloaded,binding,"replace-records",{records={record("ordinary")}})
	view=snapshot(reloaded,binding)
	check(view.setup.state=="in_progress" and view.setup.config_revision==view.config_revision,"ordinary records do not imply managed setup completion")
	same(reloaded.managed_snapshot(binding).setup,view.setup,"ordinary and managed snapshots publish the same lifecycle")
	local writes=db.writes
	setup_view(reloaded)
	check(db.writes==writes,"existing setup projection never writes")
	local pending=submit(reloaded,binding,reserve_request(binding,"setup-read",1,view.config_revision,"ordinary")).result.attempt
	db.now+=31
	local before=db.image();writes=db.writes
	setup_view(reloaded)
	check(db.writes==writes,"catalog read never expires an overdue ordinary admission")
	same(db.image(),before,"catalog read preserves overdue launch evidence exactly")
	check(reloaded.execution_job(binding,pending.id).stage=="admitted","overdue ticket waits for its normal mutating path")
end

sections.setup_migration=function()
	for _,roster in ipairs({{},{record("existing")}}) do
		local db,_,binding=fresh(roster)
		local seed=db.image();seed.authority.version=3;seed.authority.setup=nil;seed.authority.setup_adoption_required=nil
		local legacy_db=boundary(seed);local legacy=modules(legacy_db)
		local view=setup_view(legacy)
		check(view.setup.state=="in_progress" and view.adoption_required==true and view.setup.readiness.state=="not_run","every old store requires explicit adoption, even an empty roster")
		same(legacy_db.image(),seed,"read-only old-store projection never persists its migration")
		assert(legacy.open("host-A",4,nil,binding.session_key))
		local saved=legacy_db.peek("authority")
		check(saved.version==4 and saved.setup.state=="in_progress" and saved.setup_adoption_required,"existing authority writer persists explicit setup migration")
		same(saved.config,seed.authority.config,"setup migration preserves every approved record")
		check(saved.namespace==seed.authority.namespace and saved.config_revision==seed.authority.config_revision,"migration does not rotate namespace or configuration approval")
		setup_write(legacy,"dismiss")
		check(legacy_db.peek("authority").setup_adoption_required==true,"dismissal does not silently approve existing setup")
	end
	local original={schema=1,agents={record("legacy")}}
	local legacy_db=boundary({config=original});local legacy=modules(legacy_db)
	refused_unchanged(legacy_db,function()return legacy.setup_snapshot("host-A")end,"legacy config-only store requests source review rather than empty first-use")
	local binding=assert(legacy.open("host-A",4))
	local view=snapshot(legacy,binding)
	check(view.setup.state=="in_progress" and view.adoption_required and not view.ready,"legacy config review and setup adoption remain distinct")
	refused_unchanged(legacy_db,function()return legacy.setup_edit("host-A",view.config_revision,"begin",{})end,"setup writer cannot bypass source review")
	edit(legacy,binding,"review-choice",{id="legacy",source=1});edit(legacy,binding,"review-confirm",{})
	check(setup_view(legacy).setup.state=="in_progress" and setup_view(legacy).adoption_required,"source review alone never completes setup")
end

sections.setup_commit=function()
	local db=boundary();local authority,_,_,load=modules(db)
	setup_write(authority,"begin")
	local data=setup_evidence(load,setup_record("managed"))
	local before=copy(data)
	for _,mutate in ipairs({
		function(d)d.verified=false end,
		function(d)d.attested=true end,
		function(d)d.probe.passed=false end,
		function(d)d.probe.observations={} end,
		function(d)d.probe.observations[1].state="unavailable" end,
		function(d)d.probe.observations[1].state="failed" end,
		function(d)d.probe.observations[2]=nil end,
		function(d)d.probe.observations[2].state="failed" end,
		function(d)d.probe.observations[2].state="unavailable" end,
		function(d)d.probe.observations[2].id="unrelated-route" end,
		function(d)d.probe.record_sha256=string.rep("0",64) end,
		function(d)d.probe.worker_identity="different-user" end,
		function(d)d.probe.bundle_digest="not-a-digest" end,
		function(d)d.probe.unexpected=true end,
		function(d)d.record.command="changed-after-probe" end,
	}) do
		local changed=copy(data);mutate(changed)
		refused_unchanged(db,function()return authority.setup_edit("host-A",1,"commit",changed)end,"missing, failed or mismatched machine-observed managed setup")
	end
	for index=1,#data.probe.observations do
		local incomplete=copy(data);table.remove(incomplete.probe.observations,index)
		refused_unchanged(db,function()return authority.setup_edit("host-A",1,"commit",incomplete)end,"every required machine observation is necessary before setup completion")
	end
	db.fail_after(1)
	refused_unchanged(db,function()return authority.setup_edit("host-A",1,"commit",data)end,"failed commit preserves both roster and lifecycle")
	db.fail_authority_at=nil
	local writes=db.authority_writes
	setup_write(authority,"commit",data)
	local view=setup_view(authority)
	check(db.authority_writes==writes+1 and view.setup.state=="completed" and #view.records==1,"record verification and completion persist in one atomic authority write")
	check(view.records[1].mailbox.verified==true and view.records[1].mailbox.evidence_ref=="setup:"..data.probe.bundle_digest..":fixture-provision","only complete machine-observed evidence sets mailbox verification")
	check(view.setup.readiness.state=="not_run","required setup completes without optional provider-backed readiness")
	same(data,before,"writer never rewrites caller probe or record")
	check(next(db.peek("authority").sessions)==nil,"commit does not allocate an ordinary session or launch")
	refused_unchanged(db,function()return authority.setup_edit("host-A",1,"commit",data)end,"delayed duplicate commit cannot replay under old revision")
	for _,operation in ipairs({"begin","dismiss"}) do
		refused_unchanged(db,function()return authority.setup_edit("host-A",view.config_revision,operation,{})end,"completed setup cannot be reopened by "..operation)
	end
	local reload=modules(db)
	check(setup_view(reload).setup.state=="completed","completion survives reload without record inference")

	local existing_db,_,binding=fresh({record("unrelated"),setup_record("managed")})
	local seed=existing_db.image();seed.authority.version=3;seed.authority.setup=nil;seed.authority.setup_adoption_required=nil
	local adopt_db=boundary(seed);local adopt,_,_,adopt_load=modules(adopt_db)
	assert(adopt.open("host-A",4,nil,binding.session_key))
	local adoption=setup_evidence(adopt_load,setup_record("managed"))
	refused_unchanged(adopt_db,function()return adopt.setup_edit("host-A",1,"commit",adoption)end,"old store cannot bypass explicit adoption with commit")
	refused_unchanged(adopt_db,function()return adopt.setup_edit("host-A",1,"adopt",{})end,"adoption never infers verification from saved records")
	local wrong=setup_evidence(adopt_load,setup_record("missing"))
	refused_unchanged(adopt_db,function()return adopt.setup_edit("host-A",1,"adopt",wrong)end,"adoption must identify an existing record")
	local unexecuted=copy(adoption);unexecuted.probe.observations[2]=nil
	refused_unchanged(adopt_db,function()return adopt.setup_edit("host-A",1,"adopt",unexecuted)end,"adoption requires actual native route execution evidence")
	setup_write(adopt,"adopt",adoption)
	view=setup_view(adopt)
	check(view.setup.state=="adopted_existing" and view.adoption_required==nil and #view.records==2,"machine-observed adoption preserves unrelated accounts")
	same(view.records[1],record("unrelated"),"adoption never replaces unrelated ordinary records")
	local added_db=boundary(seed);local added,_,_,added_load=modules(added_db)
	assert(added.open("host-A",4,nil,binding.session_key))
	local retained=copy(added_db.peek("authority").config)
	setup_write(added,"commit",setup_evidence(added_load,setup_record("new-managed")))
	local added_view=setup_view(added)
	check(added_view.setup.state=="completed" and added_view.adoption_required==nil and #added_view.records==3,"a verified new route completes setup without pretending old records were adopted")
	local preserved=copy(added_db.peek("authority").config);table.remove(preserved.hosts["host-A"].agents,3)
	same(preserved,retained,"creating a separate managed route leaves every existing record and host exactly unchanged")
	local empty_db,_,empty_binding=fresh()
	local empty_seed=empty_db.image();empty_seed.authority.version=3;empty_seed.authority.setup=nil;empty_seed.authority.setup_adoption_required=nil
	local empty_store=boundary(empty_seed);local empty_adopt,_,_,empty_load=modules(empty_store)
	assert(empty_adopt.open("host-A",4,nil,empty_binding.session_key))
	setup_write(empty_adopt,"adopt",setup_evidence(empty_load,setup_record("first-reviewed")))
	check(setup_view(empty_adopt).setup.state=="adopted_existing" and #setup_view(empty_adopt).records==1,"explicit review of an old empty store can add its first probed record")
end

sections.setup_readiness=function()
	local db=boundary();local authority,_,_,load=modules(db)
	setup_write(authority,"begin")
	refused_unchanged(db,function()return authority.setup_edit("host-A",1,"readiness",{state="passed",summary="fixture"})end,"optional readiness cannot complete required setup")
	setup_write(authority,"commit",setup_evidence(load,setup_record("managed")))
	setup_write(authority,"readiness",{state="unavailable",summary="Provider exercise declined"})
	local view=setup_view(authority)
	check(view.setup.state=="completed" and view.setup.readiness.state=="unavailable","declining optional exercise leaves required setup completed")
	for _,state in ipairs({"passed","failed","not_run"}) do
		setup_write(authority,"readiness",{state=state,summary="Deterministic fixture"})
		view=setup_view(authority)
		check(view.setup.readiness.config_revision==view.config_revision and view.setup.state=="completed","readiness is separately revision stamped without changing completion")
	end
	setup_write(authority,"readiness",{state="passed",summary="Deterministic fixture"})
	local prior=setup_view(authority).setup.readiness
	local binding=assert(authority.open("host-A",4))
	edit(authority,binding,"replace-records",{records={record("manual")}})
	view=snapshot(authority,binding)
	check(view.setup.state=="completed" and view.setup.config_revision==view.config_revision and prior.config_revision<view.config_revision,"manual edit makes readiness visibly stale without reopening setup")
	same(view.setup.readiness,prior,"manual edit preserves exact previous exercise outcome")
	local reload=modules(db)
	same(setup_view(reload).setup,view.setup,"stale readiness and completion survive reload")
	for _,data in ipairs({{state="unknown",summary=""},{state="passed",summary=string.rep("x",1025)},{state="passed",summary="bad\nsummary"},{state="passed",summary="",config_revision=0}}) do
		refused_unchanged(db,function()return authority.setup_edit("host-A",view.config_revision,"readiness",data)end,"malformed readiness cannot overwrite saved exercise")
	end
end

sections.setup_invalid=function()
	local db,_,binding=fresh()
	local image=db.image()
	for _,mutate in ipairs({
		function(seed)seed.authority=nil end,
		function(seed)seed.authority.setup=nil end,
		function(seed)seed.authority.setup.state="ready" end,
		function(seed)seed.authority.setup.schema=2 end,
		function(seed)seed.authority.setup.config_revision=1 end,
		function(seed)seed.authority.setup.readiness.config_revision=1 end,
		function(seed)seed.authority.setup.readiness.state="unknown" end,
		function(seed)seed.authority.setup.readiness.summary=false end,
		function(seed)seed.authority.setup.extra=true end,
		function(seed)seed.authority.setup_adoption_required=true end,
		function(seed)seed["authority-initialized"]="wrong-namespace" end,
	}) do
		local seed=copy(image);mutate(seed)
		local bad_db=boundary(seed);local bad=modules(bad_db)
		refused_unchanged(bad_db,function()return bad.setup_snapshot("host-A")end,"lost or corrupt authority never looks not-started")
		refused_unchanged(bad_db,function()return bad.setup_edit("host-A",0,"begin",{})end,"setup writer preserves lost or corrupt authority")
		refused_unchanged(bad_db,function()return bad.snapshot(binding)end,"ordinary snapshot also rejects lost or corrupt setup")
	end
	for _,key in ipairs({"authority","authority-initialized","config","dispatch-v1"}) do
		local failed_db=boundary();failed_db.fail_get=key;local failed=modules(failed_db)
		refused_unchanged(failed_db,function()return failed.setup_snapshot("host-A")end,"unreadable "..key.." never looks absent")
	end
	local lost=copy(image);lost.authority=nil
	local lost_db=boundary(lost);local lost_authority=modules(lost_db)
	refused_unchanged(lost_db,function()return lost_authority.open("host-A",4)end,"ordinary fresh open cannot reset a lost initialized authority")
	local fresh_db=boundary();fresh_db.fail_after(1);local interrupted=modules(fresh_db)
	check(not interrupted.setup_edit("host-A",0,"begin",{}),"interrupted first authority save fails visibly")
	check(fresh_db.peek("authority")==nil and fresh_db.peek("authority-initialized")~=nil,"interrupted creation retains loss fence rather than pretending absent")
	refused_unchanged(fresh_db,function()return interrupted.setup_snapshot("host-A")end,"interrupted initialization cannot silently restart")
	local denied_db=boundary();denied_db.fail_set="authority-initialized";local denied=modules(denied_db)
	refused_unchanged(denied_db,function()return denied.setup_edit("host-A",0,"begin",{})end,"initialization marker must persist before the first authority save")
end
-- The native cleanup owner is injected evidence, not an executed process here.
local function setup_route(backend,revision,nonce,binding)
	local route={schema=1,nonce=nonce,window_consent="window-consent-"..nonce,config_revision=revision,window="",native_namespace="desktop-odin",native_session=4,source_pane=9,native_conn=7,native_since=1700000000,
		backend=backend,command="fixture-only "..nonce,cwd="/fixture/work",record_sha256=string.rep("b",64),
		record_id="managed",
		worker_identity="fixture-worker",host_os="linux",status="running",authority_id=binding.authority_id,
		origin_epoch=if backend=="native-agent" then "fixture-boot:42:12345" else nil}
	if backend=="native-agent" then
		route.prompt="Deterministic diagnostic fixture\nNot actual native execution"
		route.expected_arguments={"--session-dir","/fixture/"..nonce.."-native",""}
	else
		route.output="/fixture/"..nonce..".observation"
		route.expected=nonce.."\nfixture-worker\n"
	end
	return route
end

sections.setup_probe=function()
	local absent_db=boundary();local absent=modules(absent_db)
	local none,why=absent.setup_probe_read("host-A")
	check(none==nil and why==nil and absent_db.writes==0,"genuinely absent probe read creates no authority or cleanup journal")
	for _,backend in ipairs({"native-agent","local-terminal"}) do
		local db,authority,binding,_,_,load=fresh({record("preserved")})
		setup_write(authority,"begin")
		local revision=setup_view(authority).config_revision
		local route=setup_route(backend,revision,"fixture-route",binding)
		local baseline=db.image()
		none,why=authority.setup_probe_read("host-A")
		check(none==nil and why==nil,"existing store without probe has no cleanup obligation")
		same(db.image(),baseline,"reading an absent optional obligation never rewrites the store")
		refused_unchanged(db,function()return authority.setup_probe_claim("host-A",revision-1,route)end,"stale probe claimant")
		refused_unchanged(db,function()return authority.setup_probe_claim("other-host",revision,route)end,"probe claimant from another host")
		local foreign_session=copy(route);foreign_session.native_session=5
		refused_unchanged(db,function()return authority.setup_probe_claim("host-A",revision,foreign_session)end,"diagnostic origin must match a current native session authority")
		db.fail_after(1)
		refused_unchanged(db,function()return authority.setup_probe_claim("host-A",revision,route)end,"failed atomic claim grants no execution obligation")
		db.fail_authority_at=nil
		local writes=db.authority_writes
		check(authority.setup_probe_claim("host-A",revision,route),"host reserves a single persisted cleanup obligation")
		check(db.authority_writes==writes+1,"claim commits in one existing authority write")
		local expected=copy(baseline);expected.authority.setup_probe=copy(route)
		same(db.image(),expected,"claim preserves full records, lifecycle, revisions and unrelated state")
		check(setup_view(authority).setup_probe==nil and snapshot(authority,binding).setup_probe==nil,"private native command and prompt never enter public setup snapshots")
		local reload=modules(db)
		local retained=assert(reload.setup_probe_read("host-A"))
		same(retained,route,"full cleanup identity survives VM reload before native pane binding")
		retained.command="mutated projection"
		same(reload.setup_probe_read("host-A"),route,"cleanup reads do not expose mutable durable aliases")
		local another=setup_route(backend,revision,"another-window",binding)
		another.native_conn=route.native_conn+1;another.native_since=route.native_since+1
		for _,candidate in ipairs({route,another}) do
			refused_unchanged(db,function()return reload.setup_probe_claim("host-A",revision,candidate)end,"another or repeated claimant cannot replay an unfinished diagnostic")
		end
		local commit=setup_evidence(load,setup_record("managed"))
		refused_unchanged(db,function()return reload.setup_edit("host-A",revision,"commit",commit)end,"completion waits for verified native cleanup")
		refused_unchanged(db,function()return reload.setup_probe_bind("host-A","wrong-nonce",41)end,"wrong nonce cannot bind another diagnostic")
		refused_unchanged(db,function()return reload.setup_probe_bind("host-A",route.nonce,0)end,"native pane binding must be positive")
		db.fail_after(1)
		refused_unchanged(db,function()return reload.setup_probe_bind("host-A",route.nonce,41)end,"failed atomic pane binding preserves the unbound obligation")
		db.fail_authority_at=nil
		check(reload.setup_probe_bind("host-A",route.nonce,41),"host binds observed native pane once")
		expected.authority.setup_probe.pane=41
		same(db.image(),expected,"pane binding changes only the unfinished probe")
		writes=db.writes
		check(reload.setup_probe_bind("host-A",route.nonce,41) and db.writes==writes,"identical pane binding is read-only reconciliation")
		refused_unchanged(db,function()return reload.setup_probe_bind("host-A",route.nonce,42)end,"probe pane identity cannot be replaced")
		refused_unchanged(db,function()return reload.setup_probe_bind("host-A",route.nonce,41,0)end,"desktop pane binding must be positive")
		check(reload.setup_probe_bind("host-A",route.nonce,41,941),"desktop SDK pane attaches to independently discovered native pane")
		expected.authority.setup_probe.window_pane=941
		same(db.image(),expected,"desktop association preserves the distinct native pane identity")
		writes=db.writes
		check(reload.setup_probe_bind("host-A",route.nonce,41,941) and db.writes==writes,"identical host and desktop association is read-only")
		check(reload.setup_probe_bind("host-A",route.nonce,41) and db.writes==writes,"native-only reconciliation preserves an existing desktop association")
		refused_unchanged(db,function()return reload.setup_probe_bind("host-A",route.nonce,41,942)end,"desktop pane cannot be rebound")
		refused_unchanged(db,function()return reload.setup_probe_bind("host-A",route.nonce,42,941)end,"desktop echo cannot replace the native pane")
		local cold=modules(db)
		check(cold.setup_probe_read("host-A").pane==41 and cold.setup_probe_read("host-A").window_pane==941,"both identity domains survive another VM reload")
		local original_authority=binding.authority_id
		edit(cold,binding,"reset-transport",{})
		check(binding.authority_id~=original_authority and cold.setup_probe_read("host-A").authority_id==original_authority,"transport rotation preserves original incarnation solely for cleanup")
		edit(cold,binding,"replace-records",{records={record("manual-change")}})
		local after_edit=db.image()
		check(after_edit.authority.setup_probe.config_revision==revision and after_edit.authority.config_revision>revision,"manual edit preserves old cleanup obligation without granting renewed execution")
		refused_unchanged(db,function()return cold.setup_probe_clear("host-A","wrong-nonce")end,"wrong nonce cannot clear native cleanup")
		db.fail_after(1)
		refused_unchanged(db,function()return cold.setup_probe_clear("host-A",route.nonce)end,"failed atomic cleanup retains the obligation")
		db.fail_authority_at=nil
		check(cold.setup_probe_clear("host-A",route.nonce),"verified cleanup owner clears its exact obligation")
		after_edit.authority.setup_probe=nil
		same(db.image(),after_edit,"cleanup changes neither newer records nor configuration or lifecycle revisions")
		refused_unchanged(db,function()return cold.setup_probe_clear("host-A",route.nonce)end,"consumed cleanup nonce cannot clear an absent obligation")
		local current=setup_view(cold).config_revision
		local successor=setup_route(backend,current,"successor-route",binding)
		check(cold.setup_probe_claim("host-A",current,successor),"a fresh diagnostic is claimable only after prior cleanup")
		refused_unchanged(db,function()return cold.setup_probe_clear("host-A",route.nonce)end,"old cleanup cannot clear a successor obligation")
		check(cold.setup_probe_clear("host-A",successor.nonce),"successor cleanup can finish independently")
		local retired=copy(successor);retired.authority_id=original_authority
		refused_unchanged(db,function()return cold.setup_probe_claim("host-A",current,retired)end,"retired authority incarnation cannot claim another diagnostic")
	end
	for _,kind in ipairs({"ordinary","managed","uncertain"}) do
		local db,authority,binding,_,_,load=fresh({record("managed"),record("other")})
		setup_write(authority,"begin")
		local revision=setup_view(authority).config_revision
		local second=assert(authority.open("host-A",5))
		if kind=="ordinary" then
			check(submit(authority,second,reserve_request(second,"second-window",1,revision,"managed")).ok,"another native session reserves ordinary work")
		else
			local attempt=assert(authority.managed_reserve(second,revision,"managed","second-session-worker"))
			if kind=="uncertain" then check(authority.managed_observe(second,attempt.id,attempt.observer_id,{phase="Unknown"}),"other-session managed outcome is uncertain") end
		end
		local before=db.image()
		check(not authority.record_preparation_available("host-A","managed"),"host-wide preparation detects "..kind.." work outside the visible Config scope")
		same(db.image(),before,"host-wide preparation inspection performs no writes")
		local route=setup_route("local-terminal",revision,"busy-"..kind,binding)
		refused_unchanged(db,function()return authority.setup_probe_claim("host-A",revision,route)end,"busy other-session record cannot acquire paid/offline diagnostic authority")
		local evidence=setup_evidence(load,setup_record("managed"))
		refused_unchanged(db,function()return authority.setup_edit("host-A",revision,"adopt",evidence)end,"normal save/adoption rechecks host-wide busy state")
	end
	do
		local db,authority,binding=fresh({record("managed"),record("other")})
		setup_write(authority,"begin")
		local revision=setup_view(authority).config_revision
		local second=assert(authority.open("host-A",5))
		local route=setup_route("local-terminal",revision,"exclusive-preparation",binding)
		check(authority.setup_probe_claim("host-A",revision,route),"diagnostic claims exact record ownership")
		check(not submit(authority,second,reserve_request(second,"blocked-window",1,revision,"managed")).ok,"probe ownership blocks a new ordinary launch in another session")
		check(not authority.managed_reserve(second,revision,"managed","blocked-managed"),"probe ownership blocks another session's managed reservation")
		check(submit(authority,second,reserve_request(second,"unrelated-window",1,revision,"other")).ok,"record-scoped preparation does not block unrelated launches")
	end
	for _,field in ipairs({"enabled","review_required"}) do
		local configured=record("managed")
		configured[field]=field~="enabled"
		if field=="review_required" then configured.review_reason="Review this saved command" end
		local db,authority,binding=fresh({configured})
		setup_write(authority,"begin")
		local revision=setup_view(authority).config_revision
		check(not authority.record_preparation_available("host-A","managed"),"disabled or review-gated account is refused before preparation: "..field)
		refused_unchanged(db,function()return authority.setup_probe_claim("host-A",revision,setup_route("native-agent",revision,"prerequisite-"..field,binding))end,"account prerequisite cannot be bypassed at diagnostic claim")
	end
	do
		local db,authority,_,_,_,load=fresh()
		setup_write(authority,"begin")
		local value=setup_record("managed");local proof=setup_evidence(load,value).probe
		local revision=setup_view(authority).config_revision;local before=db.image()
		check(authority.setup_capacity_available("host-A",revision,value,proof),"normal prepared record fits unchanged final-save bounds before diagnostic cost")
		same(db.image(),before,"capacity preflight publishes no readiness, receipt acknowledgment or store write")
		check(value.mailbox.verified==false,"size-only projection does not mutate the real unverified record")
		local large=copy(value);large.prompt=string.rep("x",120000);local largeProof=setup_evidence(load,large).probe
		check(not authority.setup_capacity_available("host-A",revision,large,largeProof),"final roster budget refusal occurs before native/model diagnostic")
		same(db.image(),before,"capacity refusal preserves all retained replies, records and evidence")
	end
	for _,missing in ipairs({"native_namespace","window_consent"}) do
		local legacy_db,_,legacy_binding=fresh()
		local legacy=setup_route("local-terminal",0,"legacy-route",legacy_binding);legacy[missing]=nil
		local legacy_image=legacy_db.image();legacy_image.authority.setup_probe=legacy
		local retained_db=boundary(legacy_image);local retained_authority=modules(retained_db)
		local retained_probe=retained_authority.setup_probe_read("host-A")
		check(retained_probe~=nil and retained_probe.nonce==legacy.nonce and retained_probe[missing]==nil,"legacy obligation remains visible without inventing "..missing)
		same(retained_db.image(),legacy_image,"legacy obligation is retained verbatim rather than reset")
		refused_unchanged(retained_db,function()return retained_authority.setup_probe_claim("host-A",0,setup_route("local-terminal",0,"replacement",legacy_binding))end,"legacy cleanup obligation blocks a fresh launch")
		local missing_claim=setup_route("local-terminal",0,"missing-claim",legacy_binding);missing_claim[missing]=nil
		refused_unchanged(legacy_db,function()return modules(legacy_db).setup_probe_claim("host-A",0,missing_claim)end,"new claim requires "..missing)
	end
	local db,authority,binding=fresh()
	local route=setup_route("native-agent",0,"fixture-invalid",binding)
	for _,mutate in ipairs({
		function(value)value.schema=2 end,
		function(value)value.unknown=true end,
		function(value)value.nonce="" end,
		function(value)value.authority_id=nil end,
		function(value)value.authority_id="foreign:1" end,
		function(value)value.origin_epoch=string.rep("x",257) end,
		function(value)value.origin_epoch="invalid\nepoch" end,
		function(value)value.native_namespace=false end,
		function(value)value.native_namespace="" end,
		function(value)value.window_consent=false end,
		function(value)value.window_consent="" end,
		function(value)value.native_conn=nil end,
		function(value)value.native_since=nil end,
		function(value)value.native_conn="7" end,
		function(value)value.native_since="1700000000" end,
		function(value)value.native_conn={7,8} end,
		function(value)value.native_since=false end,
		function(value)value.native_conn=-1 end,
		function(value)value.native_since=-1 end,
		function(value)value.native_conn=1.5 end,
		function(value)value.native_since=1.5 end,
		function(value)value.native_conn=9007199254740992 end,
		function(value)value.native_since=math.huge end,
		function(value)value.native_session=-1 end,
		function(value)value.source_pane=0 end,
		function(value)value.window=false end,
		function(value)value.config_revision=1 end,
		function(value)value.command="bad\0command" end,
		function(value)value.status="passed" end,
		function(value)value.backend="ssh-command" end,
		function(value)value.expected_arguments[2]=nil end,
		function(value)value.prompt=nil end,
		function(value)value.output="/unexpected-terminal-output" end,
	}) do
		local invalid=copy(route);mutate(invalid)
		refused_unchanged(db,function()return authority.setup_probe_claim("host-A",0,invalid)end,"invalid initial native obligation")
		local image=db.image();image.authority.setup_probe=invalid
		local corrupt_db=boundary(image);local corrupt=modules(corrupt_db)
		refused_unchanged(corrupt_db,function()return corrupt.setup_probe_read("host-A")end,"corrupt saved diagnostic never disappears on reload")
		refused_unchanged(corrupt_db,function()return corrupt.setup_probe_clear("host-A",route.nonce)end,"corrupt saved diagnostic requires explicit recovery, never blind deletion")
	end
	local image=db.image();image.authority=nil
	local lost_db=boundary(image);local lost=modules(lost_db)
	refused_unchanged(lost_db,function()return lost.setup_probe_read("host-A")end,"lost initialized authority never means no unfinished diagnostic")
end

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
	local view=snapshot(authority,binding)
	local original=copy(view.records)
	local family=assert(authority.managed_declare_provider_families(binding,view.config_revision,{{record_id="imported",provider_family="claude"}}))
	check(family.applied==1 and family.config_revision==view.config_revision+1 and #family.families==1 and family.families[1].record_id=="imported" and family.families[1].provider_family=="anthropic","the writer durably fills an absent declaration and returns its canonical family for the exact requested record")
	local saved=snapshot(authority,binding)
	check(saved.records[1].provider_family=="anthropic" and saved.records[1].command==original[1].command,"declaration preserves owner-edited executable configuration")
	local unchanged=db.image()
	local repeated=assert(authority.managed_declare_provider_families(binding,saved.config_revision,{{record_id="imported",provider_family="anthropic"}}))
	check(repeated.applied==0 and #repeated.families==1 and repeated.families[1].provider_family=="anthropic","identical declarations return the actual saved canonical family without a write")
	same(db.image(),unchanged,"identical declarations preserve authority and history")
	refused_unchanged(db,function()return authority.managed_declare_provider_families(binding,saved.config_revision,{{record_id="second",provider_family="google"},{record_id="imported",provider_family="openai"}})end,"a conflicting declaration refuses the entire batch without partial metadata writes")
	refused_unchanged(db,function()return authority.managed_declare_provider_families(binding,view.config_revision,{{record_id="second",provider_family="google"}})end,"stale family writes cannot overwrite a newer roster")
	local _,known,kb=fresh({record("known",{provider="Codex"})})
	local migrated=assert(known.managed_declare_provider_families(kb,snapshot(known,kb).config_revision,{{record_id="known",provider_family="muse"}}))
	check(migrated.families[1].provider_family=="meta" and snapshot(known,kb).records[1].provider_family=="meta","an old explicit wrapper override does not conflict with an invented saved default")
end

local function managed_fixture()
	local db,authority,binding,_,_,load=fresh({record("managed")})
	local P,Codec=load("bridge_protocol"),load("wire/codec")
	local origin={logical_session_id="logical",owner_id="owner",owner_generation=1,host_pane_id="12",alias_nonce="alias",window_key="",window_epoch="epoch",native_session_id="4",window_host_id="7"}
	local r={schema=2,origin="orchplus",op="launch",request_id="launch",action_id="action-launch",controller_pane="44",controller_generation=1,origin_binding=origin,
		authority_namespace="orch-fixture",logical_session_id="logical",admission_seq=1,request_serial=1,next_request_serial=11,settled_before=1,consumed={9},
		record_id="managed",record_revision=1,work_id="work",prompt="assignment",cwd="/work",placement="tab",fresh=true,mailbox_handle="mailbox",
		enrolment={worker_id="worker",worker_generation=1,enrolment_token="aaaaaaaaaaaaaaaa",assignment_sha256=Codec.sha256("assignment")}}
	check(P.decode(runtime.json.encode(r))~=nil,"fixture uses canonical issued identity")
	local observer="managed-"..Codec.sha256("logical/launch")
	local a=assert(authority.managed_reserve(binding,1,"managed",observer))
	check(authority.managed_observe(binding,a.id,observer,{phase="Starting",pane=55}),"fixture records exact native observation")
	local registry={version=2,revision=0,namespace="dispatch-fixture",next_id=1,authority_namespace=r.authority_namespace,admission_cursor=1,
		sessions={logical={admission_seq=1,authority=binding.managed_authority_id,host_session=4,controller_pane="44",
			control={phase="open",binding=copy(origin),generation_floor=0,request_floor=1,next_request_serial=11,last_authority_revision=0}}},
		workers={},mailboxes=load("mailbox").empty(),gates={},requests={},controls={}}
	registry.workers["logical/launch"]={kind="launch",logical_session_id="logical",worker_id="worker",worker_generation=1,launch_request_id="launch",launch_action_id="action-launch",
		work_id="work",enrolment_token=r.enrolment.enrolment_token,assignment_sha256=r.enrolment.assignment_sha256,mailbox_handle="mailbox",record_id="managed",record_revision=1,
		origin_binding=copy(origin),controller_pane="44",controller_generation=1,phase="awaiting_acceptance",backend="local-terminal",binding=copy(binding),
		observer_id=observer,attempt_id=a.id,mailbox_live=false,pane_binding={pane_id="55",window_epoch="epoch",window_key="",native_session_id="4",window_host_id="7"}}
	P.observe(registry)
	check(load("dispatch_state").validate_registry(registry)~=nil,"fixture bridge evidence validates without side effects")
	db.kv.set("dispatch-v1",registry);db.kv.set("dispatch-v1-initialized",registry.namespace)
	return db,authority,binding,a,registry,r
end

sections.managed_unbound_mailbox_retention=function()
	for _,status in ipairs({"provisioned","uncertain"}) do
		for _,launch_status in ipairs({"absent","rejected"}) do
			local db,authority,binding,a,registry,issued=managed_fixture()
			local _,_,_,load=modules(db)
			local P,Mailbox=load("bridge_protocol"),load("mailbox")
			P.observe(registry)
			local launch=copy(issued);launch.request_serial=2
			launch.request_id="unbound";launch.action_id="action-unbound"
			launch.mailbox_handle="unbound-mailbox"
			if launch_status=="rejected" then
				registry.requests["logical/unbound"]={request=launch,request_json=runtime.json.encode(launch),body=P.reject(launch,"stale_revision","Record changed before launch")}
			end
			local provision={schema=2,origin="orchplus",op="mailbox_provision",request_id="provision",action_id="action-provision",
				authority_namespace=issued.authority_namespace,admission_seq=1,request_serial=3,next_request_serial=11,settled_before=1,consumed={9},
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
			local outcome
			registry.mailboxes,outcome=Mailbox.settle(intent,operation,{status=status})
			registry.requests["logical/provision"]={request=provision,request_json=runtime.json.encode(provision),body=P.body(provision,outcome.status,outcome.payload)}
			registry.workers={}
			check(load("dispatch_state").validate_registry(registry)~=nil,"unbound mailbox registry remains valid")
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
	local db,authority,binding,a,registry,r=managed_fixture()
	local _,_,_,load=modules(db);local P,Codec=load("bridge_protocol"),load("wire/codec")
	P.observe(registry)
	local retirement={schema=2,origin="orchplus",op="mailbox_retire",request_id="retire",action_id="action-retire",origin_binding=copy(r.origin_binding),
		authority_namespace=r.authority_namespace,admission_seq=1,request_serial=2,next_request_serial=11,settled_before=1,consumed={9},
		controller_pane=r.controller_pane,controller_generation=r.controller_generation,logical_session_id="logical",worker_id="worker",worker_generation=1,
		launch_request_id="launch",work_id="work",enrolment_token=r.enrolment.enrolment_token,handle="mailbox",expected_generation=1,mode="retire",
		settlement_revision=1,report_floor=1,report_chain_sha256=Codec.sha256("settled"),reply_floor=0,grant_id="retirement-grant"}
	check(P.decode(runtime.json.encode(retirement))~=nil,"interrupted settlement uses a valid exact retirement request")
	local pending={request=retirement,request_json=runtime.json.encode(retirement),body=P.body(retirement,"pending"),retirement_result=P.body(retirement,"retired")}
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
	registry.requests={};registry.workers={};registry.sessions={}
	db.kv.set("dispatch-v1",registry)
	local other=assert(authority.open("host-A",8))
	local fences=db.peek("dispatch-v1")
	local result=assert(forget(authority,other,{[8]=true}))
	check(result.sessions==1 and db.peek("authority").sessions[binding.session_key]==nil,"delivery ACK and current worker/session removal release settled authority scope")
	same(db.peek("dispatch-v1"),fences,"forgetting settled ledger never rewrites peer authority")
end

sections.managed_maintenance=function()
	local db,authority,binding,a,registry=managed_fixture()
	check(authority.managed_retire(binding,a.id,a.observer_id,"managed",55),"settled managed ledger alone does not clear controller")
	refused_unchanged(db,function()return authority.edit(binding,1,"reset-transport",{})end,"controller reference prevents reset after settlement")
	local other=assert(authority.open("host-A",8))
	check(forget(authority,other,{[8]=true}).kept==1,"owner and launch references protect absent session")
	registry.sessions.logical.control.binding=nil;registry.sessions.logical.control.generation_floor=1
	db.kv.set("dispatch-v1",registry)
	refused_unchanged(db,function()return authority.edit(binding,1,"reset-transport",{})end,"fenced current session and worker preserve native authority without completed launch request")
	local admit=admitter(authority,binding,"ordinary-history")
	local failed,exited=admit("managed"),admit("managed")
	update(authority,binding,failed,"admitted",{stage="failed"},{phase="Failed"})
	run_job(authority,binding,exited,88)
	update(authority,binding,exited,"running",{stage="completed"},{phase="Exited"})
	local attempts=by_id(snapshot(authority,binding))
	check(attempts[a.id]~=nil and attempts[failed].phase=="Failed" and attempts[exited].phase=="Exited","current worker reference preserves reservation without deleting ordinary Failed/Exited history")
	check(next(db.peek("dispatch-v1").requests)==nil,"worker authority retention requires no completed launch request")
	db.kv.set("dispatch-v1",nil)
	refused_unchanged(db,function()return authority.edit(binding,1,"reset-transport",{})end,"missing initialized bridge never permits reset")
	refused_unchanged(db,function()return forget(authority,other,{[8]=true})end,"missing bridge never permits forgetting")
end

sections.managed_migration=function()
	local db,_,binding,a=managed_fixture()
	local image=db.image();local old=image.authority
	old.version=1;old.setup=nil;old.setup_adoption_required=nil
	old.config.hosts["host-A"].agents[1].include_all=true
	local scope=old.sessions[binding.session_key]
	scope.native_session=nil;scope.jobs=nil;scope.managed_authority_id=nil;scope.managed_imports=nil
	scope.inbox={};scope.imports={};scope.launch.attempts[1].purpose=nil
	local restored_db=boundary(image);local restored=modules(restored_db)
	local current=assert(restored.open("host-A",4,nil,binding.session_key))
	local migrated=restored_db.peek("authority")
	check(migrated.version==4 and migrated.namespace==old.namespace and migrated.config_revision==old.config_revision,"exact v1 migration preserves roster and namespace identity")
	local result=migrated.sessions[binding.session_key].launch.attempts[1]
	local expected=copy(scope.launch.attempts[1]);expected.purpose="managed"
	same(result,expected,"migration changes only explicit purpose, never observer/attempt/pane evidence")
	same(restored_db.peek("managed-v1-original"),old,"old managed authority is preserved before conversion")
	check(migrated.config.hosts["host-A"].agents[1].include_all==nil,"v1 roster normalization removes retired bulk policy without refusing the authority")
	same(restored_db.peek("dispatch-v1"),image["dispatch-v1"],"migration never rewrites immutable bridge grants")
	check(#snapshot(restored,current).jobs==0,"migrated managed attempt cannot become an ordinary ticket")
	for _,mutate in ipairs({
		function(seed)seed["dispatch-v1"].workers["logical/launch"].observer_id="managed-not-the-exact-request"end,
		function(seed)seed.authority.sessions[binding.session_key].launch.attempts[1].record_id="ordinary"end,
		function(seed)seed["dispatch-v1"].workers["logical/launch"].pane_binding.pane_id="56"end,
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
		local seed=database.image();seed.authority.version=1;seed.authority.setup=nil;seed.authority.setup_adoption_required=nil
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
	check(empty_db.peek("authority").version==4 and #snapshot(empty,empty_binding).records==0,"clean v1 without any bridge registry migrates without replaying obsolete ordinary setup")
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
	local Dispatch,Codec=load("dispatch"),load("wire/codec")
	check(Dispatch.admin_bootstrap({request_id="migration-fixture-create",orch_session_id="migration-fixture-session",
		owner_id="migration-fixture-owner",generation=1,authority_namespace=snapshot(importer,import_binding).namespace,
		source_nonce="migration-fixture-source"})~=nil,"managed import fixture explicitly creates its native transport before opening an import gate")
	local verified_record=setup_record("imported");verified_record.mailbox.verified=true;verified_record.mailbox.evidence_ref="actual-prior-managed-setup"
	local imported_records=assert(import_config.validate_records({verified_record}))
	local raw_imported_records=copy(imported_records);raw_imported_records[1].include_all=true
	local bytes=runtime.json.encode(raw_imported_records)
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
	reset_seed.authority.sessions[import_binding.session_key].imports["bridge-receipt"][1].include_all=true
	reset_seed["dispatch-v1"].gates[gate_id].records[1].include_all=true
	local reset_db=boundary(reset_seed);local reset_authority=modules(reset_db)
	local migrated_binding=assert(reset_authority.open("host-A",4,nil,import_binding.session_key))
	same(snapshot(reset_authority,migrated_binding).records,imported_records,"receipt migration does not replay imports or restore obsolete ordinary records")
	check(reset_authority.managed_import(migrated_binding,-1,"bridge-receipt",imported_records).replayed,"consumed bridge receipt matches stable host/session after transport rotation")
	same(reset_db.peek("authority").sessions[import_binding.session_key].managed_imports["bridge-receipt"],imported_records,"v1 detached verified receipts canonicalize with consumed gate records without replaying or resetting managed identity")
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
	local stale = request(binding, "importer", 1, old_revision, "import_records", { setup_run_id = "old-setup", records = { record("stale") },manual=true,confirmed=true })
	local reply = submit(authority, binding, stale)
	check(not reply.ok and reply.error == "stale-config", "stale import returns a retained rejection")
	local after = snapshot(authority, binding)
	same(after.records, before.records, "stale import leaves roster exact")
	check(after.config_revision == before.config_revision, "stale import does not advance configuration revision")
	local imported = { record("third", { prompt = "Keep exact prompt.\nNo automatic launch." }) }
	local add = request(binding, "importer", 2, after.config_revision, "import_records", { setup_run_id = "approved-setup", records = imported,manual=true,confirmed=true })
	check(submit(authority, binding, add).result.imported == 1, "review-confirmed import adds the intended record")
	after = snapshot(authority, binding)
	check(#after.attempts == 0, "import does not reserve or execute a launch")
	local replay = request(binding, "importer", 3, after.config_revision, "import_records", add.data)
	local replay_reply = submit(authority, binding, replay)
	check(replay_reply.ok and replay_reply.result.imported == 0, "identical import is idempotent under a new request")
	local conflict = request(binding, "importer", 4, after.config_revision, "import_records", { setup_run_id = "approved-setup", records = { record("third", { command = "different" }) },manual=true,confirmed=true })
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
	local value = request(binding, "large", 1, 1, "import_records", { setup_run_id = "large-setup", records = large,manual=true,confirmed=true })
	refused_unchanged(db, function() return authority.request(binding, value,setup_context(binding)) end, "encoded durable state capacity")
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
	local context=setup_context(binding)
	local setup = request(binding, "window", 1, 1, "start_setup", {setup_run_id="setup-once",command="truthful-default --opaque",cwd=context.inventory.sessions[1].tabs[1].blocks[1].cwd,window=context.window,config_pane=700})
	local reply = submit(authority, binding, setup,context)
	check(reply.ok and reply.result.job.initial_prompt ~= helper.prompt and reply.result.job.backend=="setup-default", "disabled roster does not select or block the native default bootstrap")
	local helper_id = reply.result.attempt.id
	db.now+=31
	check(snapshot(authority,binding).attempts[1].phase=="Failed","unused native setup admission expires before any effect")
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
	local preview,why,captured = authority.forget_sessions(binding, { [6] = true }, false)
	assert(preview,why)
	check(preview.sessions == 1 and preview.attempts == 2 and preview.bytes > 0 and preview.kept == 1, "preview counts ended sessions, attempts, bytes and active absent sessions kept")
	same(db.image(), before, "preview changes nothing")
	local writes = db.authority_writes
	refused_unchanged(db, function() return authority.forget_sessions(binding, { [6] = true }, true) end, "applying without pre-inspection evidence cannot remove history")
	local result = assert(authority.forget_sessions(binding, { [6] = true }, true, captured))
	same(result, preview, "forget reports what it removed")
	check(db.authority_writes == writes + 1, "forget is one atomic persist")
	local sessions = db.peek("authority").sessions
	check(sessions[ended.session_key] == nil, "ended session bucket is removed")
	check(sessions[binding.session_key] ~= nil and sessions[live.session_key] ~= nil, "bound and live sessions are kept")
	check(sessions[running.session_key] ~= nil, "an absent session with a Running attempt is kept")
	check(#runtime.json.encode(before.authority) > #runtime.json.encode(db.peek("authority")), "forgetting frees stored bytes")
	local kept = assert(forget(authority, live, { [4] = true }))
	check(kept.sessions == 0 and db.peek("authority").sessions[live.session_key] ~= nil, "the caller's bound session is never forgotten")
	local changed = assert(authority.open("host-A", 20))
	local _,capture_error,prior = authority.forget_sessions(binding, { [4] = true, [6] = true }, false)
	assert(prior,capture_error)
	local newer = assert(authority.open("host-A", 21))
	check(submit(authority, changed, request(changed, "late", 1, 1)).ok, "captured scope receives a genuine later request")
	local current = db.image()
	local fenced = assert(authority.forget_sessions(binding, { [4] = true, [6] = true }, true, prior))
	check(fenced.sessions == 0, "changed and newly created scopes are not authorized by old inspection candidates")
	same(db.image(), current, "late scope creation and request history survive the stale cleanup capture")
	check(db.peek("authority").sessions[newer.session_key] ~= nil, "new authority was not included retroactively")
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
	local harness = { fail = false,
		clients = { { kind = "window", window = "w", conn = 1, since = 1 } },
		views = { w = { { id = 4, tabs = { { blocks = { { id = pane } } } } } } } }
	local native_cli = { inspect = function(window, _options, callback)
		if harness.fail or harness.fail_window == window then callback({ status = 1, timed_out = false, stdout = "", stderr = "injected inspection failure" }, nil); return end
		local inventory = { sessions = copy(harness.views[window] or {}), clients = copy(harness.clients) }
		if harness.on_inspect then harness.on_inspect(window,inventory) end
		callback({ status = 0, timed_out = false, truncated = harness.truncated, stdout = runtime.json.encode(inventory) }, nil)
	end }
	local fake = setmetatable({
		kv = db.kv, on = function() end, timer = function() end, now = function() return 0 end,
		ui = { text = function(value) return { t = value } end, col = function(children) return children end, node = function() return {} end },
		block = { define = function(name, value) if name=="spawner" then definition = value end end },
	}, { __index = runtime })
	-- Load registration modules against this fixture runtime, including relative
	-- updater dependencies. Transport opening is explicitly unavailable here:
	-- these authority-block tests never create a live channel endpoint.
	local registered = {}
	local function registration(name)
		if registered[name] then return registered[name] end
		if name == "channel/channel" then
			return { open = function(options)
				check(options.plugin_id == "spawn", "real relay requests the SPAWN transport boundary")
				harness.channel_opened = true
				return nil, { code = "fixture_transport_unavailable", operation = "open" }
			end }
		end
		if name == "dispatch" then return { recovery_view = function() return {} end } end
		if name == "authority" then return authority end
		if name == "config" then return config end
		if name == "wire/codec" then return load(name) end
		local source = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
		local directory = name:match("^(.*)/") or ""
		setfenv(source, setmetatable({ tern = fake, require = function(path)
			assert(path:sub(1, 2) == "./", "registration dependency must be relative")
			return registration((if directory == "" then "" else directory .. "/") .. path:sub(3))
		end }, { __index = environment }))
		local result = source()
		registered[name] = result
		return result
	end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/host.luau"), "host"))
	setfenv(chunk, setmetatable({ tern = fake, require = function(name)
		if name == "./config" then return config end
		if name == "./authority" then return authority end
		if name == "./setup_review" then return load("setup_review") end
		if name == "./setup_discovery" then return load("setup_discovery") end
		if name == "./native_cli" then return native_cli end
		if name == "./host_executor" then return { install = function() end, attach = function() end, epoch = function() return nil end } end
		if name == "./dispatch" then return {recovery_view=function()return {}end} end
		if name == "./dispatch_state" then return load("dispatch_state") end
		if name == "./wire/codec" then return load("wire/codec") end
		if name == "./managed_setup" then return load("managed_setup") end
		if name == "./prereq" then return registration("prereq") end
		if name == "./page_navigation" then return load("page_navigation") end
		if name == "./window_journal" then return {host_initialize=function()return "fixture" end,client_inventory=load("window_journal").client_inventory} end
		if name == "./dispatch_relay" then return registration("dispatch_relay") end
		if name == "./updater/host" then return registration("updater/host") end
		error("Unexpected host dependency: " .. name)
	end }, { __index = environment }))
	chunk()
	check(harness.channel_opened == true, "host installs the real pane-free relay through the isolated transport boundary")
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
	local other = assert(authority.open("host:a", 9))
	local id = submit(authority, other, reserve_request(other, "ordinary", 1, 1, "x")).result.attempt.id
	claim(authority, other, id, 91)
	update(authority, other, id, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	update(authority, other, id, "submission_intent", { stage = "completed" }, { phase = "Exited", exit_status = 0 })
	harness.clients[2] = { kind = "window", window = "other", conn = 2, since = 2 }
	harness.views.other = { { id = 9, tabs = {} } }
	local history = db.peek("authority").sessions[other.session_key]
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	same(db.peek("authority").sessions[other.session_key], history, "another live window keeps its exact ordinary Exited history")
	local absent = assert(authority.open("host:a", 10))
	harness.on_inspect = function(window,inventory)
		if window == "other" then inventory.clients[2].since += 1 end
	end
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	check(db.peek("authority").sessions[absent.session_key] ~= nil and state.forget_hold ~= nil, "incarnation drift preserves a cleanup candidate")
	local late
	harness.on_inspect = function(window)
		if window == "other" and not late then late = assert(authority.open("host:a", 11)) end
	end
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	check(db.peek("authority").sessions[absent.session_key] == nil, "unchanged settled absent scope is reclaimed after two complete stable scans")
	check(late and db.peek("authority").sessions[late.session_key] ~= nil, "a scope created during inspection survives the captured deletion set")
	harness.on_inspect = nil
	harness.fail_window = "other"
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	check(db.peek("authority").sessions[late.session_key] ~= nil and state.forget_hold ~= nil, "an unreadable other window cannot prove absence")
	harness.fail_window = nil
	harness.truncated = true
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	check(db.peek("authority").sessions[late.session_key] ~= nil, "a truncated native result cannot authorize cleanup")
	harness.truncated = nil
	local visits = 0
	harness.on_inspect = function(window,inventory)
		if window == "other" then
			visits += 1
			if visits == 2 then inventory.sessions = {} end
		end
	end
	harness.definition.event(state, { ev = "action", act = "refresh" }, harness.cx)
	check(db.peek("authority").sessions[late.session_key] ~= nil and state.forget_hold ~= nil, "session drift between complete rounds preserves history")
	same(db.peek("authority").sessions[other.session_key], history, "all incomplete or changing scans retain the other window's settled ordinary history")
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

-- Without a restart, inventory absence ends submitted work, not a claim whose
-- native pre-submission checks are pending. Native failure and recovery still end it.
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
	local waiting = db.image()
	check(authority.sweep(binding, {}, "daemon:1", db.now + authority.ADMISSION_SECONDS) == 0, "inventory absence alone cannot end a pending claim, even after its old admission deadline")
	same(db.image(), waiting, "a pending claim keeps its native binding, sequence and command absence")
	refused_unchanged(db, function() return authority.claim_execution(binding, starting, native(64)) end, "an absent inventory row does not authorize a second claim")
	update(authority, binding, starting, "claimed", { stage = "unknown" }, { phase = "Unknown", diagnostic = "Execution will not be repeated after reload" })
	check(authority.sweep(binding, {}, nil, db.now) == 1, "a recovered claim with no in-flight submission still settles when its pane is gone")
	attempts, jobs = by_id(snapshot(authority, binding))
	check(attempts[starting].phase == "Exited" and attempts[starting].diagnostic == "Pane closed" and jobs[starting].stage == "resolved", "recovery is not protected as a fresh pending claim")
	for _, a in pairs(attempts) do check(not a.unresolved, a.id .. " is history") end
	local submitted = admit("agent"); claim(authority, binding, submitted, 64)
	update(authority, binding, submitted, "claimed", { stage = "submission_intent", command = "ordinary-cli" })
	check(authority.sweep(binding, {}, nil, db.now) == 1, "a submission intent still in Starting settles from a missing pane")
	attempts, jobs = by_id(snapshot(authority, binding))
	check(attempts[submitted].phase == "Exited" and jobs[submitted].stage == "resolved" and authority.execution_job(binding, submitted).command == "ordinary-cli", "the exception is only for claimed jobs, not every Starting phase")
	refused_unchanged(db, function() return authority.update_execution(binding, submitted, "resolved", { stage = "submission_intent", command = "ordinary-cli" }) end, "a settled submission is never replayable")

	local restarted = admit("agent"); claim(authority, binding, restarted, 65)
	update(authority, binding, restarted, "claimed", { epoch = "daemon:1" })
	check(authority.sweep(binding, {}, "daemon:2", db.now) == 1, "a pending claim still begins normal restart grace")
	local restored = { [65] = { title = "ordinary-cli" } }
	check(authority.sweep(binding, restored, "daemon:2", db.now + authority.RESTART_GRACE_SECONDS) == 1, "restart grace ends a pending claim even when its shell reappears")
	attempts, jobs = by_id(snapshot(authority, binding))
	check(attempts[restarted].phase == "Exited" and attempts[restarted].diagnostic == "Host restarted" and authority.execution_job(binding, restarted).command == nil, "no unsubmitted claim is readopted as a provider")

	-- Real authority + real executor; only native observations, timers and pane
	-- input are injected. This is deterministic boundary coverage, not GUI proof.
	for _, outcome in ipairs({ "submit", "pane_exited", "window_closed", "native_ended", "readiness_failed", "process_failed", "reload" }) do
		local db, authority, binding, _, _, load = fresh({ record("pending") })
		local id = admitter(authority, binding)("pending")
		local ticket = authority.execution_job(binding, id).ticket
		local hooks, timers, writes, sweeps = {}, {}, {}, 0
		local inspection, inspected = nil, false
		local function response(value, callback)
			callback({ status = 0, stdout = runtime.json.encode(value), stderr = "", timed_out = false }, nil)
		end
		local function inventory()
			if outcome == "window_closed" then return { sessions = {} } end
			return { sessions = { { id = 4, tabs = { { id = 6, blocks = {
				{ id = 71, command = ticket, program = "/bin/bash", args = {}, live = true,
					exited = if outcome == "native_ended" then 0 else nil },
			} } } } } }
		end
		local adapter = {
			from_spawn = load("native_cli").from_spawn,
			epoch = function() return nil end,
			inspect = function(window, options, callback)
				check(window == "" and options.route.pane == 71 and options.route.socket == "/tmp/tern.sock", outcome .. ": retains the captured native route")
				if not inspected then inspected, inspection = true, callback else response(inventory(), callback) end
			end,
			wait_prompt = function(_route, _session, _pane, _options, callback)
				if outcome == "readiness_failed" then callback({ status = 0, stdout = "", stderr = "", timed_out = true }, nil)
				else response({ block = 71 }, callback) end
			end,
			process = function(_route, _session, _pane, _options, callback)
				if outcome == "process_failed" then callback({ status = 1, stdout = "", stderr = "native observation failed", timed_out = false }, nil)
				else response({ pane = 71, child = { pid = 10, argv = { "/bin/bash" } }, foreground = { pid = 10 } }, callback) end
			end,
		}
		local fake = {
			runtime = { os = "linux" }, json = runtime.json,
			on = function(name, callback) hooks[name] = callback end,
			timer = function(ms, callback) table.insert(timers, { ms = ms, fn = callback }) end,
			pane = { write = function(pane, text)
				local job = authority.execution_job(binding, id)
				check(pane == 71 and job.stage == "submission_intent" and job.command .. "\r" == text, "real durable intent precedes the only input")
				table.insert(writes, text)
			end },
		}
		local function install()
			local chunk = assert(loadstring(runtime.fs.read(root .. "/host_executor.luau"), "pending-claim-executor"))
			setfenv(chunk, setmetatable({ tern = fake, os = setmetatable({ time = function() return db.now end }, { __index = os }),
				require = function(name) return if name == "./native_cli" then adapter else load(name) end,
			}, { __index = environment }))
			local subject = chunk()
			subject.install(authority, function(changed, err)
				check(changed == binding or changed.session_key == binding.session_key, "notification keeps the bound session")
				check(err == nil, outcome .. ": lifecycle observation persists without error")
				-- Host notifications queue a sweep before the asynchronous native
				-- callback. Empty inventory deliberately exercises the observed boundary.
				fake.timer(1, function()
					sweeps += 1
					assert(authority.sweep(binding, {}, nil, db.now) ~= nil)
				end)
			end)
			return subject
		end
		local function drain()
			local turns = 0
			while true do
				local index = nil
				for position, timer in ipairs(timers) do if timer.ms <= 50 then index = position; break end end
				if index == nil then return end
				turns += 1; assert(turns <= 32, "claim fixture callbacks remain bounded")
				table.remove(timers, index).fn()
			end
		end
		local subject = install(); drain()
		local spec = { program = "/bin/bash", args = { "-l", "-c", ticket }, env = {
			TERN_PANE = "71", TERN_EXE = "/opt/tern", TERN_PANE_SOCKET = "/tmp/tern.sock", TERN_WINDOW_KEY = "",
		} }
		check(hooks.spawn(copy(spec)) ~= nil, outcome .. ": native filter accepts the admitted ticket")
		drain()
		local a = by_id(snapshot(authority, binding))
		local job = authority.execution_job(binding, id)
		check(sweeps > 0 and inspection ~= nil and a[id].sequence == 1 and a[id].phase == "Starting" and a[id].unresolved
			and job.stage == "claimed" and job.native.pane == 71 and job.command == nil and #writes == 0,
			outcome .. ": an actual deferred claim survives its notification sweep before native callback")
		check(hooks.spawn(copy(spec)) == nil, outcome .. ": the pending ticket cannot be claimed twice")
		if outcome == "reload" then
			timers, hooks = {}, {}
			subject = install(); drain()
		else
			if outcome == "pane_exited" then hooks.pane_exited({ pane = 71, status = 0 }) end
			response(inventory(), inspection)
		end
		a = by_id(snapshot(authority, binding)); job = authority.execution_job(binding, id)
		if outcome == "submit" then
			check(#writes == 1 and job.stage == "submitted" and job.command ~= nil, "the original pending callback submits once after exact native membership/readiness/process proof")
			subject.attach(binding)
			check(hooks.spawn(copy(spec)) == nil and #writes == 1, "attach and the consumed ticket cannot repeat the configured input")
			drain()
			a = by_id(snapshot(authority, binding)); job = authority.execution_job(binding, id)
			check(a[id].phase == "Exited" and job.stage == "resolved" and a[id].exit_status == nil, "post-submission inventory absence retains ordinary settlement without inventing success")
		elseif outcome == "reload" then
			check(#writes == 0 and a[id].phase == "Exited" and job.stage == "resolved" and job.command == nil, "real reload never resumes an unsubmitted claim and ordinary sweep still settles it")
		else
			check(#writes == 0 and job.stage == "failed" and a[id].phase == "Failed" and not a[id].unresolved and a[id].sequence == 2
				and a[id].exit_status == nil and job.command == nil, outcome .. ": existing native failure ends the pre-submission claim without a provider exit status or input")
			local ended = db.image(); drain()
			same(db.image(), ended, outcome .. ": later sweeps preserve terminal history")
		end
	end
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
	stored.config.hosts["host-A"].agents[1].include_all=true
	stored.sessions[binding.session_key].managed_imports["bridge-import"][1].include_all=false
	local old_db = boundary(image)
	local upgraded = modules(old_db)
	local view = snapshot(upgraded, binding)
	check(#view.records == 2 and view.records[1].id == "agent" and view.records[1].duplicate_policy == nil, "a stored record carrying duplicate_policy is read with it stripped")
	check(view.records[1].include_all==nil and view.config_revision==stored.config_revision,"retired bulk policy is removed without changing retained configuration epoch")
	same(old_db.peek("authority-roster-original"),stored,"roster normalization preserves an exact readback original before its next durable write")
	check(assert(upgraded.managed_import(binding, -1, "bridge-import", { record("imported") })).replayed, "an old receipt carrying duplicate_policy still replays exactly")
	check(submit(upgraded, binding, reserve_request(binding, "window", 1, view.config_revision, "agent")).ok, "the stripped record launches")
	local saved = old_db.peek("authority")
	check(saved.config.hosts["host-A"].agents[1].duplicate_policy == nil and saved.sessions[binding.session_key].managed_imports["bridge-import"][1].duplicate_policy == nil, "the next persist writes canonical values")
	check(saved.config.hosts["host-A"].agents[1].include_all==nil and saved.sessions[binding.session_key].managed_imports["bridge-import"][1].include_all==nil,"retired bulk policy never reappears in the roster or import receipts")
end

-- These fixtures exercise the real writer/lifecycle, not a provider or native
-- platform. Native inventory and result-file bytes are explicit boundary inputs.
local function default_fixture(roster,run_id)
	local db,authority,binding,config,launch,load=fresh(roster)
	local f={db=db,a=authority,b=binding,config=config,launch=launch,load=load,context=setup_context(binding),sequences={},
		run=run_id or "run-default"}
	function f.send(op,data,observer)
		observer=observer or "default-window"
		local n=(f.sequences[observer] or 0)+1;f.sequences[observer]=n
		local r=request(binding,observer,n,snapshot(f.a,binding).config_revision,op,data,if n>1 then {observer.."/"..tostring(n-1)} else {})
		local reply=submit(f.a,binding,r,f.context)
		if reply.ok and reply.result.job then f.job=reply.result.job end
		return reply,r
	end
	local reply=f.send("start_setup",{setup_run_id=f.run,command="truthful-default --profile 'work account' --opaque=$VALUE",
		cwd=f.context.inventory.sessions[1].tabs[1].blocks[1].cwd,window=f.context.window,config_pane=700})
	check(reply.ok,"default bootstrap admitted: "..tostring(reply.error))
	function f.step(op,extra)
		local data={attempt_id=f.job.id,setup_run_id=f.run}
		for k,v in pairs(extra or {}) do data[k]=v end
		return f.send(op,data)
	end
	function f.bind()
		check(f.step("setup_claim").ok,"native setup claim persisted")
		check(f.step("setup_begin").ok,"native setup effect intent persisted")
		table.insert(f.context.inventory.sessions[1].tabs[1].blocks,{id=42,command=f.job.setup.command,cwd=f.job.cwd})
		check(f.step("setup_bind",{pane=9001}).ok,"native setup source bound separately from SDK identity")
	end
	function f.envelope()
		return {schema=1,kind="spawn-setup-result",setup_run_id=f.run,binding=f.job.setup.binding,path=f.job.setup.result_path}
	end
	function f.result(records,padding)
		local bytes=runtime.json.encode({schema=2,setup_run_id=f.run,confirmed=true,agents=records})..string.rep(" ",padding or 0)
		db.files[f.job.setup.result_path]=bytes
		return bytes
	end
	function f.accept(records,padding)
		local bytes=f.result(records,padding)
		local ok,why=f.a.setup_submission(f.b,f.envelope(),f.context)
		check(ok,"explicit setup bytes retained: "..tostring(why))
		f.job=snapshot(f.a,f.b).jobs[1]
		return bytes
	end
	function f.import_data()
		return {attempt_id=f.job.id,setup_run_id=f.run,pending_digest=f.job.pending_digest,confirmed=true}
	end
	return f
end
sections.setup_default=function()
	do
		local _,authority,binding=fresh(nil)
		local context=setup_context(binding)
		local original=context.inventory.sessions[1].tabs[1].blocks[1].cwd
		context.inventory.sessions[1].tabs[1].blocks[1].cwd=original.."/moved"
		local refused=submit(authority,binding,request(binding,"moved-folder",1,0,"start_setup",{setup_run_id="stale-folder",command="native-default",cwd=original,window=context.window,config_pane=700}),context)
		local retained=snapshot(authority,binding)
		check(not refused.ok and #retained.jobs==0 and #retained.attempts==0,"a changed native Config folder refuses setup before reserving or starting a helper")
	end
	local f=default_fixture(nil,"run/with:unsafe\\filename")
	local view=snapshot(f.a,f.b)
	check(#view.records==0 and view.config_revision==0 and #view.attempts==1,"empty-roster setup neither inserts nor enables a record")
	check(f.job.backend=="setup-default" and f.job.ticket==nil and view.attempts[1].mode=="Setup default","setup-only native effect never becomes ordinary Native OMP or shell ticket")
	check(f.job.setup.command=="truthful-default --profile 'work account' --opaque=$VALUE" and f.job.setup.config_pane==700 and f.job.setup.host_config_pane==10,"opaque command and separate SDK/native Config IDs are immutable")
	check(f.job.setup.result_path:match("setup%-result%-%x+%.json$")~=nil and not f.job.setup.result_path:find(f.run,1,true),"unsafe run IDs never become filenames")
	check(f.job.initial_prompt:find(f.job.setup.binding,1,true) and f.job.initial_prompt:find("submission command",1,true),"provider-neutral skill carries exact run binding and helper")
	local before=f.db.image()
	for _,field in ipairs({"backend","user","host","record_id"}) do
		local bad=request(f.b,"bad",1,0,"start_setup",{setup_run_id="other",command="default",cwd=f.job.cwd,window=f.context.window,config_pane=700})
		bad.data[field]="override"
		check(not f.a.request(f.b,bad,f.context),"setup rejects unsupported route override "..field)
		same(f.db.image(),before,"route override cannot allocate another attempt")
	end
	check(f.a.claim_execution(f.b,f.job.id,native())==nil,"setup cannot enter ordinary retained-shell claim")
	check(f.a.execution_record(f.b,f.job.id)==nil,"setup bootstrap is never resolved from a saved record")
	local out_of_order=f.step("setup_bind",{pane=9001})
	check(not out_of_order.ok and f.job.stage=="admitted","native bind requires durable pre-effect intent")
	table.insert(f.context.inventory.sessions[1].tabs[1].blocks,{id=41,command=f.job.setup.command,cwd=f.job.cwd})
	f.bind()
	view=snapshot(f.a,f.b)
	check(f.job.stage=="submitted" and f.job.native_pane==42 and f.job.setup.agent_pane==9001 and view.attempts[1].pane==42,"one bind preserves both pane domains")
	check(view.attempts[1].observer_id==view.namespace.."/executor" and f.job.observer_id=="default-window","executor identity and request observer remain distinct")
	check(not f.step("setup_begin").ok and not f.step("setup_bind",{pane=9002}).ok,"effect begin and native binding are one-use")
	same(snapshot(f.a,f.b).records,{},"native effect lifecycle never imports its bootstrap")
end
sections.setup_submission=function()
	local f=default_fixture();f.bind()
	local records={record("submitted",{arguments={"literal null","quote \" slash \\ Ω"}})}
	local base=f.result(records)
	local bytes=base..string.rep(" ",120000-#base)
	f.db.files[f.job.setup.result_path]=bytes
	local envelope=f.envelope()
	for _,field in ipairs({"binding","setup_run_id","path"}) do
		local wrong=copy(envelope);wrong[field]..="-wrong"
		refused_unchanged(f.db,function()return f.a.setup_submission(f.b,wrong,f.context)end,"wrong submission "..field)
	end
	check(f.db.file_reads[envelope.path]==nil,"binding/path/run refusals precede any file read")
	local closed=copy(f.context);table.remove(closed.inventory.sessions[1].tabs[1].blocks,2)
	refused_unchanged(f.db,function()return f.a.setup_submission(f.b,envelope,closed)end,"closed source submission")
	check(f.db.file_reads[envelope.path]==nil,"inactive source does not read the file")
	local original=f.db.image()
	f.db.files[envelope.path]='{"schema":2,"setup_run_id":"run-default","confirmed":true,"agents":[],"unknown":null}'
	check(not f.a.setup_submission(f.b,envelope,f.context),"unknown null member cannot disappear through native JSON")
	same(f.db.image(),original,"invalid raw schema never retains pending bytes")
	f.db.files[envelope.path]=bytes.." "
	check(not f.a.setup_submission(f.b,envelope,f.context),"120001 complete bytes refuse rather than truncate to the valid 120000-byte prefix")
	same(f.db.image(),original,"over-bound result preserves pending capacity and accepted-state absence")
	f.db.files[envelope.path]=bytes
	check(f.a.setup_submission(f.b,envelope,f.context),"large complete submission accepted")
	local read_count=f.db.file_reads[envelope.path]
	f.db.files[envelope.path]="changed after submission"
	local accepted=f.db.image()
	check(not f.a.setup_submission(f.b,envelope,f.context),"duplicate explicit submission refused")
	same(f.db.image(),accepted,"duplicate cannot replace immutable accepted bytes")
	local pending=assert(f.a.setup_pending(f.b,f.job.id))
	check(pending.bytes==bytes and not pending.consumed and f.db.file_reads[envelope.path]==read_count,"pending retrieval reads immutable durable bytes, never mutable file")
	local view=snapshot(f.a,f.b);f.job=view.jobs[1]
	check(f.job.pending_bytes==#bytes and f.job.pending_digest==f.load("wire/codec").sha256(bytes) and f.job.pending==nil,"public metadata identifies complete bytes without carrying them")
	check(#runtime.json.encode(view)<120000 and #runtime.json.encode(f.db.peek("authority"))>#bytes,"large result is stored once outside bounded public projection")
	local writes=f.db.authority_writes
	local reply=f.send("import_records",f.import_data())
	check(reply.ok and reply.result.imported==1 and f.db.authority_writes==writes+1,"records, one-use consumption, reply and watermark persist atomically")
	local consumed=assert(f.a.setup_pending(f.b,f.job.id))
	check(consumed.consumed and consumed.bytes==nil and f.db.file_reads[envelope.path]==read_count,"successful import releases raw bytes and never rereads the source file")
	check(#snapshot(f.a,f.b).attempts==1 and #snapshot(f.a,f.b).records==1,"import reserves no new launch")
	check(not f.send("import_records",f.import_data()).ok,"new request cannot reuse consumed automatic result")
end
sections.setup_import_fences=function()
	local variants={
		function(f)f.context.window="another-window" end,
		function(f)f.context.config_pane=11 end,
		function(f)f.context.inventory.clients[1].since+=1 end,
		function(f)f.context.epoch="fixture-host:2" end,
		function(f)f.context.inventory.sessions[1].tabs[1].blocks[2].command="pane reused" end,
		function(f)f.context.inventory.sessions[1].tabs[1].blocks[2].cwd="/different" end,
		function(f)table.remove(f.context.inventory.sessions[1].tabs[1].blocks,2)end,
		function(f)edit(f.a,f.b,"replace-records",{records={record("manual-change")}})end,
	}
	for index,mutate in ipairs(variants) do
		local f=default_fixture();f.bind();f.accept({record("wanted")});mutate(f)
		local before=snapshot(f.a,f.b)
		local reply=f.send("import_records",f.import_data())
		check(not reply.ok,"fresh native/config source fence "..index.." refuses")
		local after=snapshot(f.a,f.b)
		same(after.records,before.records,"fresh source fence preserves all records")
		check(not assert(f.a.setup_pending(f.b,f.job.id)).consumed,"fresh source fence preserves unconsumed pending bytes")
	end
	local f=default_fixture();f.bind();f.accept({record("wanted")})
	local data=f.import_data();data.confirmed=nil
	refused_unchanged(f.db,function()return f.a.request(f.b,request(f.b,"default-window",5,0,"import_records",data),f.context)end,"missing explicit native confirmation")
	data=f.import_data();data.pending_digest=string.rep("0",64)
	check(not f.send("import_records",data).ok,"changed reviewed digest refuses")
	check(not f.send("import_records",f.import_data(),"another-window").ok,"another observer cannot borrow a result")
	local before=f.db.image();f.db.fail_after(1)
	local next_sequence=(f.sequences["default-window"] or 0)+1
	local r=request(f.b,"default-window",next_sequence,0,"import_records",f.import_data())
	check(not f.a.request(f.b,r,f.context),"atomic storage failure refuses the entire import")
	same(f.db.image(),before,"failed write preserves records, pending bytes and request watermark")
	f.db.fail_authority_at=nil
	check(f.a.request(f.b,r,f.context),"explicit retry of an uncommitted import can succeed")
	check(snapshot(f.a,f.b).replies[r.request_id].ok,"retried import is committed, not a launch replay")
	local committed=f.db.image()
	check(f.a.request(f.b,r,f.context),"identical retained request returns its one existing receipt")
	same(f.db.image(),committed,"retained import replay writes nothing")
	check(not f.a.reviewed_setup_preparation(f.b,r.request_id,f.job.id,r.data.pending_digest),"plain Save settings only is never a preparation or paid-model approval")
	do
		local function preparation(f)
			return {nonce="prepare-receipt",revision=1,window=f.context.window,native_namespace="fixture-desktop",native_conn=1,native_since=10,
				entries={{nonce="prepare-receipt-1",record_id="wanted",label="custom — wanted",backend="local-terminal",revision=2}},
				consents={{nonce="prepare-receipt-1",window_consent="explicit-record-native-consent"}}}
		end
		local signed=default_fixture();signed.bind();signed.accept({record("wanted")})
		local data=signed.import_data();data.preparation=preparation(signed)
		local receipt,issued=signed.send("import_records",data)
		check(receipt.ok and #snapshot(signed.a,signed.b).records==1,"one final approval saves exact settings plus explicit preparation consent without starting checks")
		local before=signed.db.image()
		local captured=assert(signed.a.reviewed_setup_preparation(signed.b,issued.request_id,signed.job.id,data.pending_digest))
		same(captured,data.preparation,"preparation projection is the exact immutable successful import request, including record nonces and native recipient")
		same(signed.db.image(),before,"reading the actual preparation receipt acknowledges or deletes nothing")
		check(not signed.a.reviewed_setup_preparation(signed.b,"missing-receipt",signed.job.id,data.pending_digest),"an unrelated saved-state receipt cannot authorize preparation")
		local other=assert(signed.a.open("host-A",5))
		check(not signed.a.reviewed_setup_preparation(other,issued.request_id,signed.job.id,data.pending_digest),"another session cannot borrow an original Config's approval")
		edit(signed.a,signed.b,"replace-records",{records={record("wanted",{enabled=false})}})
		check(not signed.a.reviewed_setup_preparation(signed.b,issued.request_id,signed.job.id,data.pending_digest),"a later settings revision cannot reuse an old successful import receipt for preparation")
		for _,mutate in ipairs({
			function(value)value.entries[1].record_id="unrelated" end,
			function(value)value.entries[1].revision+=1 end,
			function(value)value.window="another-window" end,
			function(value)value.consents[1].nonce="different-record-consent" end,
		}) do
			local guarded=default_fixture();guarded.bind();guarded.accept({record("wanted")})
			local proposed=guarded.import_data();proposed.preparation=preparation(guarded);mutate(proposed.preparation)
			local accepted,why=guarded.a.request(guarded.b,request(guarded.b,"default-window",5,0,"import_records",proposed,{"default-window/4"}),guarded.context)
			if accepted then check(not snapshot(guarded.a,guarded.b).replies["default-window/5"].ok,"changed scope is a real refused import outcome") else check(type(why)=="string","malformed consent is refused by the closed request contract") end
			check(#snapshot(guarded.a,guarded.b).records==0 and not assert(guarded.a.setup_pending(guarded.b,guarded.job.id)).consumed,"changed roster, revision, recipient or nonce cannot save or authorize model preparation")
		end
	end
end
sections.setup_import_conflicts=function()
	local existing=record("existing")
	local f=default_fixture({existing});f.bind()
	f.accept({existing,record("new")})
	local reply=f.send("import_records",f.import_data())
	check(reply.ok and reply.result.imported==1 and #snapshot(f.a,f.b).records==2,"identical existing ID skips while new record imports")
	local conflict=default_fixture({existing});conflict.bind()
	conflict.accept({record("new"),record("existing",{command="divergent"})})
	local before=snapshot(conflict.a,conflict.b)
	local refused=conflict.send("import_records",conflict.import_data())
	check(not refused.ok and refused.error:find("record-conflict",1,true),"one divergent ID refuses whole operation")
	same(snapshot(conflict.a,conflict.b).records,before.records,"divergent import cannot partially insert earlier records")
	check(not assert(conflict.a.setup_pending(conflict.b,conflict.job.id)).consumed,"conflict cannot consume reviewed bytes")
	local full={};for index=1,32 do full[index]=record("id-"..index) end
	local maximum=default_fixture();maximum.bind();maximum.accept(full)
	check(maximum.send("import_records",maximum.import_data()).result.imported==32,"32 complete reviewed records import without any bootstrap record")
	local overflow=default_fixture();overflow.bind();table.insert(full,record("id-33"));overflow.result(full)
	check(not overflow.a.setup_submission(overflow.b,overflow.envelope(),overflow.context),"33 records refuse before immutable submission acceptance")
	local unreviewed=default_fixture();unreviewed.bind()
	local claimed=setup_record("self-certified");claimed.mailbox.verified=true;claimed.mailbox.evidence_ref="agent-asserted"
	unreviewed.result({record("ordinary-first"),claimed})
	local accepted,claim_error=unreviewed.a.setup_submission(unreviewed.b,unreviewed.envelope(),unreviewed.context)
	check(not accepted and claim_error:find("new record",1,true) and #snapshot(unreviewed.a,unreviewed.b).records==0,"guided ingress rejects self-certified readiness before retaining any partial import")
	check(unreviewed.a.setup_pending(unreviewed.b,unreviewed.job.id)==nil,"rejected readiness leaves no immutable pending result preventing correction and fresh approval")
	local manual=default_fixture();manual.bind()
	local refused_manual=manual.send("import_records",{manual=true,setup_run_id="manual-untrusted",confirmed=true,records={record("ordinary-first"),claimed}},"manual-owner")
	check(not refused_manual.ok and #snapshot(manual.a,manual.b).records==0,"the same readiness claims rejected at guided ingress cannot enter through manual review, even beside ordinary records")
	claimed.mailbox.verified=false;claimed.mailbox.evidence_ref=nil
	unreviewed.accept({record("ordinary-first"),claimed})
	local corrected=unreviewed.send("import_records",unreviewed.import_data())
	check(corrected.ok and corrected.result.imported==2,"a corrected explicitly reviewed ordinary proposal saves rather than remaining trapped behind its rejected readiness claim")
	local preserved=setup_record("already-saved");preserved.mailbox.verified=true;preserved.mailbox.evidence_ref="actual-prior-setup"
	local keep=default_fixture({preserved});keep.bind();keep.accept({preserved})
	check(keep.send("import_records",keep.import_data()).ok and snapshot(keep.a,keep.b).records[1].mailbox.verified==true,"an identical previously saved verified record preserves its actual prior setup")
end
sections.setup_discard=function()
	local f=default_fixture({record("existing")});f.bind()
	f.accept({record("existing",{command="conflicting"}),record("not-imported")})
	check(not f.send("import_records",f.import_data()).ok,"conflicting reviewed result remains available for an explicit discard decision")
	local before=snapshot(f.a,f.b)
	local data=f.import_data()
	for _,field in ipairs({"attempt_id","setup_run_id","pending_digest"}) do
		local changed=copy(data);changed[field]=if field=="pending_digest" then string.rep("0",64) else changed[field].."-wrong"
		check(not f.send("discard_setup_result",changed).ok and not assert(f.a.setup_pending(f.b,f.job.id)).consumed,"discard refuses a changed exact pending identity: "..field)
	end
	local original_context=f.context;f.context=copy(f.context);f.context.window="not-an-observed-window"
	check(not f.send("discard_setup_result",data).ok and not assert(f.a.setup_pending(f.b,f.job.id)).consumed,"discard requires actual current native Config membership, not a caller window label")
	f.context=original_context
	local reply,request_value=f.send("discard_setup_result",data)
	check(reply.ok and reply.result.discarded==true,"exact explicit decision consumes only its reviewed pending submission")
	local after=snapshot(f.a,f.b)
	same(after.records,before.records,"discard imports no conflicting or adjacent records")
	same(after.attempts,before.attempts,"discard preserves existing helper/launch history without claiming exit")
	check(after.config_revision==before.config_revision and after.jobs[1].setup_discarded==true and assert(f.a.setup_pending(f.b,f.job.id)).consumed,"discard retains exact digest metadata distinctly from an import and leaves the roster revision unchanged")
	local settled=f.db.image()
	check(f.a.request(f.b,request_value,f.context),"identical discard delivery returns its existing receipt")
	same(f.db.image(),settled,"discard replay does not consume another submission or mutate history")
	check(not f.send("discard_setup_result",data).ok,"a new decision cannot discard an already consumed submission twice")
	local fresh=f.send("start_setup",{setup_run_id="fresh-after-discard",command="truthful-default",cwd=f.job.cwd,window=f.context.window,config_pane=700})
	check(fresh.ok and #snapshot(f.a,f.b).attempts==#before.attempts+1,"a discarded conflicting result no longer strands the single-run guard and a separately approved fresh run may be admitted")
end
sections.setup_default_recovery=function()
	for _,claimed in ipairs({false,true}) do
		local f=default_fixture()
		if claimed then check(f.step("setup_claim").ok,"claim before expiry fixture") end
		f.db.now+=30
		local view=snapshot(f.a,f.b)
		check(view.jobs[1].stage=="failed" and view.attempts[1].phase=="Failed","admitted and claimed native setup expire at exactly 30 seconds")
		check(not f.step("setup_begin").ok,"expired setup never obtains effect permission")
	end
	local f=default_fixture();f.step("setup_claim");f.step("setup_begin")
	f.db.now+=300
	local reloaded=modules(f.db);f.a=reloaded
	check(snapshot(f.a,f.b).jobs[1].stage=="submission_intent","unbound persisted native effect is never reinterpreted as an expired ticket")
	check(f.a.sweep(f.b,{[10]={}},"fixture-host:1",f.db.now)==0,"normal sweep cannot settle an uncertain unbound effect as never-started")
	check(not f.step("setup_begin").ok,"reload cannot obtain another native effect permission")
	check(f.step("setup_uncertain").ok and snapshot(f.a,f.b).attempts[1].unresolved,"explicit uncertain native outcome retains reservation")
	local pending=default_fixture();pending.bind();pending.accept({record("recovered")})
	table.remove(pending.context.inventory.sessions[1].tabs[1].blocks,2)
	check(pending.a.sweep(pending.b,{[10]={}},"fixture-host:1",pending.db.now)==1,"closed setup source settles its launch without discarding result")
	edit(pending.a,pending.b,"clear-history",{attempt_revision=snapshot(pending.a,pending.b).attempt_revision})
	check(#snapshot(pending.a,pending.b).attempts==1 and assert(pending.a.setup_pending(pending.b,pending.job.id)).bytes~=nil,"unconsumed result protects otherwise-finished history")
	check(not pending.send("import_records",pending.import_data()).ok,"closed native source cannot automatically import")
	local manual=pending.send("import_records",{setup_run_id=pending.run,records={record("recovered")},manual=true,confirmed=true},"manual-review")
	check(manual.ok and manual.result.imported==1,"explicit disclosed manual recovery works in original host/session after source closure")
	check(assert(pending.a.setup_pending(pending.b,pending.job.id)).consumed,"manual recovery consumes matching retained result atomically")
	edit(pending.a,pending.b,"clear-history",{attempt_revision=snapshot(pending.a,pending.b).attempt_revision})
	check(#snapshot(pending.a,pending.b).attempts==0,"consumed finished result returns to normal history eligibility")
	local retained=default_fixture();retained.bind();retained.accept({record("retained-reference")})
	table.remove(retained.context.inventory.sessions[1].tabs[1].blocks,2)
	local reference=retained.import_data();reference.manual=true
	local changed=copy(reference);changed.pending_digest=string.rep("0",64)
	check(not retained.send("import_records",changed,"manual-review").ok,"manual retained recovery refuses a changed reviewed digest")
	changed=copy(reference);changed.setup_run_id="another-run"
	check(not retained.send("import_records",changed,"manual-review").ok,"manual retained recovery refuses a borrowed run identity")
	check(#snapshot(retained.a,retained.b).records==0 and not assert(retained.a.setup_pending(retained.b,retained.job.id)).consumed,
		"refused manual references preserve records and the pending source")
	local mixed=copy(reference);mixed.records={record("replacement")}
	refused_unchanged(retained.db,function()
		return retained.a.request(retained.b,request(retained.b,"mixed-review",1,snapshot(retained.a,retained.b).config_revision,"import_records",mixed),retained.context)
	end,"manual reference cannot substitute a second record payload")
	local recovered=retained.send("import_records",reference,"manual-review")
	check(recovered.ok and recovered.result.imported==1 and assert(retained.a.setup_pending(retained.b,retained.job.id)).consumed,
		"explicit manual reference imports and consumes same-session retained bytes after source closure")
	check(not retained.send("import_records",reference,"manual-review").ok,"consumed manual reference cannot be imported twice")
	local strict=default_fixture();strict.bind();strict.accept({record("strict")})
	local saved=strict.db.image()
	for index,mutate in ipairs({
		function(job)job.setup.extra=true end,
		function(job)job.setup.native_session+=1 end,
		function(job)job.setup.before_panes={10,10} end,
		function(job)job.native.pane+=1 end,
		function(job)job.setup.agent_pane=nil end,
		function(job)job.pending.digest=string.rep("0",64)end,
		function(job)job.pending.length+=1 end,
		function(job)job.pending.consumed=true end,
		function(job)job.ticket="exit 125 # SPAWN:"..job.token end,
		function(job)
			job.pending.bytes='{"schema":2,"setup_run_id":"run-default","confirmed":true,"agents":[],"unknown":null}'
			job.pending.length=#job.pending.bytes;job.pending.digest=strict.load("wire/codec").sha256(job.pending.bytes)
		end,
	}) do
		local damaged=copy(saved);mutate(damaged.authority.sessions[strict.b.session_key].jobs[strict.job.id])
		local db=boundary(damaged);local a=modules(db)
		local view,why=a.snapshot(strict.b)
		check(view==nil and type(why)=="string","strict setup recovery validator refuses changed binding/projection/result "..index)
		same(db.image(),damaged,"corrupt setup recovery never repairs or replays uncertain work")
	end
	local legacy=copy(saved);legacy.authority.sessions[strict.b.session_key].jobs[strict.job.id].backend="native-agent"
	local old=modules(boundary(legacy));local view,why=old.snapshot(strict.b)
	check(view==nil and why:find("earlier Native OMP setup protocol",1,true),"old retained setup work has visible mixed-version hold, never reinterpretation")
	local isolated=assert(strict.a.open("host-A",5))
	table.remove(strict.context.inventory.sessions[1].tabs[1].blocks,2)
	check(strict.a.sweep(strict.b,{[10]={}},"fixture-host:1",strict.db.now)==1,"retention fixture closes original native source")
	local preview=assert(strict.a.forget_sessions(isolated,{[5]=true},false))
	check(preview.sessions==0 and preview.kept==1,"unconsumed closed-source result prevents ended-session garbage collection")
	local single=default_fixture()
	check(single.step("setup_claim").ok and single.step("setup_begin").ok,"one explicit setup may reach native effect intent")
	local previous=single.job.id
	local duplicate=single.send("start_setup",{setup_run_id="second-run",command="trusted-default",cwd=single.job.cwd,window=single.context.window,config_pane=700})
	check(not duplicate.ok and #snapshot(single.a,single.b).jobs==1 and snapshot(single.a,single.b).jobs[1].id==previous,"a different run ID cannot admit a second paid setup helper while the original run remains unfinished")
end

local run = assert(sections[section], "unknown authority test section: " .. section)
local artifact=run()
return "PASS " .. section .. " " .. tostring(checks) .. " SPAWN authority checks" .. (if artifact then "\nSPAWN_AUTHORITY_V4_JSON "..artifact else "")
