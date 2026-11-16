-- Behavior tests use the native JSON decoder, including its null/array semantics.
-- No host, window, storage, launch or confirmation effects are available to Review.
local root = ...
assert(type(root) == "string", "pass the package directory")
local runtime, environment = tern, getfenv()
local checks = 0
local function check(ok, message) assert(ok, message); checks += 1 end
local function equal(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end
local function load(name, dependencies, fixture_runtime)
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ tern = fixture_runtime or {}, require = function(path)
		assert(dependencies and dependencies[path], "unexpected dependency: " .. path)
		return dependencies[path]
	end }, { __index = environment }))
	return chunk()
end
local Config = load("config")
local Backend = load("backend", { ["./config"] = Config, ["./launch_resolution"] = load("launch_resolution", { ["./config"] = Config }) })
local Review = load("setup_review", { ["./config"] = Config })
local function record(id)
	return { id = id or "account", provider = "Example", backend = "local-terminal", command = "example" }
end
local function result(records, run)
	return { schema = 2, setup_run_id = run or "run-1", confirmed = true, agents = records or { record() } }
end
local function native(value) return runtime.json.decode(runtime.json.encode(value)) end
local function refused(value, run, message)
	local ok, review, reason = pcall(Review.prepare, value, if run == nil then "run-1" else run)
	check(ok and review == nil and type(reason) == "string" and #reason > 0, message)
end
local function accepted(value, run)
	local review, reason = Review.prepare(value, run or "run-1")
	check(review ~= nil and reason == nil, "valid result produces a review")
	check(review.setup_run_id == (run or "run-1"), "review retains the exact run")
	check(equal(review.records, assert(Config.validate_records(value.agents))), "Config alone defines normalized records")
	return review
end
local function fields(row)
	local found = {}
	for _, item in ipairs(row.fields) do
		check(type(item.label) == "string" and item.label ~= "" and type(item.value) == "string", "review fields are native readable text")
		check(found[item.label] == nil, "field labels uniquely identify their values")
		found[item.label] = item.value
	end
	return found
end

-- Wrong shapes and exact schema/run/confirmation requirements, not JSON wording snapshots.
for _, bytes in ipairs({ "null", "false", "true", "2", '"result"', "[]", "{}", '[{"schema":2}]' }) do
	refused(runtime.json.decode(bytes), nil, "non-envelope JSON refuses: " .. bytes)
end
for _, key in ipairs({ "schema", "setup_run_id", "confirmed", "agents" }) do
	local missing = result(); missing[key] = nil
	refused(native(missing), nil, "missing required envelope member refuses: " .. key)
	local explicit_null = result(); explicit_null[key] = runtime.json.null
	refused(native(explicit_null), nil, "native object null cannot satisfy a required member: " .. key)
end
for _, schema in ipairs({ 1, 3, "2", false, {} }) do
	local value = result(); value.schema = schema
	refused(native(value), nil, "schema must be numeric 2")
end
for _, confirmed in ipairs({ false, "true", 1, {} }) do
	local value = result(); value.confirmed = confirmed
	refused(native(value), nil, "confirmation must be literal true")
end
for _, run in ipairs({ "", "   ", "run-2", "run-1 ", "RUN-1", "run\n1", string.rep("r", 257), false, 1, {} }) do
	local value = result(); value.setup_run_id = run
	refused(native(value), nil, "invalid or nonidentical returned run refuses")
end
for _, run in ipairs({ "", " ", "run\n1", string.rep("r", 257), false, 1, {} }) do
	refused(native(result()), run, "invalid expected run refuses")
end
local no_expected, no_expected_reason = Review.prepare(native(result()), nil)
check(no_expected == nil and type(no_expected_reason) == "string", "missing expected run is not inferred from the result")
local maximum_run = string.rep("r", 256)
accepted(native(result(nil, maximum_run)), maximum_run)
accepted(native(result(nil, "run-雪")), "run-雪")
local extra = result(); extra.extra = true
refused(native(extra), nil, "unknown envelope fields refuse")
extra.extra = runtime.json.null
accepted(native(extra)) -- Native object null members are dropped before this pure boundary.
local numeric_key = result(); numeric_key[1] = "unexpected"
refused(numeric_key, nil, "mixed array/object envelope refuses")

-- Native null array elements survive decoding; objects with numeric-looking keys are not arrays.
for _, bytes in ipairs({ "null", "false", '"agents"', "[null]", "[[]]", '[{"id":null}]', '{"1":{}}' }) do
	local value = runtime.json.decode('{"schema":2,"setup_run_id":"run-1","confirmed":true,"agents":' .. bytes .. '}')
	refused(value, nil, "invalid native record collection refuses: " .. bytes)
end
for _, bytes in ipairs({ "[]", "{}" }) do
	local value = runtime.json.decode('{"schema":2,"setup_run_id":"run-1","confirmed":true,"agents":' .. bytes .. '}')
	local review = accepted(value)
	check(#review.records == 0 and #review.rows == 0, "empty collection follows Config normalization without inventing records")
end
local full = {}
for index = 1, 32 do full[index] = record("account-" .. tostring(index)) end
local maximum = accepted(native(result(full)))
check(#maximum.records == 32 and #maximum.rows == 32, "all 32 records are reviewed in submitted order")
for index, row in ipairs(maximum.rows) do check(row.id == full[index].id, "row identity follows record order") end
full[33] = record("account-33")
refused(native(result(full)), nil, "33 records refuse the whole result")
refused(native(result({ record("same"), record("same") })), nil, "identical duplicate IDs refuse within one result")
local divergent = record("same"); divergent.command = "different"
refused(native(result({ record("same"), divergent })), nil, "divergent duplicate IDs refuse without suffix IDs")
local sparse = result(); sparse.agents = { [1] = record(), [3] = record("third") }
refused(sparse, nil, "sparse input cannot silently omit a record")
local invalid_later = record("second"); invalid_later.backend = "unknown"
refused(native(result({ record(), invalid_later })), nil, "invalid later record refuses all records")

-- Exercise full Config validation, not a parallel subset of the record schema.
for _, pair in ipairs({
	{ "unknown", true }, { "env", { KEY = "value" } }, { "enabled", "yes" },
	{ "provider_family", "invalid\nfamily" }, { "arguments", "--profile work" }, { "arguments", { false } },
	{ "placement", "unknown" }, { "mailbox", { unknown = true } },
	{ "fresh_executable", "fresh-only" }, { "capacity_limit", 0 },
	{ "argv_contract", "unknown" }, { "review_reason", "unblocked reason" },
}) do
	local bad = record(); bad[pair[1]] = pair[2]
	refused(native(result({ bad })), nil, "invalid record field refuses through Config: " .. pair[1])
end
local null_arg = record(); null_arg.arguments = runtime.json.decode('["first",null,"last"]')
refused(result({ null_arg }), nil, "native null argv item cannot be dropped or stringified")
local optional_null = record(); optional_null.cwd = runtime.json.null; optional_null.enabled = runtime.json.null
local normalized_null = accepted(native(result({ optional_null })))
check(normalized_null.records[1].cwd == nil and normalized_null.records[1].enabled == true,
	"native null object fields follow Config absence/default semantics")
local empty_object_argv = record(); empty_object_argv.arguments = runtime.json.decode("{}")
check(#accepted(result({ empty_object_argv })).records[1].arguments == 0, "empty argv object follows existing Config array normalization")

-- Every normalized field, nested declaration and argv item is visible independently.
local detailed = {
	id = "complete", provider = "OMP", account_label = "Work 雪", backend = "ssh-command",
	enabled = false, placement = "split", command = "env OMP_PROFILE=work omp",
	arguments = { "--profile", "work space", "", "line one\nline two", "{literal:not-json}", "PATH=/exact/env" },
	cwd = "/work space", prompt = "Keep every line.\nSecond line.", host = "worker.example", user = "operator",
	key_path = "/keys/work key", review_required = true, review_reason = "Inspect remote account",
	fresh_executable = "/tools/fresh", fresh_arguments = { "--task", "", "literal $HOME" }, fresh_native_default = false,
	task_argument_index = 3, host_shell = "sh", target_os = "windows", target_shell = "powershell",
	argv_contract = "windows-crt", model = "model-a", profile = "profile-a", variant_id = "variant-a",
	capacity_binding = "capacity-a", capacity_limit = 2, selector_evidence = "declared selector evidence",
	mailbox = { permitted_root = "/mailbox", helper_path = "/tools/helper", producer_helper_path = "/tools/producer",
		worker_identity = "worker-a", evidence_ref = "evidence-a", verified = false, wake = "worker-poll-v1",
		producer = { read = true, write = false, hash = true, journal = false, poll = true },
		capabilities = { "argv-v1", "report-files-v1", "worker-poll-v1", "native-ask-v1", "coordinator-control-v1", "check-runner-v1", "release-manager-v1" } },
}
local source = native(result({ detailed }))
local before = native(source)
local review = accepted(source)
check(equal(source, before), "preparation never mutates decoded input")
check(review.rows[1].id == detailed.id and review.rows[1].label == detailed.account_label, "row identity and account label remain readable")
local displayed = fields(review.rows[1])
for _, pair in ipairs({
	{ "Record ID", detailed.id }, { "Provider", detailed.provider }, { "Account", detailed.account_label },
	{ "Backend", detailed.backend }, { "Enabled", "false" },
	{ "Placement", detailed.placement }, { "Command", detailed.command }, { "Working directory", detailed.cwd },
	{ "Prompt", detailed.prompt }, { "SSH host", detailed.host }, { "SSH user", detailed.user }, { "SSH key path", detailed.key_path },
	{ "Review required", "true" }, { "Review reason", detailed.review_reason },
	{ "Fresh executable", detailed.fresh_executable }, { "Fresh native default", "false" }, { "Task argument index", "3" },
	{ "Host shell", detailed.host_shell }, { "Target OS", detailed.target_os }, { "Target shell", detailed.target_shell },
	{ "Argument contract", detailed.argv_contract }, { "Model", detailed.model }, { "Profile", detailed.profile },
	{ "Variant ID", detailed.variant_id }, { "Capacity binding", detailed.capacity_binding }, { "Capacity limit", "2" },
	{ "Selector evidence", detailed.selector_evidence }, { "Mailbox permitted root", detailed.mailbox.permitted_root },
	{ "Mailbox helper path", detailed.mailbox.helper_path }, { "Mailbox producer helper path", detailed.mailbox.producer_helper_path },
	{ "Mailbox worker identity", detailed.mailbox.worker_identity }, { "Mailbox evidence reference", detailed.mailbox.evidence_ref },
	{ "Mailbox verified", "false" }, { "Mailbox wake route", detailed.mailbox.wake },
}) do check(displayed[pair[1]] == pair[2], "configured field is complete readable text: " .. pair[1]) end
for _, item in ipairs({ { "Arguments", detailed.arguments }, { "Fresh arguments", detailed.fresh_arguments }, { "Mailbox capabilities", detailed.mailbox.capabilities } }) do
	for index, value in ipairs(item[2]) do
		local shown = displayed[item[1] .. " [" .. tostring(index) .. "]"]
		check(shown == (if value == "" then "(empty string)" else value), "each ordered list element is independently readable")
	end
end
for name, value in pairs(detailed.mailbox.producer) do
	check(displayed["Mailbox producer " .. name] == tostring(value), "producer boolean claims preserve false as well as true")
end
local reordered = {}
local keys = {}; for key in pairs(detailed) do table.insert(keys, key) end; table.sort(keys)
for index = #keys, 1, -1 do reordered[keys[index]] = detailed[keys[index]] end
check(equal(accepted(native(result({ reordered }))).rows, review.rows), "object key insertion order never changes readable field order")
source.agents[1].arguments[1] = "changed"
source.agents[1].mailbox.producer.read = false
check(review.records[1].arguments[1] == "--profile" and review.records[1].mailbox.producer.read == true,
	"normalized review owns its nested records rather than mutable input references")
local changed_review = accepted(source)
check(not equal(changed_review.records, review.records) and not equal(changed_review.rows, review.rows),
	"preparation reflects changed content; caller must compare immutable bytes at confirmation")

local defaults = record(); defaults.duplicate_policy = "retired"; defaults.account_label = ""; defaults.cwd = ""
local default_review = accepted(native(result({ defaults })))
local default_fields = fields(default_review.rows[1])
check(default_fields.Account == defaults.provider and default_fields.Enabled == "true" and default_fields.Placement == "tab",
	"review displays Config defaults rather than unnormalized submitted values")
check(default_fields.Arguments == "None" and default_fields["Working directory"] == nil and default_review.records[1].duplicate_policy == nil,
	"empty argv is explicit and retired/empty optional fields stay absent after normalization")
local empty_nested = record(); empty_nested.fresh_executable = "/fresh"; empty_nested.fresh_arguments = {}
empty_nested.mailbox = { producer = {}, capabilities = {} }
local empty_fields = fields(accepted(native(result({ empty_nested }))).rows[1])
check(empty_fields["Fresh arguments"] == "None" and empty_fields.Mailbox == "Configured"
	and empty_fields["Mailbox producer"] == "Configured" and empty_fields["Mailbox capabilities"] == "None",
	"configured empty nested declarations remain visible")
local native_default = record(); native_default.provider = "OMP"; native_default.backend = "native-agent"; native_default.command = "omp"; native_default.fresh_native_default = true
check(fields(accepted(native(result({ native_default }))).rows[1])["Fresh native default"] == "true", "native fresh-default configuration is readable without changing backend meaning")
local many_args = record(); many_args.arguments = {}
for index = 1, 256 do many_args.arguments[index] = "argument-" .. tostring(index) end
many_args.prompt = string.rep("p", 32000)
local many = accepted(native(result({ many_args })))
local many_fields = fields(many.rows[1])
check(many_fields["Arguments [256]"] == "argument-256" and many_fields.Prompt == many_args.prompt,
	"maximum argv and optional text are complete, never truncated for review")
many_args.arguments[257] = "too-many"
refused(native(result({ many_args })), nil, "argument count remains Config's limit")

-- Managed adoption regressions use isolated effects, never real resources or providers.
do
	local identity_calls = 0
	local terminal_help = ""
	local fake = {
		runtime = { os = "linux" }, plugin = { dir = "/fixture/package", data = "/fixture/data" },
		fs = { read = function() return "fixture helper bytes" end },
		timer = function(_, callback) callback() end, now = function() return 1 end,
	}
	local digest = string.rep("a", 64)
	local Setup = load("managed_setup", {
		["./config"] = Config,
		["./wire/codec"] = {
			sha256 = function() return digest end, sha256_begin = function() return {} end,
			sha256_feed = function() end, sha256_step = function() return true end,
			sha256_digest = function() return digest end,
		},
		["./backend"] = Backend, ["./native_cli"] = {},
		["./mailbox_adapter"] = { absolute_path = function(path) return type(path) == "string" and path:sub(1, 1) == "/" end },
		["./prereq"] = {
			identity = function(_, done) identity_calls += 1; done("fixture-user", nil) end,
			account = function(user, _, _, done) identity_calls += 1; done({identity=user,home="/fixture/selected-home",executable="/fixture/selected-home/.local/bin/omp"},nil) end,
			as_user = function(argv) return argv end,
			run = function(argv, stdin, done) done(if argv[#argv] == "--help" then terminal_help else stdin or "", nil) end,
			probe = function(_, _, done) done({ passed = false, observations = {} }) end,
		},
	}, fake)
	local saved = assert(Config.validate_record({
		id = "native-default", provider = "OMP", backend = "native-agent",
		command = "/tools/omp", arguments = { "--resume", "ordinary-session" },
		fresh_native_default = true, cwd = "/fixture/repository", host = "remote.example",
		key_path = "/fixture/key",
	}))
	local draft = Setup.from_record(saved)
	check(Setup.defaults(nil).cwd == "", "missing working folder remains an empty draft rather than an absolute path")
	check(draft.executable == "omp" and draft.arguments == "", "native fresh default never inherits ordinary executable or resume arguments")
	draft.root = "/fixture/mailbox"
	local prepared, probe, problem
	Setup.prepare(draft, { host_os = "linux", host_shell = "sh" }, function(value, result, why)
		prepared, probe, problem = value, result, why
	end)
	check(prepared ~= nil and problem == nil and probe.passed == false, "isolated preparation retains unsuccessful probe evidence")
	check(prepared.fresh_executable == "omp" and #prepared.fresh_arguments == 0, "native default becomes the same explicit fresh argv contract")
	check(prepared.command == saved.command and equal(prepared.arguments, saved.arguments), "adoption preserves ordinary resume separately")
	check(prepared.host == saved.host and prepared.key_path == saved.key_path and prepared.user == saved.user,
		"same-user adoption preserves execution-host binding and account metadata")
	check(prepared.mailbox.verified == false and saved.mailbox == nil, "preparation neither attests nor changes the saved record")
	check(table.find(prepared.mailbox.capabilities, "project-start-v1") ~= nil
		and table.find(prepared.mailbox.capabilities, "coordinator-control-v1") ~= nil,
		"fresh verified helper bundle preparation explicitly declares typed project start support")
	local Capabilities = load("mailbox_capabilities", {
		["./backend"] = {
			eligibility = function() return { fresh = true, input = true, target = true } end,
			shell_kind = function() return "posix" end,
		},
		["./bridge_protocol"] = { text = function(value, limit)
			return type(value) == "string" and #value > 0 and #value <= limit
		end },
	})
	check(Capabilities.valid_set("native-agent", "native-ask-v1", prepared.mailbox.capabilities),
		"fresh native helper capability set includes negotiated project start")
	local legacy_caps = { "report-files-v1", "native-ask-v1", "coordinator-control-v1" }
	check(Capabilities.valid_set("native-agent", "native-ask-v1", legacy_caps)
		and table.find(legacy_caps, "project-start-v1") == nil,
		"existing coordinator bundles remain usable without advertising typed project start")
	check(not Capabilities.valid_set("native-agent", "native-ask-v1",
		{ "report-files-v1", "native-ask-v1", "project-start-v1" }),
		"project start cannot be declared without coordinator control")
	local eligible, _, reasons = Capabilities.eligibility(prepared, {
		host_os = "linux", host_shell = "sh", host_key = "host:local.example",
	})
	check(not eligible and table.find(reasons, "Configured execution host differs from canonical host authority") ~= nil,
		"adopted remote host binding remains subject to the unchanged authority eligibility guard")
	for _, selector in ipairs({ "model", "profile" }) do
		local invalid = native(saved); invalid[selector] = "selected"
		local invalid_draft = Setup.from_record(invalid); invalid_draft.root = draft.root
		local calls = identity_calls
		Setup.prepare(invalid_draft, { host_os = "linux", host_shell = "sh" }, function(value, _, why)
			check(value == nil and type(why) == "string" and why:find("explicit fresh", 1, true),
				"unsupported default with selector requires explicit fresh-contract review")
		end)
		check(identity_calls == calls, "unsupported fresh-default selectors refuse before resource effects")
	end
	local explicit = native(saved); explicit.fresh_native_default = nil
	explicit.fresh_executable = "/tools/fresh-omp"; explicit.fresh_arguments = { "--model", "selected" }
	explicit.model = "selected"
	local explicit_draft = Setup.from_record(explicit)
	check(explicit_draft.executable == explicit.fresh_executable
		and equal(assert(Config.parse_arguments(explicit_draft.arguments)), explicit.fresh_arguments),
		"explicit fresh executable and selector arguments remain unchanged")
	local cross_user=native(saved);cross_user.user="fixture-user"
	local cross_user_draft=Setup.from_record(cross_user);cross_user_draft.root=draft.root
	local calls=identity_calls
	Setup.prepare(cross_user_draft,{host_os="linux",host_shell="sh"},function(value,_,why)
		check(value~=nil and why==nil and value.user=="fixture-user" and value.id==saved.id,
			"authorized existing account preparation retains exact account and stable record identity")
		check(value.fresh_executable=="/fixture/selected-home/.local/bin/omp" and value.mailbox.permitted_root==draft.root,
			"selected account uses observed executable and preserves explicit mailbox root")
	end)
	check(identity_calls==calls+1 and cross_user.user=="fixture-user" and cross_user.mailbox==nil,
		"account preparation observes selected access without mutating the saved record")
	local ssh = assert(Config.validate_record({
		id = "terminal-seat", provider = "Example", account_label = "Work", backend = "ssh-command",
		command = "/tools/agent", arguments = { "--yolo" }, cwd = "/fixture/repository",
		host = "127.0.0.1", key_path = "/fixture/ssh-key", user = "fixture-user",
	}))
	local local_draft = Setup.from_record(ssh)
	local_draft.backend = "local-terminal"; local_draft.root = draft.root
	local converted, conversion_error
	Setup.prepare(local_draft, { host_os = "linux", host_shell = "sh" }, function(value, _, why)
		converted, conversion_error = value, why
	end)
	check(converted ~= nil and conversion_error == nil, "explicit SSH-to-local conversion prepares the selected existing account")
	check(converted.id == ssh.id and converted.user == ssh.user and converted.cwd == ssh.cwd
		and converted.command == ssh.command and equal(converted.arguments, ssh.arguments)
		and equal(converted.fresh_arguments, ssh.arguments),
		"SSH-to-local conversion retains agent identity, account, folder and permission arguments")
	local verified = table.clone(converted); verified.mailbox = table.clone(converted.mailbox)
	verified.mailbox.verified = true; verified.mailbox.evidence_ref = "fixture:verified-helper-route"
	verified.mailbox.producer = { read = true, write = true, hash = true, journal = true, poll = true }
	local local_eligible, _, local_reasons = Capabilities.eligibility(verified, {
		host_os = "linux", host_shell = "sh", host_key = "host:local.example",
	})
	check(local_eligible and #local_reasons == 0,
		"verified local conversion is eligible on its actual host rather than rejected by the obsolete SSH destination")
	check(ssh.backend == "ssh-command" and ssh.host == "127.0.0.1" and ssh.key_path == "/fixture/ssh-key",
		"preparation leaves the saved SSH record unchanged until normal verified adoption")
	local disabled = table.clone(ssh)
	disabled.enabled = false; disabled.prompt = "Existing ordinary-session instructions"
	disabled.review_required = true; disabled.review_reason = "Independent CLI review"
	local disabled_draft = Setup.from_record(disabled)
	disabled_draft.backend = "local-terminal"; disabled_draft.root = draft.root
	Setup.prepare(disabled_draft, { host_os = "linux", host_shell = "sh" }, function(value, _, why)
		check(value ~= nil and why == nil and value.enabled == false and value.prompt == disabled.prompt
			and value.review_required == true and value.review_reason == disabled.review_reason,
			"preparation neither re-enables a disabled agent nor drops ordinary instructions or an unresolved review gate")
	end)
	local function terminal_variant(arguments, slot, help, create)
		terminal_help = help
		local variant = Setup.from_record(ssh); variant.backend = "local-terminal"; variant.root = draft.root
		variant.arguments = Config.render_arguments(arguments); variant.task_argument_index = tostring(slot)
		if create then variant.source_record = nil end
		local value, problem
		Setup.prepare(variant, { host_os = "linux", host_shell = "sh" }, function(record, _, why) value, problem = record, why end)
		return assert(value, problem)
	end
	local interactive_help = "Usage: custom-cli\n  --prompt-interactive  Run an initial message interactively and keep the session open\n"
	local interactive = terminal_variant({ "--yolo" }, 2, interactive_help)
	check(equal(interactive.fresh_arguments, { "--yolo", "--prompt-interactive" }) and interactive.task_argument_index == 3
		and equal(interactive.arguments, ssh.arguments) and interactive.user == ssh.user,
		"observed named interactive input replaces inferred positional delivery without changing ordinary permissions or account")
	local created = terminal_variant({ "--yolo" }, 2, interactive_help, true)
	check(equal(created.arguments, { "--yolo" }) and equal(created.fresh_arguments, interactive.fresh_arguments)
		and created.task_argument_index == 3,
		"a new agent keeps standalone startup usable while fresh task delivery uses its declared named input")
	for _, mode in ipairs({ "--", "--prompt-interactive", "-i", "--print", "-p", "--prompt", "--prompt-interactive=selected" }) do
		local arguments = { "--yolo", mode }
		local explicit_mode = terminal_variant(arguments, 3, interactive_help)
		check(equal(explicit_mode.fresh_arguments, arguments) and explicit_mode.task_argument_index == 3,
			"an explicit input mode or end-of-options separator is retained rather than duplicated or relocated")
	end
	local positioned = terminal_variant({ "--yolo" }, 1, interactive_help)
	check(equal(positioned.fresh_arguments, { "--yolo" }) and positioned.task_argument_index == 1,
		"a non-final custom task position is not silently moved by help discovery")
	for _, help in ipairs({ "", "Example: use --prompt-interactive for interactive input\n", "  --prompt-interactive-mode  A different option\n" }) do
		local unrelated = terminal_variant({ "--yolo" }, 2, help)
		check(equal(unrelated.fresh_arguments, { "--yolo" }) and unrelated.task_argument_index == 2,
			"unavailable help, prose mentions and different option names do not invent a launch flag")
	end
	local alias = terminal_variant({ "--yolo" }, 2, "  -i, --prompt-interactive MESSAGE  Interactive message\n")
	check(equal(alias.fresh_arguments, interactive.fresh_arguments) and alias.task_argument_index == interactive.task_argument_index,
		"a declared short-and-long option row supports the same named interactive input contract")
end
-- SKILLS-194: the helper's approval is the only approval. The pure plan decides
-- what SPAWN does automatically once a bound result is submitted.
do
	local terminal_a, terminal_b = record("term-a"), record("term-b")
	local plan = Review.automatic_plan(accepted(native(result({ terminal_a, terminal_b }))).records)
	check(type(plan) == "table" and plan.action == "prepare" and plan.enabled == 2 and #plan.native == 0 and plan.reason == nil,
		"an approved terminal roster is saved and prepared automatically with no model-credit scope")
	local omp = record("omp-a"); omp.provider = "OMP"; omp.backend = "native-agent"; omp.command = "omp"; omp.prompt = "Begin."
	local native_plan = Review.automatic_plan(accepted(native(result({ terminal_a, omp }))).records)
	check(native_plan.action == "prepare" and native_plan.enabled == 2 and #native_plan.native == 1 and native_plan.native[1]:find("OMP", 1, true) ~= nil,
		"native accounts are named so the toast repeats the scope the helper disclosed")
	local disabled = record("off"); disabled.enabled = false
	local none = Review.automatic_plan(accepted(native(result({ disabled }))).records)
	check(none.action == "save_only" and none.enabled == 0 and type(none.reason) == "string", "a roster with nothing enabled is saved without preparation and says why")
	local ssh = record("remote"); ssh.backend = "ssh-command"; ssh.host = "example.test"; ssh.user = "u"
	local remote = Review.automatic_plan(accepted(native(result({ terminal_a, ssh }))).records)
	check(remote.action == "save_only" and remote.reason:find("review", 1, true) ~= nil,
		"an SSH route is saved, never prepared automatically, and the reason names the review it needs")
	check(Review.automatic_plan({}).action == "save_only", "an empty roster never prepares")
end
return "PASS setup_review " .. tostring(checks)
