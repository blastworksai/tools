-- Pure fixtures; parent runs this in Tern with the package root argument.
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
local Backend, Config = load("backend"), load("config")
local Resolution, Executor = load("launch_resolution"), load("host_executor")
local checks = 0
local function check(condition, message) assert(condition, message); checks += 1 end
local function same(left, right, message) check(left == right, message) end
local function record(fields)
	local result = { id = "worker", provider = "custom", backend = "local-terminal", command = "worker", arguments = {} }
	for key, value in pairs(fields or {}) do result[key] = value end
	return result
end
local host = { host_os = "linux", host_shell = "/bin/bash" }
local task = "  exact ' \" $HOME `tick` $(literal); & | %PATH% !bang! \\ 雪 😀\nnext line  "
local function managed(fields)
	return record(fields or { fresh_executable = "/tools/worker", fresh_arguments = { "--task" }, task_argument_index = 2 })
end
local function options(fields)
	local result = { fresh = true, prompt = task, cwd = "/work/a ' directory", placement = "split" }
	for key, value in pairs(fields or {}) do result[key] = value end
	return result
end
same(Backend.posix_quote("a'b"), "'a'\\''b'", "POSIX quote closes and reopens literals")
same(Backend.posix_quote(""), "''", "empty POSIX argv survives")
same(Backend.windows_argument(""), '""', "empty CRT argv survives")
same(Backend.windows_argument('a"b'), '"a\\"b"', "CRT quotes are escaped")
same(Backend.windows_argument("a\\"), '"a\\\\"', "CRT trailing backslash doubles")
same(Backend.windows_argument('a\\"b'), '"a\\\\\\"b"', "CRT backslashes before quotes double plus one")
same(Backend.utf16le("A雪😀"), string.char(65, 0, 234, 150, 61, 216, 0, 222), "UTF16LE includes surrogate pairs, not UTF8 bytes")
check(Backend.utf16le(string.char(255)) == nil, "UTF16 rejects malformed UTF8")
same(Backend.base64(""), "", "Base64 empty")
same(Backend.base64("f"), "Zg==", "Base64 one byte")
same(Backend.base64("fo"), "Zm8=", "Base64 two bytes")
same(Backend.base64("foo"), "Zm9v", "Base64 three bytes")
local args = { "", task, "ending\\", "--resume", "literal" }
local command = assert(Backend.serialize("/a worker", args, "/work's", "linux", "sh"))
local expected = "cd -- " .. Backend.posix_quote("/work's") .. " && " .. Backend.posix_quote("/a worker")
for _, arg in ipairs(args) do expected ..= " " .. Backend.posix_quote(arg) end
same(command, expected, "POSIX every argv and cwd remains literal")
check(Backend.serialize("worker", { string.rep("x", 32768) }, nil, "linux", "sh") == nil, "POSIX limit includes executable and quoting")
check(Backend.serialize("worker", { "bad\0value" }, nil, "linux", "sh") == nil, "NUL argv rejects")
check(Backend.serialize("worker", { [1] = "one", [3] = "gap" }, nil, "linux", "sh") == nil, "sparse argv rejects")
check(Backend.serialize("worker", {}, nil, "linux", "fish") == nil, "unverified shell rejects")
check(Backend.serialize("worker", {}, nil, "unknown", "sh") == nil, "unknown OS rejects")
local windows = assert(Backend.serialize("C:\\Tools\\worker.exe", { task, "" }, "C:\\work", "windows", "powershell.exe"))
check(windows:match("^powershell.exe %-NoLogo %-NoProfile %-EncodedCommand [A-Za-z0-9+/=]+$") ~= nil, "Windows outer command is encoded data only")
check(not windows:find(task, 1, true), "literal task never enters outer PowerShell code")
check(#windows <= 7000, "encoded Windows command is bounded")
local function decode64(value)
	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local result = {}
	for index = 1, #value, 4 do
		local n = 0
		for offset = 0, 3 do
			local char = value:sub(index + offset, index + offset)
			n = n * 64 + (if char == "=" then 0 else assert(alphabet:find(char, 1, true)) - 1)
		end
		table.insert(result, string.char(math.floor(n / 65536)))
		if value:sub(index + 2, index + 2) ~= "=" then table.insert(result, string.char(math.floor(n / 256) % 256)) end
		if value:sub(index + 3, index + 3) ~= "=" then table.insert(result, string.char(n % 256)) end
	end
	return table.concat(result)
end
local wide = decode64(assert(windows:match("EncodedCommand ([A-Za-z0-9+/=]+)$")))
local ascii = {}
for index = 1, #wide, 2 do
	same(wide:byte(index + 1), 0, "fixed ASCII wrapper has UTF16LE high zero bytes")
	table.insert(ascii, wide:sub(index, index))
end
local wrapper = table.concat(ascii)
local payload = assert(wrapper:match("FromBase64String%('([A-Za-z0-9+/=]+)'%)"))
local decoded = runtime.json.decode(decode64(payload))
same(decoded.executable, "C:\\Tools\\worker.exe", "Windows executable is separate JSON data")
same(decoded.cwd, "C:\\work", "Windows exact cwd is separate JSON data")
same(decoded.arguments, Backend.windows_argument(task) .. ' ""', "Windows native CRT argv preserves the entire literal task and empty arg")
check(Backend.serialize("worker.exe", { string.rep("x", 7000) }, nil, "windows", "cmd.exe") == nil, "Windows limit applies after both encodings")
local launched = assert(Backend.build(managed(), host, options()))
same(launched.command, "'/tools/worker' '--task' " .. Backend.posix_quote(task), "managed task has one literal argv slot without a duplicate local cd")
same(launched.cwd, options().cwd, "exact cwd returned")
same(launched.placement, "split", "explicit placement returned")
same(launched.capabilities[1], "argv-v1", "terminal task reports only input capability")
check(launched.prompt == nil, "terminal task is not duplicated into a prompt channel")
check(Backend.build(managed(), host, { fresh = true, prompt = task, cwd = "/tmp" }) == nil, "managed placement cannot silently default")
check(Backend.build(managed(), host, { fresh = true, prompt = task, placement = "tab" }) == nil, "managed cwd cannot silently default")
check(Backend.build(managed(), host, options({ placement = "replace_if_alone" })) == nil, "managed terminal cannot silently downgrade unsupported placement")
check(Backend.build(managed(), host, options({ prompt = " " })) == nil, "blank assignment rejects")
check(Backend.build(record(), host, options()) == nil, "no inferred fresh mode or resume stripping")
local resumed = managed({ fresh_executable = "worker", fresh_arguments = { "--resume", "explicit-session" }, task_argument_index = 3 })
local resume_command = assert(Backend.build(resumed, host, options())).command
check(resume_command:find("'--resume' 'explicit-session'", 1, true) ~= nil, "configured fresh argv is not rewritten")
check(Backend.build(managed({ fresh_executable = "worker", fresh_arguments = {}, task_argument_index = 2 }), host, options()) == nil, "slot cannot create argv holes")
local native = record({ provider = "omp", backend = "native-agent", command = "omp --resume old", fresh_native_default = true })
local native_launch = assert(Backend.build(native, host, options()))
same(native_launch.command, "'omp'", "explicit native fresh default never reuses resume argv or duplicates cwd")
same(native_launch.prompt, task, "native startup receives exact one task prompt")
same(#native_launch.capabilities, 0, "native start does not invent argv or mailbox proof")
check(Backend.build(native, { host_os = "windows", host_shell = "pwsh.exe" }, options()) == nil, "native Windows gate is preserved")
same(assert(Backend.build(native, host, options({ placement = "replace_if_alone" }))).placement, "replace_if_alone", "native replacement placement remains supported")
native.profile = "other-account"
check(Backend.build(native, host, options()) == nil, "native default cannot discard configured profile identity")
check(Backend.build(managed(), host) == nil, "backend cannot accidentally launch ordinary resume argv")
check(Backend.build(managed(), host, options({ fresh = false })) == nil, "ordinary launches require host tickets, not backend commands")
check(Backend.build(managed(), host, options({ fresh = "true" })) == nil, "fresh mode is an explicit boolean")
local source = managed({ command = "worker --session old", arguments = { "", "two words" }, fresh_executable = "/tools/fresh-worker", fresh_arguments = { "--fresh", "" }, task_argument_index = 3 })
local ordinary = assert(Resolution.resolve(source, "ordinary", "posix"))
local fresh = assert(Resolution.resolve(source, "fresh", "posix"))
same(ordinary.executable, "worker", "shared ordinary resolution retains configured command")
same(table.concat(ordinary.arguments, "|"), "--session|old||two words", "shared ordinary resolution preserves resume and exact argv")
same(fresh.executable, "/tools/fresh-worker", "shared fresh resolution never borrows ordinary executable")
same(table.concat(fresh.arguments, "|"), "--fresh|", "shared fresh resolution never borrows resume argv")
same(ordinary.record.placement, "tab", "shared resolver returns canonical normalized record")
check(ordinary.record ~= source and ordinary.arguments ~= source.arguments and fresh.arguments ~= source.fresh_arguments, "resolved argv cannot mutate approved inputs")
table.insert(fresh.arguments, "assignment")
same(#source.fresh_arguments, 2, "fresh argv mutation leaves the source contract intact")
check(Resolution.resolve(source, "implicit", "posix") == nil, "resolver requires an explicit launch mode")
check(Resolution.resolve(record({ arguments = { [1] = "one", [3] = "gap" } }), "ordinary", "posix") == nil, "shared boundary rejects malformed records")
check(Resolution.resolve(record({ review_required = true, review_reason = "Owner review required" }), "ordinary", "posix") == nil, "ordinary resolution cannot bypass record review")
check(Backend.build(managed({ fresh_executable = "worker", fresh_arguments = {}, task_argument_index = 1, review_required = true }), host, options()) == nil, "managed resolution cannot bypass record review")
local windows_path = assert(Resolution.resolve(record({ command = '"C:\\Program Files\\Tools\\worker.cmd"', arguments = { "two words" } }), "ordinary", "powershell"))
same(windows_path.executable, "C:\\Program Files\\Tools\\worker.cmd", "normal Windows path is literal, not POSIX escapes")
same(windows_path.arguments[1], "two words", "normal Windows argv remains separate from executable")
check(Resolution.resolve(record({ command = "C:\\Tools\\worker --resume old" }), "ordinary", "powershell") == nil, "ambiguous Windows command needs a separate argument array")
same(Executor.render(source, "/bin/bash", "linux"), "SPAWN_PROVIDER=custom worker --session old '' 'two words'", "host executor consumes shared ordinary resume argv")
local terminal = managed({ prompt = "saved prompt", fresh_executable = "worker", fresh_arguments = { "--task" }, arguments = { "--normal" }, task_argument_index = 2 })
same(Executor.render(terminal, "/bin/bash", "linux", task), "SPAWN_PROVIDER=custom worker --normal", "ordinary terminal never adopts managed argv prompt insertion")
same(assert(Backend.build(terminal, host, options())).command, "'worker' '--task' " .. Backend.posix_quote(task), "managed terminal intentionally inserts the explicit assignment")
local normal_native = record({ provider = "omp", backend = "native-agent", command = "omp --resume old", prompt = "saved prompt", fresh_native_default = true })
same(Executor.render(normal_native, "/bin/bash", "linux"), "SPAWN_PROVIDER=omp omp --resume old 'saved prompt'", "ordinary OMP keeps resume plus its saved prompt")
same(Executor.render(normal_native, "/bin/bash", "linux", "setup prompt"), "SPAWN_PROVIDER=omp omp --resume old 'setup prompt'", "ordinary setup prompt overrides without changing resume argv")
same(assert(Backend.build(normal_native, host, options())).command, "'omp'", "managed Native OMP remains explicitly fresh")
local user_record = managed({ user = "worker-account", fresh_executable = "worker", fresh_arguments = {}, task_argument_index = 1 })
local user_resolution = assert(Resolution.resolve(user_record, "ordinary", "posix"))
check(Resolution.select_user(user_resolution, "posix"), "shared resolver selects configured local OS user")
same(user_resolution.executable, "sudo", "unwrapped local identity uses sudo")
same(table.concat(user_resolution.arguments, "|"), "-u|worker-account|-H|--|worker", "shared sudo wrapper keeps exact identity and command")
same(Executor.render(user_record, "/bin/bash", "linux"), "SPAWN_PROVIDER=custom sudo -u worker-account -H -- worker", "ordinary host uses the shared exact user wrapper")
same(assert(Backend.build(user_record, host, options())).command, "'sudo' '-u' 'worker-account' '-H' '--' 'worker' " .. Backend.posix_quote(task), "managed backend uses the same exact user wrapper")
for _, selector in ipairs({ { "-u", "worker-account" }, { "--user", "worker-account" }, { "-uworker-account" }, { "--user=worker-account" } }) do
	local argv = table.clone(selector)
	for _, value in ipairs({ "-H", "--", "worker", "-u", "provider-option" }) do table.insert(argv, value) end
	local wrapped = managed({ command = "/usr/bin/sudo", arguments = argv, user = "worker-account", fresh_executable = "/usr/bin/sudo", fresh_arguments = argv, task_argument_index = #argv + 1 })
	for _, mode in ipairs({ "ordinary", "fresh" }) do
		local resolved = assert(Resolution.resolve(wrapped, mode, "posix"))
		check(Resolution.select_user(resolved, "posix"), mode .. " matching sudo selector remains accepted")
		same(resolved.executable, "/usr/bin/sudo", mode .. " existing sudo is not nested")
		same(table.concat(resolved.arguments, "|"), table.concat(argv, "|"), mode .. " provider user-like flags are not sudo selectors")
	end
	check(Executor.render(wrapped, "/bin/bash", "linux") ~= nil, "ordinary matching sudo stays launchable")
	check(Backend.build(wrapped, host, options()) ~= nil, "managed matching sudo stays launchable")
	same(#wrapped.arguments, #argv, "ordinary rendering leaves configured sudo argv unchanged")
	same(#wrapped.fresh_arguments, #argv, "managed insertion leaves configured sudo argv unchanged")
end
for _, argv in ipairs({
	{ "-u", "other", "--", "worker" }, { "worker" },
	{ "-u", "worker-account", "-u", "other", "--", "worker" },
	{ "--user=worker-account", "-uworker-account", "--", "worker" },
	{ "-u", "worker-account", "-g", "group", "--", "worker" },
	{ "-u", "worker-account", "--", "NAME=value", "worker" },
	{ "--user=", "--", "worker" }, { "-u" },
}) do
	local wrapped = managed({ command = "sudo", arguments = argv, user = "worker-account", fresh_executable = "sudo", fresh_arguments = argv, task_argument_index = #argv + 1 })
	check(Executor.render(wrapped, "/bin/bash", "linux") == nil, "ordinary sudo cannot override or ambiguously select the configured identity")
	check(Backend.build(wrapped, host, options()) == nil, "managed sudo cannot override or ambiguously select the configured identity")
end
local missing_target = assert(Resolution.resolve(record({ command = "sudo", arguments = { "-u", "worker-account", "--" }, user = "worker-account" }), "ordinary", "posix"))
check(not Resolution.select_user(missing_target, "posix"), "sudo selector without a target command rejects")
local shifted_selector = managed({ fresh_executable = "sudo", fresh_arguments = { "-u", "worker-account", "--", "worker" }, task_argument_index = 2, user = "worker-account" })
check(Backend.build(shifted_selector, host, options()) == nil, "managed task insertion cannot alter a preconfigured sudo selector")
check(Executor.render(user_record, "pwsh.exe", "windows") == nil, "ordinary Windows user cannot fall back to the current account")
check(Backend.build(user_record, { host_os = "windows", host_shell = "pwsh" }, options()) == nil, "managed Windows user cannot fall back to the current account")
local ssh = managed({ backend = "ssh-command", host = "server", user = "remote", key_path = "/keys/key", command = "worker", fresh_executable = "worker", fresh_arguments = {}, task_argument_index = 1, target_os = "linux", target_shell = "sh" })
local remote = assert(Backend.serialize("worker", { task }, options().cwd, "linux", "sh"))
local ssh_argv = assert(Backend.ssh_arguments(ssh, remote, true))
local ssh_launch = assert(Backend.build(ssh, host, options()))
same(ssh_launch.command, Backend.serialize("ssh", ssh_argv, nil, "linux", "/bin/bash"), "remote serialization nests inside pane-host serialization")
same(ssh_launch.cwd, ".", "remote cwd never becomes pane-host cwd")
check(not ssh_launch.command:find("StrictHostKeyChecking", 1, true), "SSH host-key policy is not bypassed")
local ordinary_ssh = table.clone(ssh)
ordinary_ssh.cwd, ordinary_ssh.target_os, ordinary_ssh.target_shell = "~/project", "windows", "powershell.exe"
same(Executor.render(ordinary_ssh, "/bin/bash", "linux"),
	"SPAWN_PROVIDER=custom ssh -t -i /keys/key -- remote@server " .. Backend.posix_quote('cd "$HOME/"' .. Backend.posix_quote("project") .. " && worker"),
	"ordinary SSH retains released POSIX/home behavior even with managed Windows target metadata")
local home_remote = assert(Backend.serialize("worker", { task }, "~", "linux", "sh"))
same(assert(Backend.build(ssh, host, options({ cwd = "~" }))).command,
	Backend.serialize("ssh", assert(Backend.ssh_arguments(ssh, home_remote, true)), nil, "linux", "/bin/bash"),
	"managed remote cwd is literal, not ordinary home expansion")
for _, identity in ipairs({
	{ host = "-oBad", user = "remote" }, { host = "server other", user = "remote" },
	{ host = "server", user = "-other" }, { host = "server", user = "other user" },
	{ host = "other@server", user = "remote" }, { host = "other@@server", user = "" },
	{ host = "@server", user = "" }, { host = "other@", user = "" }, { host = "other@-server", user = "" },
}) do
	local invalid_ssh = table.clone(ssh)
	invalid_ssh.host, invalid_ssh.user = identity.host, identity.user
	check(Backend.ssh_arguments(invalid_ssh, "worker", true) == nil, "mailbox SSH helper rejects malformed or conflicting identity")
	check(Executor.render(invalid_ssh, "/bin/bash", "linux") == nil, "ordinary SSH rejects malformed or conflicting identity")
	check(Backend.build(invalid_ssh, host, options()) == nil, "managed SSH rejects the same malformed or conflicting identity")
end
local embedded_ssh = table.clone(ssh)
embedded_ssh.host, embedded_ssh.user = "remote@server", nil
local embedded_args = assert(Backend.ssh_arguments(embedded_ssh, "worker", false))
same(embedded_args[#embedded_args - 1], "remote@server", "one embedded SSH user remains an exact released destination")
check(Executor.render(embedded_ssh, "/bin/bash", "linux") ~= nil, "ordinary SSH retains a single embedded user")
check(Backend.build(embedded_ssh, host, options()) ~= nil, "managed SSH retains a single embedded user")
ssh.target_os = nil
check(Backend.build(ssh, host, options()) == nil, "managed SSH cannot guess target OS")
ssh.target_os, ssh.target_shell, ssh.fresh_executable = "windows", "powershell.exe", "C:\\Tools\\worker.exe"
local windows_remote_options = options({ cwd = "C:\\work" })
check(Backend.build(ssh, host, windows_remote_options) == nil, "managed Windows target requires an explicit CRT contract")
ssh.argv_contract = "windows-crt"
same(assert(Config.validate_record(ssh)).argv_contract, "windows-crt", "configured CRT contract survives normalization")
local windows_remote = assert(Backend.serialize(ssh.fresh_executable, { task }, "C:\\work", "windows", "powershell.exe", true))
same(assert(Backend.build(ssh, host, windows_remote_options)).command,
	Backend.serialize("ssh", assert(Backend.ssh_arguments(ssh, windows_remote, true)), nil, "linux", "/bin/bash"),
	"Linux host nests the independently encoded Windows target command")
for _, executable in ipairs({ "worker.cmd", "worker.bat", "worker.ps1", "worker", "cmd.exe", "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\PowerShell.EXE", "pwsh.exe" }) do
	local unsupported = table.clone(ssh)
	unsupported.fresh_executable = executable
	check(Backend.build(unsupported, host, windows_remote_options) == nil, "managed Windows rejects script/shim/shell: " .. executable)
	check(not Backend.eligibility(unsupported).configured, "catalog facts reject unsupported Windows fresh target: " .. executable)
end
local windows_host = { host_os = "windows", host_shell = "powershell.exe" }
local windows_local = record({ command = "worker.cmd", fresh_executable = "C:\\Tools\\worker.exe", fresh_arguments = {}, task_argument_index = 1, argv_contract = "windows-crt" })
check(Backend.build(windows_local, windows_host, windows_remote_options) ~= nil, "managed local Windows accepts explicit native CRT executable")
local transport_task = task .. "\nTransport metadata (literal): " .. string.rep("m", 1024)
local compact_options = options({ prompt = transport_task, cwd = "C:\\work" })
local compact = assert(Backend.build(windows_local, windows_host, compact_options))
check(#compact.command <= 7000, "managed Windows task plus 1KiB transport metadata fits encoded bound")
local compact_wide = decode64(assert(compact.command:match("EncodedCommand ([A-Za-z0-9+/=]+)$")))
local compact_ascii = {}
for index = 1, #compact_wide, 2 do table.insert(compact_ascii, compact_wide:sub(index, index)) end
local compact_wrapper = table.concat(compact_ascii)
check(not compact_wrapper:find("Get-Command", 1, true) and not compact_wrapper:find("cmd.exe", 1, true), "managed CRT wrapper has no legacy discovery or batch shell")
local compact_payload = runtime.json.decode(decode64(assert(compact_wrapper:match("FromBase64String%('([A-Za-z0-9+/=]+)'%)"))))
same(compact_payload.arguments, Backend.windows_argument(transport_task), "compact wrapper retains exact task plus transport metadata")
check(compact_payload.batch == nil, "compact payload does not duplicate task in cmd-escaped data")
local windows_to_posix = table.clone(ssh)
windows_to_posix.target_os, windows_to_posix.target_shell, windows_to_posix.fresh_executable = "linux", "sh", "worker"
local posix_remote = assert(Backend.serialize("worker", { transport_task }, "/work", "linux", "sh", true))
local compact_ssh = assert(Backend.build(windows_to_posix, windows_host, options({ prompt = transport_task, cwd = "/work" })))
same(compact_ssh.command, Backend.serialize("ssh.exe", assert(Backend.ssh_arguments(windows_to_posix, posix_remote, true)), nil, "windows", "powershell.exe", true), "fresh Windows SSH host uses explicit ssh.exe and compact CRT wrapper")
check(#compact_ssh.command <= 7000, "compact Windows SSH wrapper bounds literal transport metadata")
check(Executor.render(record({ command = "worker.cmd" }), "powershell.exe", "windows") ~= nil, "ordinary Windows batch launch stays in the released host executor")
check(Backend.ssh_arguments({ host = "-oBad" }, "command") == nil, "SSH destination cannot become option")
local metadata = record({ fresh_executable = "worker", fresh_arguments = {}, task_argument_index = 1, host_shell = "bash", target_os = "linux", target_shell = "sh", model = "configured-model", profile = "configured-profile", variant_id = "variant", capacity_binding = "account-pool", capacity_limit = 2, mailbox = { permitted_root = "/mailboxes", helper_path = "/tools/mailbox_target.sh", worker_identity = "worker", producer = { read = true, write = true, hash = true, journal = true, poll = false }, capabilities = { "report-files-v1", "argv-v1" }, verified = false, evidence_ref = "configured-evidence-reference" } })
metadata.mailbox.producer_helper_path = "/tools/mailbox_producer.sh"
check(assert(Config.validate_record(metadata)).selector_evidence == nil, "model/profile and transport evidence never imply selector evidence")
metadata.selector_evidence = "selector-status-reference"
local saved = assert(Config.validate_record(metadata))
same(saved.fresh_executable, metadata.fresh_executable, "fresh executable survives normalizer")
same(#saved.fresh_arguments, 0, "explicit empty fresh argv survives")
same(saved.model, metadata.model, "model metadata retained without name inference")
same(saved.profile, metadata.profile, "profile metadata retained")
same(saved.selector_evidence, "selector-status-reference", "explicit selector evidence remains distinct from transport evidence")
same(saved.capacity_binding, metadata.capacity_binding, "capacity identity retained")
same(saved.capacity_limit, 2, "capacity bound retained")
same(saved.mailbox.producer.poll, false, "false producer capability remains false")
same(saved.mailbox.verified, false, "normalizer never manufactures verification")
same(saved.mailbox.producer_helper_path, "/tools/mailbox_producer.sh", "private producer helper path survives normalization independently of transport helper")
check(saved.mailbox ~= metadata.mailbox and saved.mailbox.producer ~= metadata.mailbox.producer, "normalized nested metadata does not alias input")
local migrated = assert(Config.migrate({ schema = 2, hosts = { machine = { schema = 2, agents = { saved } } } }, "machine"))
check(not migrated.changed, "managed metadata survives idempotent authoritative reload")
check(Config.validate_record(record({ fresh_executable = "worker" })) == nil, "fresh pair must be explicit")
check(Config.validate_record(record({ fresh_arguments = {} })) == nil, "orphan fresh argv rejects")
check(Config.validate_record(record({ task_argument_index = 0 })) == nil, "zero task slot rejects")
check(Config.validate_record(record({ mailbox = { capabilities = { "report-files-v1", "report-files-v1" } } })) == nil, "duplicate capability rejects")
check(Config.validate_record(record({ mailbox = { producer = { imaginary = true } } })) == nil, "unknown producer metadata rejects")
check(Config.validate_record(record({ mailbox = { permitted_root = "relative/root" } })) == nil, "mailbox permitted root must be absolute")
check(Config.validate_record(record({ mailbox = { producer_helper_path = "relative/helper" } })) == nil, "producer helper path must be absolute")
check(Config.validate_record(record({ mailbox = { producer_helper_path = string.rep("/", 4097) } })) == nil, "producer helper path is bounded")
check(Config.validate_record(record({ mailbox = { producer_helper_path = false } })) == nil, "producer helper path must be text")
check(assert(Config.validate_record(record({ mailbox = { helper_path = "/tools/mailbox_target.sh" } }))).mailbox.producer_helper_path == nil, "transport helper never defaults the producer helper")
check(Config.validate_record(record({ selector_evidence = false })) == nil, "selector evidence must be text")
check(Config.validate_record(record({ selector_evidence = string.rep("x", 4097) })) == nil, "selector evidence is bounded")
check(Config.validate_record(record({ selector_evidence = " " })) == nil, "explicit selector evidence cannot be blank")
check(Config.validate_record(record({ argv_contract = "anything-else" })) == nil, "argv contract is a closed optional enum")
check(assert(Config.validate_record(record())).argv_contract == nil, "normalizer never invents a CRT contract")
local absent = assert(Config.validate_record(record()))
check(absent.mailbox == nil and absent.fresh_executable == nil and absent.fresh_native_default == nil, "missing capability declarations stay absent")
check(not Backend.eligibility(saved).runtime_verified, "configured facts are never runtime proof")
return string.format("PASS %d SPAWN backend checks", checks)
