-- Run owned code in Tern's Lua runtime; the only argument is the package root.
local root = ...
assert(type(root) == "string", "pass the package directory")
local runtime, environment = tern, getfenv()
local modules = {}
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load, tern = runtime }, { __index = environment }))
	local result = chunk()
	modules[name] = result
	return result
end
local config, lifecycle = load("config"), load("launch_state")
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
local function record(id, fields)
	local result = {
		id = id, provider = "custom", account_label = id, backend = "local-terminal",
		command = "ordinary-cli", arguments = {}, enabled = true, include_all = true,
		duplicate_policy = "skip", placement = "tab",
	}
	for key, value in pairs(fields or {}) do result[key] = value end
	return result
end
local function migrate(records)
	local result, err = config.migrate({ schema = 1, agents = records }, "host-A")
	assert(result, tostring(err))
	return result
end
local function refused(saved, message)
	local before = copy(saved)
	local result, err = config.migrate(saved, "host-A")
	check(result == nil and type(err) == "string", message)
	same(saved, before, message .. " leaves source untouched")
end

-- Migration is a candidate transformation, never an in-place repair.
local fresh = assert(config.migrate(nil, "host-A"))
check(fresh.changed and #fresh.records == 0, "cold start has no seeded accounts")
check(not assert(config.migrate(fresh.store, "host-A")).changed, "empty store is idempotent")
local original_record = record("preserved", {
	command = "/opt/My Tools/custom-cli", arguments = { "", "two words", "--", "acp", "$(not executed)" },
	cwd = "/work/a directory/'quoted'", prompt = "  Keep this prompt.\nSecond line: $HOME `literal`  ",
	enabled = false, include_all = false, duplicate_policy = "allow", placement = "split",
	host = "remote.example", user = "account", key_path = "/keys/my key",
})
local sentinel = { schema = 1, agents = { record("foreign") }, extension = { exact = "untouched" } }
local saved = { schema = 2, hosts = { ["host-A"] = { schema = 1, agents = { original_record }, note = "bucket" }, ["host-B"] = sentinel }, extension = { preserve = true } }
local before = copy(saved)
local migrated = assert(config.migrate(saved, "host-A"))
same(migrated.records[1], original_record, "canonical account fields survive migration exactly")
same(saved, before, "migration does not mutate original before durable commit")
same(migrated.store.hosts["host-B"], sentinel, "other host bucket is preserved")
same(migrated.store.extension, saved.extension, "store metadata is preserved")
check(migrated.store.hosts["host-A"].note == "bucket", "active bucket metadata is preserved")
local second = assert(config.migrate(migrated.store, "host-A"))
check(not second.changed, "second migrated load needs no write")
same(second.store, migrated.store, "second load preserves exact canonical store")
refused({ schema = 99, agents = {} }, "future root refuses downgrade")
refused({ schema = 2, hosts = { ["host-B"] = { schema = 99, agents = {} } } }, "future foreign bucket refuses replacement")
refused({ schema = 2, hosts = false }, "corrupt host map refuses reset")
refused({ schema = 1, agents = { record("same"), record("same") } }, "duplicate account identities refuse migration")
refused({ schema = 1, agents = { [1] = record("first"), [3] = record("third") } }, "sparse roster refuses truncation")
refused({ schema = 1, agents = { record("bad", { arguments = { [1] = "a", [3] = "b" } }) } }, "sparse argv refuses truncation")
local full = {}
for index = 1, 32 do full[index] = record("account-" .. tostring(index)) end
check(#migrate(full).records == 32, "full supported roster is retained")
full[33] = record("account-33")
refused({ schema = 1, agents = full }, "overflow roster refuses instead of keeping first 32")
full[33] = record("account-33", { command = "unterminated '" })
refused({ schema = 2, hosts = { ["host-B"] = { schema = 1, agents = full } } }, "inactive host overflow also refuses replacement")
local twin = record("pair", {
	backend = "native-agent", provider = "claude", command = "claude-agent-acp", arguments = { "--server-only" },
	cli_command = "/opt/bin/claude", cli_arguments = { "", "--profile", "work account" },
	acp_enabled = true, include_cli_twin = true, cwd = "/project", prompt = "exact prompt",
})
local paired = migrate({ twin }).records[1]
check(paired.backend == "local-terminal" and not paired.review_required, "proven server and ordinary pair selects one terminal launch")
check(paired.command == twin.cli_command, "explicit ordinary executable survives")
same(paired.arguments, twin.cli_arguments, "alternate argv stays paired with alternate executable")
check(paired.cwd == twin.cwd and paired.prompt == twin.prompt, "pair migration retains cwd and prompt")
check(paired.cli_command == nil and paired.acp_enabled == nil and paired.include_cli_twin == nil, "canonical record drops retired launch fields")
local ambiguous = record("ambiguous", { backend = "native-agent", command = "custom-a", arguments = { "one" }, cli_command = "custom-b", cli_arguments = { "two" } })
local blocked = migrate({ ambiguous }).records[1]
check(blocked.review_required and blocked.command == "custom-a", "ambiguous ordinary pair blocks without guessing")
same(blocked.arguments, { "one" }, "ambiguous pair preserves original argv")
local blocked_reload = assert(config.migrate(migrate({ ambiguous }).store, "host-A"))
check(not blocked_reload.changed and blocked_reload.records[1].review_required, "review blocking survives reload idempotently")
for index, invocation in ipairs({
	{ "claude-agent-acp", {} }, { "'C:\\tools\\codex-acp.cmd'", {} }, { "kimi", { "acp" } },
	{ "gemini", { "--experimental-acp" } }, { "sh", { "-c", "exec claude-agent-acp; echo done" } },
	{ "env", { "KEY=value", "codex-acp" } }, { "omp", { "--profile", "work", "acp" } },
}) do
	local item = record("server-" .. tostring(index), { command = invocation[1], arguments = invocation[2] })
	local converted = migrate({ item }).records[1]
	check(converted.review_required, "server-shaped or ambiguous invocation requires review " .. tostring(index))
	check(converted.command == item.command, "blocked executable is preserved " .. tostring(index))
	same(converted.arguments, item.arguments, "blocked argv is preserved " .. tostring(index))
	check(config.validate_record(item) == nil, "unreviewed server cannot be saved as launchable " .. tostring(index))
end
local omp = migrate({ record("omp", { provider = "omp", backend = "native-agent", command = "omp", arguments = { "acp", "message", "acp", "" } }) }).records[1]
check(not omp.review_required and omp.command == "omp", "direct native OMP server mode converts")
same(omp.arguments, { "message", "acp", "" }, "only proven immediate OMP subcommand is removed")
local embedded = migrate({ record("omp-command", { provider = "omp", backend = "native-agent", command = 'omp acp message --profile "work account"', arguments = { "acp" } }) }).records[1]
same(assert(config.parse_arguments(embedded.command)), { "omp", "message", "--profile", "work account" }, "embedded immediate subcommand removal retains command token boundaries")
same(embedded.arguments, { "acp" }, "embedded removal does not strip separate argument values")
for _, command in ipairs({ "custom-cli", "claude", "omp" }) do
	local ordinary = migrate({ record(command, { command = command, arguments = { "message", "mention claude-agent-acp", "acp" } }) }).records[1]
	check(not ordinary.review_required, "ordinary argument values are not mistaken for server mode: " .. command)
end
local argv = { "", " ", "two words", "single'quote", 'double"quote', "back\\slash", "$HOME", "`literal`", "a;b", "line\nbreak", "--", "雪" }
same(assert(config.parse_arguments(config.render_arguments(argv))), argv, "argument render/parse round trip preserves every boundary")
same(assert(config.parse_arguments([[one '' "" 'a\b' two\ words pre"mid"post]])), { "one", "", "", "a\\b", "two words", "premidpost" }, "editor parser preserves empty quoted and concatenated tokens")
check(config.parse_arguments("unfinished\\") == nil, "trailing escape refuses save")
check(config.parse_arguments("'unfinished") == nil, "unterminated quote refuses save")
check(config.parse_arguments("bad\0argument") == nil, "null byte refuses save")
local many = {}
for index = 1, 256 do many[index] = "x" end
check(#assert(config.parse_arguments(table.concat(many, " "))) == 256, "argument count accepts boundary")
table.insert(many, "x")
check(config.parse_arguments(table.concat(many, " ")) == nil, "argument count refuses overflow")

-- The same renderer used by the host preserves canonical argv and never makes
-- an ordinary terminal prompt into an implicit provider message.
local executor, native = load("host_executor"), load("native_cli")
local ordinary_render = record("render", { command = "'/opt/My Tools/custom-cli'", arguments = copy(argv), prompt = "not an implicit ordinary-terminal message" })
local render_before = copy(ordinary_render)
local rendered = assert(executor.render(ordinary_render, "/bin/bash", "linux"))
-- POSIX lines carry one provider command-name word; the rest is the exact argv.
local function argv_of(line, provider)
	local words = assert(config.parse_arguments(line))
	check(words[1] == "SPAWN_PROVIDER=" .. provider, "POSIX launch line begins with its provider command name")
	table.remove(words, 1)
	return words
end
local rendered_words = argv_of(rendered, "custom")
local expected_words = { "/opt/My Tools/custom-cli" }
for _, value in ipairs(argv) do table.insert(expected_words, value) end
same(rendered_words, expected_words, "host POSIX rendering preserves empty, quoted, newline and Unicode argv")
same(ordinary_render, render_before, "host rendering does not mutate the approved record")
local approved_prompt = "  Exact approved prompt.\nQuotes: ' \" $HOME `literal`  "
local native_record = record("native-render", { provider = "omp", backend = "native-agent", command = "omp", arguments = { "--profile", "work account" }, prompt = "saved greeting", user = "account" })
rendered = assert(executor.render(native_record, "/bin/zsh", "macos", approved_prompt))
same(argv_of(rendered, "omp"), { "sudo", "-u", "account", "-H", "--", "omp", "--profile", "work account", approved_prompt }, "native setup prompt is one exact startup argv after approved arguments")
check(native_record.prompt == "saved greeting" and #native_record.arguments == 2, "setup prompt does not overwrite the record or append persisted argv")
native_record.user = ""
same(argv_of(assert(executor.render(native_record, "/bin/bash", "linux")), "omp"), { "omp", "--profile", "work account", "saved greeting" }, "ordinary native launch uses its approved stored prompt")
local wrapped = record("wrapped", { command = "sudo -u explicit -- ordinary-cli", user = "saved-user", arguments = { "one" } })
same(argv_of(assert(executor.render(wrapped, "/bin/bash", "linux")), "custom"), { "sudo", "-u", "explicit", "--", "ordinary-cli", "one" }, "explicit sudo wrapper is preserved rather than nested")
local remote_record = record("remote-render", { backend = "ssh-command", host = "example.test", user = "remote-user", key_path = "/keys/a key", cwd = "~/project 'quoted'", arguments = { "", "two words", "$HOME" } })
local remote_words = argv_of(assert(executor.render(remote_record, "/bin/bash", "linux")), "custom")
check(not remote_words[#remote_words]:find("SPAWN_PROVIDER", 1, true), "provider command name stays on the local outer line, never in the remote command")
local tricky = { "two words", "it's", 'say "hi"', "$HOME", "", "if", "done", "a=b", "plain-word_1.0,/x:y@z+%", "{", "!" }
local tricky_line = assert(executor.render(record("tricky", { provider = "Kimi Code!", command = "ordinary-cli", arguments = copy(tricky) }), "/bin/bash", "linux"))
local tricky_expected = { "ordinary-cli" }
for _, value in ipairs(tricky) do table.insert(tricky_expected, value) end
same(argv_of(tricky_line, "kimicode"), tricky_expected, "render/parse round trip preserves spaces, quotes, $, empty, reserved and simple words")
check(tricky_line:find(" if ", 1, true) == nil and tricky_line:find(" 'if' ", 1, true) ~= nil, "reserved words stay quoted")
same(argv_of(assert(executor.render(record("assign", { command = "FOO=bar", arguments = { "x" } }), "/bin/bash", "linux")), "custom"), { "FOO=bar", "x" }, "a command word with = is never an assignment")
same({ remote_words[1], remote_words[2], remote_words[3], remote_words[4], remote_words[5], remote_words[6] }, { "ssh", "-t", "-i", "/keys/a key", "--", "remote-user@example.test" }, "host SSH wrapper retains destination and key argument boundaries")
check(executor.render(ordinary_render, "/bin/fish", "linux") == nil, "unsupported host shell refuses invocation")
check(executor.render(native_record, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "windows") == nil, "unverified Windows native OMP launch refuses before prompt submission")
local windows_record = record("windows-render", { command = "C:\\Program Files\\Vendor\\tool.cmd", arguments = { "", "two words", "trailing\\", 'a"b', "%NAME%", "!literal!" } })
local windows_render = assert(executor.render(windows_record, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "windows"))
check(windows_render:find("C:\\Program Files\\Vendor\\tool.cmd", 1, true) ~= nil, "Windows executable path is literal rather than POSIX backslash parsing")
check(windows_render:find("SPAWN_PROVIDER", 1, true) == nil, "PowerShell launch lines never carry the POSIX provider command name")
local spawn_spec = { program = "/bin/bash", args = { "-l", "-c", "exit 125 # SPAWN:known" }, cwd = "/tmp", env = { TERN_EXE = "/owned/tern", TERN_PANE_SOCKET = "/owned/daemon.sock", TERN_WINDOW_KEY = "", TERN_PANE = "17" } }
local routed = assert(native.from_spawn(spawn_spec))
same(routed, { executable = "/owned/tern", socket = "/owned/daemon.sock", window = "", pane = 17 }, "fresh native routing uses only the exact host-issued spawn identities")
for _, change in ipairs({
	{ "TERN_EXE", "tern" }, { "TERN_PANE_SOCKET", "relative.sock" }, { "TERN_PANE", "0" },
	{ "TERN_PANE", "1.5" }, { "TERN_WINDOW_KEY", "bad\nwindow" }, { "TERN_EXE", "/owned/tern\nother" },
}) do
	local invalid_spec = copy(spawn_spec)
	invalid_spec.env[change[1]] = change[2]
	check(native.from_spawn(invalid_spec) == nil, "invalid fresh route is refused: " .. change[1] .. " " .. change[2])
end
check(native.from_spawn({ env = {} }) == nil, "missing native routing cannot borrow the VM's inherited pane")
local windows_spawn = copy(spawn_spec)
windows_spawn.env.TERN_EXE, windows_spawn.env.TERN_PANE_SOCKET = "C:\\Tern\\tern.com", "\\\\.\\pipe\\owned-tern"
check(native.from_spawn(windows_spawn) ~= nil, "fresh Windows console executable and named-pipe routing are accepted without PATH discovery")

local ticket = "exit 125 # SPAWN:exact-ticket"
for _, args in ipairs({ { "-c", ticket }, { "-l", "-c", ticket }, { "-NoLogo", "-Command", ticket } }) do
	check(executor.ticket_argument({ args = args }) == ticket, "ticket matching accepts native shell command shapes without a fixed arity")
end
for _, args in ipairs({ { "-c", ticket .. " extra" , ticket }, { ticket }, { "-c", "echo " .. ticket }, { "-c", ticket, "extra" } }) do
	check(executor.ticket_argument({ args = args }) == nil, "ticket matching refuses unrelated or ambiguous command arguments")
end
check(executor.render(record("controls", { arguments = { "control\3key" } }), "/bin/bash", "linux") == nil, "literal terminal control keys are refused before pane input")

-- Effect-boundary fixtures exercise the actual executor with deterministic
-- native observations and Authority persistence. They are not runtime evidence.
local executor_source = runtime.fs.read(root .. "/host_executor.luau")
local function execution_fixture(saved_job, options)
	options = options or {}
	local binding = { session_key = "host-A/session-4", authority_id = "authority-A", host_key = "host-A", native_session = 4 }
	local job = copy(saved_job or {
		id = "attempt-1", attempt_id = "attempt-1", native_session = 4, session_key = binding.session_key,
		ticket = ticket, stage = "admitted", pane_reused = false, admitted_at = os.time(),
		provider = "custom", account_label = "effect", backend = "local-terminal", placement = "tab", cwd = "~",
	})
	local approved = record("effect", { arguments = { "--exact", "two words" } })
	local fixture = { job = job, hooks = {}, timers = {}, writes = {}, probes = 0, claims = 0, changes = {}, active = options.active == true }
	local fake = { runtime = { os = "linux" }, json = runtime.json }
	fake.on = function(name, fn) fixture.hooks[name] = fn end
	fake.timer = function(ms, fn) table.insert(fixture.timers, { ms = ms, fn = fn }); return {} end
	local function response(value, callback)
		fixture.probes += 1
		callback({ status = 0, stdout = runtime.json.encode(value), stderr = "", timed_out = false }, nil)
	end
	local adapter = {
		from_spawn = native.from_spawn,
		epoch = function() return if options.other_epoch then "daemon-2" else "daemon-1" end,
		process_identity = function(pid) return "provider:" .. tostring(pid) end,
		inspect = function(window, opts, callback)
			check(window == "" and opts.route.socket == "/owned/daemon.sock", "execution observation uses its fresh bound native route")
			response({ sessions = { { id = if options.wrong_session then 5 else 4, tabs = { { id = 6, blocks = {
				{ id = 17, command = ticket, program = "/bin/bash", args = {}, live = true },
			} } } } } }, callback)
		end,
		wait_prompt = function(route, session, pane, _opts, callback)
			check(route.pane == 17 and session == 4 and pane == 17, "readiness never substitutes a Window SDK identity")
			response({ block = 17 }, callback)
		end,
		process = function(_route, _session, _pane, _opts, callback)
			response({ pane = 17, child = { pid = 10, name = "bash", argv = if options.name_only then {} else { "/bin/bash", "--rcfile", "/owned/kitty.bash" } }, foreground = { pid = if fixture.active then 20 else 10 } }, callback)
		end,
	}
	local authority = {}
	authority.execution_bindings = function() return { binding } end
	authority.ADMISSION_SECONDS = 30
	authority.execution_jobs = function() return { copy(job) } end
	authority.execution_record = function() if options.deny_record then return nil, "approval-revision-changed" end return copy(approved) end
	authority.execution_job = function(_binding, id) return if id == job.id then copy(job) else nil end
	authority.claim_execution = function(_binding, _id, info)
		fixture.claims += 1
		if options.deny_claim or job.stage ~= "admitted" then return nil, "claim-refused" end
		job.native, job.stage = copy(info), "claimed"
		return copy(job)
	end
	authority.update_execution = function(_binding, _id, expected, patch, observation)
		if expected ~= job.stage then return nil, "stage-race" end
		if patch.stage == "submission_intent" and options.deny_intent then return nil, "approval-revision-changed" end
		for name, value in pairs(patch) do job[name] = copy(value) end
		if observation ~= nil then job.observation = copy(observation) end
		return copy(job)
	end
	fake.pane = { write = function(pane, text)
		check(job.stage == "submission_intent" and job.command .. "\r" == text and pane == 17, "durable exact submission intent precedes every provider effect")
		table.insert(fixture.writes, text)
		if options.write_error then error("uncertain pane write") end
		fixture.active = true
		fixture.hooks.command_started({ pane = pane, line = job.command })
		if options.finish ~= nil then
			fixture.active = false
			fixture.hooks.command_finished({ pane = pane, line = job.command, status = options.finish })
		end
	end }
	local chunk = assert(loadstring(executor_source, "host-executor-effects"))
	setfenv(chunk, setmetatable({ tern = fake, require = function(name)
		if name == "./config" then return config end
		if name == "./native_cli" then return adapter end
		error("Unexpected executor dependency: " .. name)
	end }, { __index = environment }))
	local subject = chunk()
	if options.slow_store then
		for name, operation in pairs(authority) do
			if type(operation) == "function" then
				authority[name] = function(...)
					if fixture.filter_active then error("Native 50 ms filter deadline exceeded by storage") end
					return operation(...)
				end
			end
		end
	end
	subject.install(authority, function(_binding, err) table.insert(fixture.changes, err or "changed") end)
	fixture.drain = function()
		local turns = 0
		while true do
			local index = nil
			for position, pending in ipairs(fixture.timers) do if pending.ms <= 50 then index = position; break end end
			if index == nil then return end
			turns += 1
			assert(turns <= 32, "Executor startup callbacks must be bounded")
			table.remove(fixture.timers, index).fn()
		end
	end
	fixture.spawn = function()
		local spec = copy(spawn_spec)
		spec.args = { "-l", "-c", ticket }
		fixture.filter_active = true
		local result = fixture.hooks.spawn(spec)
		fixture.filter_active = false
		return result, spec
	end
	return fixture
end
local successful = execution_fixture()
successful.drain()
local expiry = nil
for _, pending in ipairs(successful.timers) do if pending.ms > 50 then expiry = pending end end
check(expiry ~= nil and expiry.ms >= 30000 and expiry.ms <= 31000, "a prepared ticket schedules its own expiry one second after the admission deadline")
local changes_before = #successful.changes
expiry.fn()
check(#successful.changes == changes_before + 1, "the expiry timer runs the reload path without any other refresh")
local filtered = successful.spawn()
check(filtered ~= nil and #filtered.args == 0 and filtered.program == "/bin/bash", "host filter preserves the actual shell and clears only its command arguments")
check(successful.spawn() == nil, "reentered ticket cannot allocate another execution")
successful.drain()
check(#successful.writes == 1 and successful.job.stage == "running" and successful.job.process_identity == "provider:20", "host submission occurs once and genuine start captures provider identity")
local active_saved = copy(successful.job)
successful.hooks.command_finished({ pane = 17, line = successful.job.command, status = 23 })
check(successful.job.stage == "completed" and successful.job.observation.phase == "Failed" and successful.job.observation.exit_status == 23, "actual nonzero host completion records failure")
successful.hooks.pane_exited({ pane = 17, status = 0 })
check(successful.job.stage == "completed" and successful.job.observation.exit_status == 23, "later retained-shell exit cannot erase provider completion")
successful.hooks.command_started({ pane = 17, line = "unrelated user command" })
check(successful.job.pane_reused and successful.job.stage == "completed", "pane reuse survives even after completion without resurrecting the provider")
local immediate_finish = execution_fixture(nil, { finish = 0 })
immediate_finish.drain(); immediate_finish.spawn(); immediate_finish.drain()
check(#immediate_finish.writes == 1 and immediate_finish.job.stage == "completed", "completion racing the post-write submitted update wins")
local name_only = execution_fixture(nil, { name_only = true, finish = 23 })
name_only.drain(); name_only.spawn(); name_only.drain()
check(#name_only.writes == 1 and name_only.job.stage == "completed" and name_only.job.observation.exit_status == 23, "native process name without argv permits the verified shell and preserves provider failure")
local refused_claim = execution_fixture(nil, { deny_claim = true })
refused_claim.drain()
refused_claim.spawn(); refused_claim.drain()
check(#refused_claim.writes == 0 and refused_claim.job.stage == "failed", "deferred claim refusal retains the shell without provider input")
local refused_intent = execution_fixture(nil, { deny_intent = true })
refused_intent.drain(); refused_intent.spawn(); refused_intent.drain()
check(#refused_intent.writes == 0 and refused_intent.job.stage == "failed", "approval fence refusal before durable intent blocks the provider effect")
local refused_record = execution_fixture(nil, { deny_record = true })
refused_record.drain(); refused_record.spawn(); refused_record.drain()
check(#refused_record.writes == 0 and refused_record.job.stage == "failed", "submission reads the approved record from current configuration and refuses when it changed")
local wrong_scope = execution_fixture(nil, { wrong_session = true })
wrong_scope.drain(); wrong_scope.spawn(); wrong_scope.drain()
check(#wrong_scope.writes == 0 and wrong_scope.job.stage == "failed", "native membership in another session is not an execution permission")
local reused_before_input = execution_fixture()
reused_before_input.drain(); reused_before_input.spawn()
reused_before_input.hooks.command_started({ pane = 17, line = "user command before submission" })
reused_before_input.drain()
check(#reused_before_input.writes == 0 and reused_before_input.job.stage == "failed" and reused_before_input.job.pane_reused, "a reused retained shell is refused before any provider input")
local uncertain_write = execution_fixture(nil, { write_error = true })
uncertain_write.drain(); uncertain_write.spawn(); uncertain_write.drain()
check(#uncertain_write.writes == 1 and uncertain_write.job.stage == "unknown", "an uncertain pane write remains blocking and is never repeated")
check(uncertain_write.spawn() == nil and #uncertain_write.writes == 1, "the old ticket cannot retry an uncertain submission")
local recovered_execution = execution_fixture(active_saved, { active = true })
recovered_execution.drain()
check(#recovered_execution.writes == 0 and recovered_execution.job.stage == "running", "same-epoch same-provider recovery only observes and never resends")
local different_epoch = execution_fixture(active_saved, { active = true, other_epoch = true })
different_epoch.drain()
different_epoch.hooks.command_started({ pane = 17, line = "command in a reused numeric pane alias" })
check(not different_epoch.job.pane_reused, "a stale daemon epoch cannot borrow a new pane's events")
recovered_execution.hooks.command_started({ pane = 17, line = recovered_execution.job.command })
recovered_execution.hooks.command_finished({ pane = 17, line = recovered_execution.job.command, status = 0 })
check(recovered_execution.job.pane_reused and recovered_execution.job.stage == "unknown", "a later identical manual command cannot supply the original provider's completion")
check(#different_epoch.writes == 0 and different_epoch.probes == 0 and different_epoch.job.stage == "unknown", "different daemon epoch refuses even an observational pane-identity guess")
local lost_completion = execution_fixture(active_saved)
lost_completion.drain()
check(#lost_completion.writes == 0 and lost_completion.job.stage == "unknown", "an idle retained shell after reload cannot invent successful provider completion")
local claimed_gap = copy(active_saved)
claimed_gap.stage, claimed_gap.epoch, claimed_gap.command, claimed_gap.process_identity = "claimed", nil, nil, nil
local recovered_gap = execution_fixture(claimed_gap)
recovered_gap.drain()
check(#recovered_gap.writes == 0 and recovered_gap.job.stage == "unknown", "claim-before-submission reload is observation-only rather than a deferred retry")
local slow_store = execution_fixture(nil, { slow_store = true })
slow_store.drain()
check(slow_store.spawn() ~= nil, "slow journal storage cannot trip the native spawn-filter deadline")
check(slow_store.spawn() == nil, "a pending deferred claim cannot be consumed twice")
slow_store.drain()
check(#slow_store.writes == 1 and slow_store.claims == 1 and slow_store.job.stage == "running", "deferred persistence admits exactly one provider invocation")

-- Real lifecycle mutations: no simulated launch results or wiring assertions.
local state = lifecycle.new()
local account = assert(config.validate_record(record("launch")))
local function reserve(target, item, scope, observer)
	local attempt, err = lifecycle.reserve(target, item, scope or "host-A/session-1", observer or "window-1")
	assert(attempt, tostring(err))
	return attempt
end
-- The host executor is the only observer; Launch advances the sequence itself.
local function observe(target, attempt, _sequence, observation)
	local ok, err = lifecycle.observe(target, attempt.id, observation)
	check(ok, "accept observation " .. observation.phase .. ": " .. tostring(err))
end
local function reject_observation(target, attempt, observer, sequence, observation, reason)
	local snapshot = copy(target)
	local ok, err = lifecycle.observe(target, attempt.id, observation)
	check(not ok and err == reason, "reject observation: " .. reason)
	same(target, snapshot, "rejected observation leaves all state unchanged: " .. reason)
end
local first = reserve(state, account)
check(first.phase == "Starting" and first.unresolved, "reservation is starting, not proof of execution")
local snapshot = copy(state)
local denied, why = lifecycle.reserve(state, account, first.scope, "window-2")
check(denied == nil and why == "skip", "another window cannot bypass account reservation")
same(state, snapshot, "duplicate skip allocates no ID or revision")
observe(state, first, 1, { phase = "Running", pane = 42 })
observe(state, first, 2, { phase = "Waiting for input" })
check(first.error_category == nil and first.unresolved, "waiting input is not fabricated authentication failure")
observe(state, first, 3, { phase = "Unknown" })
check(first.unresolved and lifecycle.reserve(state, account, first.scope, "window-2") == nil, "close or disconnect remains duplicate-blocking")
reject_observation(state, first, first.observer_id, 4, { phase = "Running", pane = 42, scope = "host-A/reused-session-alias" }, "scope-mismatch")
reject_observation(state, first, first.observer_id, 4, { phase = "Running", pane = 43 }, "pane-mismatch")
local recovered = assert(lifecycle.validate(copy(state)))
local recovered_first = recovered.attempts[1]
observe(recovered, recovered_first, 4, { phase = "Running", pane = 42, scope = first.scope })
check(recovered_first.phase == "Running" and recovered_first.unresolved, "same observer may reconnect with proven same pane membership")
local other_scope = reserve(recovered, account, "host-B/session-1", "window-1")
observe(recovered, other_scope, 1, { phase = "Running", pane = 42 })
check(other_scope.id ~= first.id, "same numeric pane alias on another host/session is independent")
observe(recovered, recovered_first, 5, { phase = "Exited", exit_status = 0 })
local batch = { recovered_first.id, recovered_first.id, { outcome = "Skipped", reason = "duplicate" }, { outcome = "Blocked", reason = "review" } }
local counts = lifecycle.aggregate(recovered, batch)
check(counts.Exited == 1 and counts.total == 3 and counts.Skipped == 1 and counts.Blocked == 1, "batch deduplicates attempts and distinguishes admission outcomes")
observe(recovered, recovered_first, 6, { phase = "Failed", exit_status = 23, error_category = "command-exit", diagnostic = "late failure" })
counts = lifecycle.aggregate(recovered, batch)
check(counts.Exited == 0 and counts.Failed == 1, "late failure corrects the existing batch result")
observe(recovered, recovered_first, 7, { phase = "Unknown" })
check(recovered_first.phase == "Failed" and recovered_first.exit_status == 23 and recovered_first.diagnostic == "late failure", "failed retained shell cannot erase provider failure on close")
reject_observation(recovered, recovered_first, recovered_first.observer_id, 8, { phase = "Running", pane = 42 }, "illegal-transition")
reject_observation(recovered, recovered_first, recovered_first.observer_id, 8, { phase = "Exited", exit_status = 0 }, "illegal-transition")
local replacement = reserve(recovered, account, first.scope, "window-2")
observe(recovered, replacement, 1, { phase = "Running", pane = 42 })
check(replacement.id ~= recovered_first.id, "new observer may reuse a terminal alias only as a new attempt")
local immediate = reserve(recovered, record("immediate"))
observe(recovered, immediate, 1, { phase = "Exited", exit_status = 127, diagnostic = "command unavailable" })
check(immediate.phase == "Failed" and immediate.error_category == "command-exit" and not immediate.unresolved, "nonzero immediate exit is failure, not successful submission")
local ssh = reserve(recovered, record("ssh", { backend = "ssh-command", host = "example" }))
observe(recovered, ssh, 1, { phase = "Exited", exit_status = 255 })
check(ssh.phase == "Failed" and ssh.error_category == "command-exit", "SSH 255 alone does not invent connectivity or authentication evidence")

-- Delayed completion supersedes connectivity uncertainty, not actual exit evidence.
for _, category in ipairs({ "host-unavailable", "host-mismatch" }) do
	for _, status in ipairs({ 0, 23 }) do
		local delayed_state = lifecycle.new()
		local delayed = reserve(delayed_state, record("delayed"))
		observe(delayed_state, delayed, 1, { phase = "Running", pane = 73 })
		observe(delayed_state, delayed, 2, { phase = "Unknown", error_category = category, diagnostic = "membership unavailable" })
		check(delayed.unresolved and delayed.error_category == category, "disconnect retains uncertain reservation")
		observe(delayed_state, delayed, 3, { phase = if status == 0 then "Exited" else "Failed", exit_status = status })
		check(delayed.phase == (if status == 0 then "Exited" else "Failed") and delayed.exit_status == status and not delayed.unresolved, "delayed completion releases reservation with actual status")
		check(delayed.error_category == (if status == 0 then nil else "command-exit"), "terminal evidence supersedes stale connectivity category")
		check(delayed.diagnostic == nil, "terminal evidence discards stale connectivity diagnostic")
		observe(delayed_state, delayed, 4, { phase = "Unknown", error_category = category, diagnostic = "membership lost again" })
		check(delayed.phase == (if status == 0 then "Exited" else "Failed") and delayed.exit_status == status and delayed.diagnostic == nil, "later disconnect preserves verified terminal evidence without connectivity diagnostic")
		check(delayed.error_category == (if status == 0 then nil else "command-exit") and not delayed.unresolved, "later disconnect cannot replace terminal category or reacquire reservation")
	end
end
local metadata_state = lifecycle.new()
local metadata = reserve(metadata_state, record("terminal-metadata"))
observe(metadata_state, metadata, 1, { phase = "Unknown", error_category = "host-unavailable", diagnostic = "old connectivity" })
observe(metadata_state, metadata, 2, { phase = "Failed", exit_status = 23, error_category = "permission-denied", diagnostic = "verified permission failure" })
check(metadata.error_category == "permission-denied" and metadata.diagnostic == "verified permission failure", "explicit terminal metadata replaces connectivity evidence")
observe(metadata_state, metadata, 3, { phase = "Failed" })
check(metadata.error_category == "permission-denied" and metadata.diagnostic == "verified permission failure" and metadata.exit_status == 23, "repeated failure without evidence retains meaningful terminal metadata")
observe(metadata_state, metadata, 4, { phase = "Failed", exit_status = 24 })
check(metadata.error_category == "command-exit" and metadata.exit_status == 24 and metadata.diagnostic == "verified permission failure", "new nonzero exit defaults category while retaining terminal diagnostic")
observe(metadata_state, metadata, 5, { phase = "Unknown", error_category = "host-mismatch", diagnostic = "later connectivity" })
check(metadata.error_category == "command-exit" and metadata.exit_status == 24 and metadata.diagnostic == "verified permission failure", "later unknown cannot overwrite retained terminal metadata")

local allowed = record("parallel", { duplicate_policy = "allow" })
local parallel_a = reserve(recovered, allowed)
local parallel_b = reserve(recovered, allowed)
check(parallel_a.id ~= parallel_b.id, "explicit duplicate allowance creates distinct attempts")
observe(recovered, parallel_a, 1, { phase = "Running", pane = 90 })
reject_observation(recovered, parallel_b, parallel_b.observer_id, 1, { phase = "Running", pane = 90 }, "pane-already-bound")
observe(recovered, parallel_b, 1, { phase = "Running", pane = 91 })
check(lifecycle.resolve(recovered, replacement.id), "explicit resolution releases uncertain attempt")
check(replacement.phase == "Unknown" and not replacement.unresolved and replacement.exit_status == nil, "resolution does not invent successful exit")
reject_observation(recovered, replacement, replacement.observer_id, 2, { phase = "Running", pane = 42 }, "resolved-attempt")
local revision = recovered.revision
check(lifecycle.resolve(recovered, replacement.id) and recovered.revision == revision, "repeated resolution is idempotent")
local next_id = recovered.next_attempt
local removed = lifecycle.clear_history(recovered)
check(removed == 4, "history clear removes only three terminal and one resolved attempts")
check(#recovered.attempts == 3 and recovered.attempts[1].id == other_scope.id and recovered.attempts[2].id == parallel_a.id and recovered.attempts[3].id == parallel_b.id, "clear preserves live attempts and original order")
check(recovered.next_attempt == next_id, "clear preserves ID continuity")
check(lifecycle.aggregate(recovered, { replacement.id }).missing == 1, "cleared result is missing, never successful")
local after_clear = reserve(recovered, account, first.scope, "window-2")
check(after_clear.id == "attempt-" .. tostring(next_id), "new reservation after clear never reuses old identity")
check(lifecycle.validate(recovered) == recovered, "mutated lifecycle remains a valid persisted value")
local unknown = reserve(recovered, record("unknown"))
observe(recovered, unknown, 1, { phase = "Unknown" })
check(lifecycle.clear_history(recovered) == 0 and unknown.unresolved, "clear cannot release unresolved unknown reservations")
check(lifecycle.reserve(recovered, record("disabled", { enabled = false }), first.scope, "window-1") == nil, "disabled account cannot reserve")
check(lifecycle.reserve(recovered, blocked, first.scope, "window-1") == nil, "review-required migration cannot reserve")
check(reserve(recovered, record("explicit-only", { include_all = false })).phase == "Starting", "batch exclusion does not prohibit explicit launch")
local full_state = lifecycle.new()
for index = 1, 128 do reserve(full_state, record("capacity-" .. tostring(index))) end
snapshot = copy(full_state)
local overflow, capacity = lifecycle.reserve(full_state, record("overflow"), first.scope, "window-1")
check(overflow == nil and capacity == "capacity", "full history refuses rather than evicting reservations")
same(full_state, snapshot, "capacity refusal preserves all history")
for _, invalid in ipairs({ { version = 99, next_attempt = 1, revision = 0, attempts = {} }, { version = 1, next_attempt = 1, revision = 0, attempts = { [2] = copy(first) } } }) do
	local preserved = copy(invalid)
	check(lifecycle.validate(invalid) == nil, "future or corrupt lifecycle refuses reset")
	same(invalid, preserved, "invalid persisted lifecycle stays untouched")
end
return "PASS " .. tostring(checks) .. " SPAWN behavior checks"
