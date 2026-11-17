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
same(table.concat({ table.unpack(user_resolution.arguments, 1, 5) }, "|"), "-u|worker-account|-H|--|/bin/sh", "shared sudo wrapper keeps the exact identity before the login shell")
same(table.concat({ user_resolution.arguments[6], user_resolution.arguments[8], user_resolution.arguments[9] }, "|"), "-c|spawn-login|cd -- \"$0\" || exit 1; exec 'worker'", "shared sudo wrapper enters the account's login shell and keeps the exact command")
check(#user_resolution.arguments == 9, "the login wrapper carries the program as one quoted text word")
local login_script = user_resolution.arguments[7]
check(login_script:find('-lc "$1" "$d"', 1, true) ~= nil and login_script:find("$SHELL", 1, true) == nil and login_script:find("worker", 1, true) == nil, "the login script is constant: it never carries the program and never reads SHELL from the environment")
same(Executor.render(user_record, "/bin/bash", "linux"), "SPAWN_PROVIDER=custom sudo -u worker-account -H -- /bin/sh -c " .. Backend.posix_quote(login_script) .. " spawn-login " .. Backend.posix_quote("cd -- \"$0\" || exit 1; exec 'worker'"), "ordinary host uses the shared exact user wrapper")
same(assert(Backend.build(user_record, host, options())).command, "'sudo' '-n' '-u' 'worker-account' '-H' '--' '/bin/sh' '-c' " .. Backend.posix_quote(login_script) .. " 'spawn-login' " .. Backend.posix_quote("cd -- \"$0\" || exit 1; exec 'worker' " .. Backend.posix_quote(task)) .. "", "managed backend never asks interactively for cross-user credentials")
for _, selector in ipairs({ { "-u", "worker-account" }, { "--user", "worker-account" }, { "-uworker-account" }, { "--user=worker-account" } }) do
	local argv = table.clone(selector)
	for _, value in ipairs({ "-H", "--", "worker", "-u", "provider-option" }) do table.insert(argv, value) end
	local wrapped = managed({ command = "/usr/bin/sudo", arguments = argv, user = "worker-account", fresh_executable = "/usr/bin/sudo", fresh_arguments = argv, task_argument_index = #argv + 1 })
	for _, mode in ipairs({ "ordinary", "fresh" }) do
		local resolved = assert(Resolution.resolve(wrapped, mode, "posix"))
		check(Resolution.select_user(resolved, "posix"), mode .. " matching sudo selector remains accepted")
		same(resolved.executable, "/usr/bin/sudo", mode .. " existing sudo is not nested")
		-- After "--" come the login wrapper and ONE quoted text word carrying the configured program and arguments.
		local split = 0
		for index, value in ipairs(argv) do if value == "--" then split = index; break end end
		same(table.concat(resolved.arguments, "|", 1, split), table.concat(argv, "|", 1, split), mode .. " keeps the sudo selectors and flags exactly")
		same(table.concat(resolved.arguments, "|", split + 1, split + 2), "/bin/sh|-c", mode .. " enters the account's login shell")
		same(resolved.arguments[split + 4], "spawn-login", mode .. " names the login script")
		local quoted = {}
		for index = split + 1, #argv do table.insert(quoted, "'" .. argv[index] .. "'") end
		same(resolved.arguments[split + 5], 'cd -- "$0" || exit 1; exec ' .. table.concat(quoted, " "), mode .. " provider user-like flags are not sudo selectors")
		same(#resolved.arguments, split + 5, mode .. " adds nothing after the quoted text")
	end
	check(Executor.render(wrapped, "/bin/bash", "linux") ~= nil, "ordinary matching sudo stays launchable")
	check(Backend.build(wrapped, host, options()) ~= nil, "managed matching sudo stays launchable")
	check(assert(Backend.build(wrapped,host,options())).command:find("'/usr/bin/sudo' '-n'",1,true)~=nil,"managed configured sudo also requires noninteractive execution")
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
-- Pure wizard preparation boundaries; no provisioning/provider process runs here.
local Setup,Prereq=load("managed_setup"),load("prereq")
local setupDraft=Setup.from_record(saved)
same(setupDraft.id,saved.id,"adoption keeps the stable record ID")
same(setupDraft.task_argument_index,tostring(saved.task_argument_index),"adoption keeps the actual task argv insertion slot")
same(setupDraft.source_record.profile,saved.profile,"adoption retains selectors in its review draft")
check(setupDraft.source_record~=saved,"adoption draft cannot mutate the authoritative record")
local rejectedSetup=nil
setupDraft.id="different"
Setup.prepare(setupDraft,host,function(value,probe,why) rejectedSetup={value=value,probe=probe,why=why} end)
check(rejectedSetup and rejectedSetup.value==nil and rejectedSetup.probe==nil and rejectedSetup.why:find("immutable",1,true),"adoption cannot rename an existing stable ID before resource creation")
setupDraft.id=saved.id;setupDraft.task_argument_index="0";rejectedSetup=nil
Setup.prepare(setupDraft,host,function(value,probe,why) rejectedSetup={value=value,probe=probe,why=why} end)
check(rejectedSetup and rejectedSetup.value==nil and rejectedSetup.why:find("position",1,true),"invalid task insertion refuses before effects")
same(table.concat(Prereq.as_user({"id","-un"},"selected"),"|"),"sudo|-n|-u|selected|-H|--|id|-un","prerequisites execute noninteractive chosen-account checks with that account's home")
local sameUser={"id","-un"}
check(Prereq.as_user(sameUser,nil)==sameUser,"same-user prerequisites do not add SSH or sudo")
do
 local native=assert(Setup.from_native("sudo -n -u selected -H -- '/tools/native worker Ω' --profile 'work account'","/work"))
 same(native.user,"selected","native adoption reads the OS account only from the explicit command selector")
 same(native.executable,"/tools/native worker Ω","native adoption preserves the exact literal executable, including spaces")
 same(native.arguments,Config.render_arguments({"--profile","work account"}),"native adoption preserves configured native selectors without provider allowlists")
 check(Setup.from_native("sudo -u one -u two -- worker","/work")==nil,"ambiguous native OS identities refuse")
 check(Setup.from_native("sudo -E -u selected -- worker","/work")==nil,"unreviewed native identity environment options refuse adoption")
 check(Setup.from_native("ssh remote worker","/work")==nil,"discovery cannot invent a cross-host managed route")
 same(assert(Setup.from_native("custom-native --account work","/work")).user,"","provider account arguments and labels never become POSIX users")
 for _,arguments in ipairs({"--restore existing-session","--resume=existing-session","--continue","resume existing-session","--session-id existing-session","--session-dir /existing/session"}) do
  local restored,why=Setup.from_native("sudo -n -u selected -H -- omp "..arguments,"/work")
  check(restored==nil and why:find("Fresh native route required",1,true),"active native continuation cannot be adopted as fresh: "..arguments)
 end
 local fresh=assert(Setup.from_native("omp --model selected/model --permission-mode normal","/work"))
 same(fresh.arguments,Config.render_arguments({"--model","selected/model","--permission-mode","normal"}),"genuinely fresh native defaults retain exact model and permissions flags")
 local configured=assert(Config.validate_record(record({provider="Configured native label",backend="native-agent",command="/tools/native",fresh_executable="/tools/native",fresh_arguments={}})))
 check(configured.provider=="Configured native label" and configured.backend=="native-agent","an explicit configured native route is not rejected by a display-provider allowlist")
 local lifecycle=load("launch_state")
 check(lifecycle.reserve(lifecycle.new(),configured,"host/session","observer","managed")~=nil,"configured native identity is not replaced by an OMP label during reservation")
end
local Adapter=load("mailbox_adapter")
check(Adapter.absolute_path("/work/a..b/helpers",false),"a literal basename containing two dots is not traversal")
check(Adapter.absolute_path("C:\\work\\a..b\\helpers",true),"Windows literal two-dot basename is accepted")
for _,path in ipairs({"/work/../helpers","/work/..","/work/./helpers","/work/.","/work//helpers"}) do
 check(not Adapter.absolute_path(path,false),"POSIX traversal/repeated separators reject: "..path)
end
for _,path in ipairs({"C:\\work\\..\\helpers","C:\\work\\..","C:\\work\\.\\helpers","C:\\work\\."}) do
 check(not Adapter.absolute_path(path,true),"Windows traversal segments reject: "..path)
end
-- Planning is offline; the required native boundary is separately consented.
local routeRecord=assert(Config.validate_record(saved))
routeRecord.backend="native-agent";routeRecord.provider="OMP";routeRecord.cwd="/fixture/repository"
routeRecord.fresh_executable="omp";routeRecord.fresh_arguments={"--model","selected/model","--profile","selected-profile"}
routeRecord.mailbox.permitted_root="/fixture/mail";routeRecord.mailbox.worker_identity="selected"
routeRecord.mailbox.helper_path="/fixture/bundle/mailbox_target.sh"
local routeProbe={provision_handle="setup-fixture",record_sha256=string.rep("a",64)}
local diagnostic=assert(Setup.route(routeRecord,routeProbe,host,7,"","route-native-fixture"))
same(diagnostic.window,"","normal empty native window key is retained, never invented")
same(diagnostic.config_revision,7,"native diagnostic captures exact config revision")
same(diagnostic.expected_arguments[2],"selected/model","diagnostic keeps explicitly selected model")
same(diagnostic.expected_arguments[4],"selected-profile","diagnostic keeps explicitly selected profile")
same(#diagnostic.expected_arguments,#routeRecord.fresh_arguments+2,"only owned diagnostic session storage is added; no tool/rule/model/time flags are injected")
for index,word in ipairs(routeRecord.fresh_arguments) do same(diagnostic.expected_arguments[index],word,"every selected CLI argument is preserved verbatim") end
local secondDiagnostic=assert(Setup.route(routeRecord,routeProbe,host,7,"","another-consent"))
check(diagnostic.expected_arguments[#diagnostic.expected_arguments]~=secondDiagnostic.expected_arguments[#secondDiagnostic.expected_arguments],"separate consents never share diagnostic session storage")
same(routeRecord.fresh_arguments[#routeRecord.fresh_arguments],"selected-profile","diagnostic controls never rewrite saved argv")
check(diagnostic.prompt:find(diagnostic.nonce,1,true)~=nil and diagnostic.prompt~=secondDiagnostic.prompt,"startup sentinel distinguishes separate consents")
local Native=load("native_cli")
local oldObserve=Native.observe_process
local observedArgs={"bun","/fixture/omp.js"}
for _,word in ipairs(diagnostic.expected_arguments) do table.insert(observedArgs,word) end
table.insert(observedArgs,"--native-transport-fixture")
Native.observe_process=function(window,session,pane,callback)
 same(window,"","process readback retains originating empty window identity")
 callback({status=0,timed_out=false,stdout=runtime.json.encode({pane=pane,child={argv=observedArgs,pid=123,cwd=diagnostic.cwd}})},nil)
end
local proof,proofError
Setup.observe_route(diagnostic,4,9,function(value,why)proof=value;proofError=why end)
check(proof~=nil and proofError==nil,"actual argv observation allows native transport suffix without dropping selected arguments")
observedArgs[3]="--wrong-selected-flags"
Setup.observe_route(diagnostic,4,9,function(value,why)proof=value;proofError=why end)
check(proof==nil and proofError~=nil,"wrong actual child argv cannot manufacture native-route success")
local oldChild,oldIdentity=Prereq.native_child,Native.process_identity
local rootEpoch,childEpoch="boot:123:1","boot:456:1"
Native.process_identity=function(pid) return if pid==123 then rootEpoch elseif pid==456 then childEpoch else nil end
Native.observe_process=function(_,_,pane,callback)
 callback({status=0,timed_out=false,stdout=runtime.json.encode({pane=pane,child={pid=123,argv={"sudo"}}})},nil)
end
local childArgs={"bun","/fixture/omp.js"}
for _,word in ipairs(diagnostic.expected_arguments) do table.insert(childArgs,word) end
local child={pid=456,cwd=diagnostic.cwd,argv=childArgs,worker_identity="selected",process_identity=childEpoch}
Prereq.native_child=function(_,_,_,_,callback)callback(child,nil)end
diagnostic.user="selected"
Setup.observe_route(diagnostic,4,9,function(value,why)proof=value;proofError=why end)
check(proof~=nil and proofError==nil,"an inaccessible sudo wrapper is verified through its actual selected-account agent descendant")
child.worker_identity="another"
Setup.observe_route(diagnostic,4,9,function(value,why)proof=value;proofError=why end)
check(proof==nil and proofError~=nil,"a descendant from another OS account cannot establish native-route proof")
child.worker_identity="selected";child.cwd="/another"
Setup.observe_route(diagnostic,4,9,function(value,why)proof=value;proofError=why end)
check(proof==nil and proofError~=nil,"account-aware observation does not weaken the actual working-folder check")
child.cwd=diagnostic.cwd;childEpoch="boot:456:2"
Setup.observe_route(diagnostic,4,9,function(value,why)proof=value;proofError=why end)
check(proof==nil and proofError~=nil,"reused child PIDs cannot retain the previous native diagnostic proof")
childEpoch=child.process_identity
Prereq.native_child=function(_,_,_,_,callback)rootEpoch="boot:123:2";callback(child,nil)end
Setup.observe_route(diagnostic,4,9,function(value,why)proof=value;proofError=why end)
check(proof==nil and proofError~=nil,"a changed native wrapper epoch invalidates the descendant observation")
Prereq.native_child,Native.process_identity=oldChild,oldIdentity
diagnostic.user=nil
Native.observe_process=oldObserve
routeRecord.backend="local-terminal";routeRecord.user="selected"
local terminalDiagnostic=assert(Setup.route(routeRecord,routeProbe,host,7,"window","route-terminal-fixture"))
check(terminalDiagnostic.command:find("setup_route.sh",1,true)~=nil and terminalDiagnostic.command:find("'-n'",1,true)~=nil,"offline terminal diagnostic uses packaged helper and noninteractive selected identity")
check(terminalDiagnostic.prompt==nil and terminalDiagnostic.expected:find("\nselected\n",1,true)~=nil,"terminal readback binds literal bytes and actual worker identity, not a fabricated provider task")
local originalRead=Prereq.run
local fixtureBytes,fixtureError="SPAWN_ROUTE_PENDING",nil
Prereq.run=function(_,_,callback)callback(fixtureBytes,fixtureError)end
local terminalProof,terminalError,terminalPending
local function observeTerminal()
 Setup.observe_route(terminalDiagnostic,4,9,function(value,why,pending)terminalProof=value;terminalError=why;terminalPending=pending end)
end
observeTerminal()
check(terminalProof==nil and terminalPending==true,"missing terminal publication is typed pending, not failure")
fixtureBytes=terminalDiagnostic.expected:sub(1,17);observeTerminal()
check(terminalProof==nil and terminalPending==true,"partially written matching terminal observation remains pending")
fixtureBytes="";observeTerminal()
check(terminalProof==nil and terminalPending==true,"new empty terminal observation remains pending while its producer writes")
fixtureBytes=terminalDiagnostic.expected;observeTerminal()
check(terminalProof~=nil and terminalPending~=true and terminalError==nil,"complete exact terminal publication succeeds after pending reads")
fixtureBytes="foreign observation";observeTerminal()
check(terminalProof==nil and terminalPending~=true and terminalError~=nil,"wrong complete terminal evidence is a failure, not a retryable publication")
fixtureBytes=nil;fixtureError="Permission denied";observeTerminal()
check(terminalProof==nil and terminalPending~=true and terminalError=="Permission denied","permanent read failures are not hidden by pending retries")
Prereq.run=originalRead
do
 -- Exercise the Windows wrappers without processes/filesystem writes. In
 -- particular, a UTF16 converter's second return is not Base64 options.
 local encodedScripts,processCalls,prepared=0,0,nil
 local pendingUtf16=nil
 local wrappedBackend=table.clone(Backend)
 wrappedBackend.utf16le=function(script)
  local bytes,why=Backend.utf16le(script)
  pendingUtf16=bytes
  return bytes,why
 end
 local fake={
  runtime={os="windows"},plugin={data="C:/fixture/data",dir="C:/fixture/plugin"},
  json=runtime.json,now=function()return 1000 end,
  timer=function(_,callback)callback()end,
  fs={read=function(path)return "fixture helper bytes: "..path end},
  base64={encode=function(bytes,...)
   check(select("#",...)==0,"Base64 receives only bytes, not UTF16's error return as options")
   if pendingUtf16 then
    same(bytes,pendingUtf16,"EncodedCommand receives the exact UTF16LE bytes")
    pendingUtf16=nil;encodedScripts+=1
   end
   return runtime.base64.encode(bytes)
  end},
 }
 local function captured(argv)
  processCalls+=1
  same(table.concat(argv,"|",1,5),"powershell.exe|-NoLogo|-NoProfile|-NonInteractive|-EncodedCommand","Windows script argv prefix is unchanged")
  check(#argv==6 and #runtime.base64.decode(argv[6])>0,"Windows script remains one standard padded Base64 argument")
 end
 local fixturePrereq={
  identity=function(_,done)done("fixture-user",nil)end,
  account=function(user,_,_,done)done({identity=user,home="/fixture/selected-home",executable="/fixture/selected-home/.local/bin/native"},nil)end,
  run=function(argv,stdin,done)
   if #argv==2 and argv[1]=="C:/fixture/worker.exe" and argv[2]=="--help" then
    done("Usage: fixture [options]\n  --help  Show help",nil)
    return
   end
   if fake.runtime.os=="windows" then captured(argv) end
   done(stdin or "",nil)
  end,
  as_user=Prereq.as_user,
  probe=function(canonical,_,done)prepared=canonical;done({passed=true})end,
 }
 local dependencies={["./config"]=Config,["./wire/codec"]=load("wire/codec"),["./backend"]=wrappedBackend,["./prereq"]=fixturePrereq,["./mailbox_adapter"]=Adapter,["./native_cli"]=Native,["./terminal_identity"]=load("terminal_identity")}
 local function isolated(name)
  local chunk=assert(loadstring(runtime.fs.read(root.."/"..name..".luau"),name))
  setfenv(chunk,setmetatable({tern=fake,require=function(dependency)return assert(dependencies[dependency])end},{__index=environment}))
  return chunk()
 end
 local setup=isolated("managed_setup")
 local draft=setup.defaults()
 draft.cwd="C:/fixture/repository";draft.executable="C:/fixture/worker.exe"
 local function prepare()
  local result,problem
  setup.prepare(draft,{host_os=fake.runtime.os,host_shell=if fake.runtime.os=="windows" then "powershell.exe" else "sh"},function(value,_,why)result=value;problem=why end)
  return result,problem
 end
 for _,excluded in ipairs({{backend="native-agent",user=""},{backend="local-terminal",user="other"},{backend="ssh-command",user=""}}) do
  draft.backend=excluded.backend;draft.user=excluded.user
  local result,problem=prepare()
  check(result==nil and type(problem)=="string" and processCalls==0,"Windows native OMP, cross-user and managed SSH exclusions precede all setup effects")
 end
 draft.backend="local-terminal";draft.user=""
 check(prepare()~=nil and prepared.backend=="local-terminal" and encodedScripts==11,"Windows local setup encodes both directory wrappers and all nine helper publications")
 local windowsRoute={backend="local-terminal",host_os="windows",output="C:/fixture/Ω.observation",expected="exact observation\n"}
 fixturePrereq.run=function(argv,_,done)captured(argv);done(windowsRoute.expected,nil)end
 local observed
 setup.observe_route(windowsRoute,4,9,function(value,why)observed=value;check(why==nil,"Windows route exact readback is accepted")end)
 check(observed~=nil and encodedScripts==12,"Windows route observation uses the same single-value Base64 boundary")
 fake.process={run=function(argv,_,done)
  captured(argv)
  done({status=1,timed_out=false,stdout="",stderr="fixture refusal"})
 end}
 local prerequisite=isolated("prereq")
 local probe
 prerequisite.probe(prepared,{host_os="windows",host_shell="powershell.exe",bundle_digest=string.rep("a",64),provision_handle="fixture-probe"},function(value)probe=value end)
 check(encodedScripts==13 and probe and not probe.passed,"Windows prerequisite encoding retains process failure as failed evidence")
 fake.runtime.os="linux"
 fake.plugin.data="/fixture/data";fake.plugin.dir="/fixture/plugin"
 draft=setup.defaults()
 draft.cwd="/fixture/repository";draft.root="/fixture/mail"
 fixturePrereq.run=function(_,stdin,done)done(stdin or "",nil)end
 check(prepare()~=nil and prepared.backend=="native-agent","non-Windows native setup remains a valid branch after Windows exclusions")
 prepared.provider_family="anthropic"
 draft=setup.from_record(prepared)
 draft.provider_family="openai"
 local changedFamily=prepare()
 check(changedFamily and changedFamily.provider_family=="openai" and draft.source_record.provider_family=="anthropic","managed preparation honors the edited underlying provider without mutating or silently restoring the old declaration")
 draft=setup.defaults("/fixture/repository");draft.user="selected"
 local selected=prepare()
 check(selected and selected.user=="selected" and selected.mailbox.worker_identity=="selected","explicit existing-account preparation never falls back to the host identity")
 check(selected.mailbox.permitted_root=="/fixture/selected-home/.local/share/tern-spawn/managed" and selected.mailbox.helper_path:find(selected.mailbox.permitted_root.."/helper-bundles/",1,true)==1,"selected account receives stable home-local mailbox/helper paths, not another user's plugin data")
 check(draft.root=="/fixture/data/managed" and draft.executable=="omp","preparation cannot mutate the reviewed draft while resolving the selected executable/root")
 local launch=assert(Backend.build(selected,{host_os="linux",host_shell="sh"},{fresh=true,prompt="explicit consent diagnostic",cwd=selected.cwd,placement="tab"}))
 same(launch.command,"'sudo' '-n' '-u' 'selected' '-H' '--' '/bin/sh' '-c' "..Backend.posix_quote(([==[u=$(id -un); d=$PWD; sh=$(getent passwd "$u" 2>/dev/null | cut -d: -f7); [ -n "$sh" ] || sh=$(dscl . -read "/Users/$u" UserShell 2>/dev/null | sed -n 's/^UserShell: //p'); case "${sh##*/}" in bash|zsh|sh|dash|ksh) [ -x "$sh" ] && exec "$sh" -lc "$1" "$d";; esac; exec /bin/sh -c "$1" "$d"]==])).." 'spawn-login' "..Backend.posix_quote([==[cd -- "$0" || exit 1; exec '/fixture/selected-home/.local/bin/native']==]),"native projection uses exactly the observed executable under the selected account, not the current-user PATH")
 check(launch.cwd=="/fixture/repository" and launch.prompt=="explicit consent diagnostic","selected-account native startup retains exact cwd and separate prompt channel")
 local diagnostic=assert(setup.route(selected,{record_sha256=string.rep("a",64)},{host_os="linux",host_shell="sh"},9,"","selected-diagnostic"))
 check(diagnostic.user=="selected" and diagnostic.worker_identity=="selected" and diagnostic.command:find("'/fixture/selected-home/.local/share/tern-spawn/managed/selected-diagnostic-native'",1,true),"consented native diagnostic binds its exact selected account and owned session directory for existing cleanup machinery")
 local mismatched=table.clone(selected);mismatched.mailbox=table.clone(selected.mailbox);mismatched.mailbox.worker_identity="host-account"
 check(Backend.build(mismatched,{host_os="linux",host_shell="sh"},{fresh=true,prompt="held assignment",cwd=selected.cwd,placement="tab"})==nil,"a prepared connection for another account cannot launch under an explicit OS user")
 local wrapped=table.clone(mismatched);wrapped.user=nil;wrapped.command="sudo";wrapped.arguments={"-n","-u","selected","-H","--",selected.fresh_executable};wrapped.fresh_executable="sudo";wrapped.fresh_arguments=table.clone(wrapped.arguments)
 local refused,identityError=Backend.build(wrapped,{host_os="linux",host_shell="sh"},{fresh=true,prompt="held assignment",cwd=selected.cwd,placement="tab"})
 check(refused==nil and type(identityError)=="string","legacy embedded sudo cannot bypass prepared-identity validation when its user field is absent")
 wrapped.mailbox=table.clone(selected.mailbox)
 check(Backend.build(wrapped,{host_os="linux",host_shell="sh"},{fresh=true,prompt="held assignment",cwd=selected.cwd,placement="tab"})~=nil,"matching embedded sudo and mailbox identities remain launchable")
 local effects=0
 local accountChecks=0
 fixturePrereq.account=function(_,_,_,done)accountChecks+=1;done(nil,"fixture account check reached")end
 fixturePrereq.identity=function(_,done)accountChecks+=1;done(nil,"fixture identity check reached")end
 fixturePrereq.run=function(_,_,done)effects+=1;done("",nil)end
 for _,arguments in ipairs({"--restore existing-session","--resume=existing-session","--continue","resume existing-session","--session-id existing-session","--session-dir /existing/session"}) do
  draft.arguments=arguments
  local refused,problem=prepare()
  check(refused==nil and problem:find("Fresh native route required",1,true) and accountChecks==0 and effects==0,"continuation draft refuses before selected-account probes or resource effects: "..arguments)
 end
 draft.arguments=""
 local restored=table.clone(selected);restored.fresh_arguments={"--restore","existing-session"}
 local refusedRoute,routeProblem=setup.route(restored,{record_sha256=string.rep("a",64)},{host_os="linux",host_shell="sh"},9,"","selected-diagnostic")
 check(refusedRoute==nil and routeProblem:find("Fresh native route required",1,true) and effects==0,"adding a diagnostic session directory cannot make a restore contract fresh or authorize a launch")
 fixturePrereq.run=function(_,_,done)effects+=1;done("",nil)end
 fixturePrereq.account=function(_,_,_,done)done(nil,"Selected-account prerequisite failed: sudo authorization denied")end
 local denied,denial=prepare()
 check(denied==nil and denial:find("authorization denied",1,true) and effects==0,"unavailable selected access refuses before all helper/directory effects")
end
do
 local calls,mode={},'accepted'
 local fake=setmetatable({runtime={os="linux"},process={run=function(argv,_,done)
  table.insert(calls,argv)
  if argv[1]=="getent" then done({status=0,stdout="selected:x:1001:1001:Existing:/home/selected:/bin/sh\n",stderr=""})
  elseif mode=="denied" then done({status=1,stdout="",stderr="sudo: a password is required"})
  else done({status=0,stdout=(if mode=="wrong-identity" then "other" else "selected").."\n/home/selected\n/home/selected/.local/bin/native\n",stderr=""}) end
 end}},{__index=runtime})
 local chunk=assert(loadstring(runtime.fs.read(root.."/prereq.luau"),"prereq_selected_account"))
 setfenv(chunk,setmetatable({tern=fake,require=load},{__index=environment}))
 local prerequisite=chunk()
 for _,case in ipairs({"accepted","denied","wrong-identity"}) do
  mode=case;calls={}
  local observed,problem
  prerequisite.account("selected","native","/work",function(account,why)observed=account;problem=why end)
  check(#calls==2 and table.concat(calls[2],"|",1,6)=="sudo|-n|-u|selected|-H|--","existing-account observations use only the explicit authorized noninteractive identity")
  if case=="accepted" then check(observed and observed.home=="/home/selected" and observed.executable=="/home/selected/.local/bin/native" and problem==nil,"account preparation exposes actual home/executable observation, not login/readiness")
  else check(observed==nil and problem:find("Selected-account prerequisite failed",1,true),"denial/identity mismatch cannot become a current-user fallback") end
 end
 calls={}
 prerequisite.account("-invalid","native","/work",function(account,why)check(account==nil and why~=nil,"invalid OS user refuses")end)
 check(#calls==0,"invalid OS user cannot reach a process")
end
return string.format("PASS %d SPAWN backend checks", checks)
