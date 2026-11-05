--!strict
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local chunk = assert(loadstring(tern.fs.read(root .. "/spawn.luau"), "spawn"))
local spawn = chunk()

local function check(condition: boolean, message: string)
	if not condition then error(message) end
end

local function record(id: string, fields: any): any
	local value = {
		id = id, provider = "Claude", account_label = "Work", backend = "local-terminal",
		enabled = true, include_all = true, command = "claude", arguments = {}, cwd = "/srv/glitch",
	}
	for key, field in pairs(fields) do value[key] = field end
	return value
end

local function store(agents: { any }): any
	return { authority = {
		version = 3, host_key = "host:vm",
		config = { schema = 2, hosts = {
			["host:vm"] = { schema = 2, agents = agents },
			["host:other"] = { schema = 2, agents = { record("elsewhere", {}) } },
		} },
	} }
end

-- Roster: the authority's own host bucket, in saved order, unusable records disabled.
local roster = spawn.decode(store({
	record("claude-work", { user = "claudework" }),
	record("off", { enabled = false }),
	record("blocked", { review_required = true, review_reason = "Check the path" }),
	record("bad=id", {}),
	record("kimi-x", { provider = "Kimi", account_label = "X" }),
	record("custom", { provider = "Mystery" }),
}), "linux")
check(roster.problem == nil, "current SPAWN store decodes")
check(#roster.agents == 5, "records without a plain id are left out; other hosts' buckets ignored")
check(roster.agents[1].id == "claude-work" and roster.agents[1].label == "Claude — Work", "SPAWN's label")
check(roster.agents[1].icon == "provider-anthropic" and roster.agents[1].disabled == nil, "enabled record with provider logo")
check(roster.agents[2].disabled == "Disabled in SPAWN Config", "disabled record stays listed, greyed")
check(roster.agents[3].disabled == "Check the path", "review reason shown")
check(roster.agents[4].icon == "provider-kimi-code", "Kimi logo")
check(roster.agents[5].icon == "sparkle", "unknown provider falls back to a generic mark")
check(spawn.find(roster, "kimi-x") == roster.agents[4] and spawn.find(roster, "nope") == nil, "find by record id")

local windows = spawn.decode(store({ record("claude-work", {}) }), "windows")
check(windows.agents[1].disabled ~= nil, "Windows hosts list agents but don't launch them")

local unreadable = spawn.decode({ authority = { config = { schema = 1 } } }, "linux")
check(unreadable.problem ~= nil and #unreadable.agents == 0, "unknown store format is reported, not guessed")

local prompt = "/work-on example-project"

-- A provider CLI run directly gets the prompt as its first-prompt argument.
local line, delivery = spawn.render(record("c", { arguments = { "--dangerously-skip-permissions" } }), prompt)
check(line == "SPAWN_PROVIDER=claude claude --dangerously-skip-permissions '/work-on example-project'", "claude positional prompt: " .. tostring(line))
check(delivery == "argument", "claude prompt delivered on the command line")

line, delivery = spawn.render(record("a", { provider = "Agy", command = "agy", arguments = { "--dangerously-skip-permissions" }, user = "agywork" }), prompt)
check(line == "SPAWN_PROVIDER=agy sudo -u agywork -H -- agy --dangerously-skip-permissions -i '/work-on example-project'", "agy -i prompt under the account: " .. tostring(line))
check(delivery == "argument", "agy prompt delivered on the command line")

-- A seat wrapper drops extra arguments: the prompt is typed, never appended.
line, delivery = spawn.render(record("s", { command = "/usr/local/bin/seat-launcher", arguments = { "claudework" }, user = "claudework" }), prompt)
check(line == "SPAWN_PROVIDER=claude sudo -u claudework -H -- /usr/local/bin/seat-launcher claudework", "seat wrapper line: " .. tostring(line))
check(delivery == "type", "seat wrapper prompt is typed")

line, delivery = spawn.render(record("k", { provider = "Kimi", command = "kimi", arguments = { "--yolo" } }), prompt)
check(delivery == "type" and not string.find(line, "work-on", 1, true), "Kimi has no interactive prompt flag")

-- A command that already starts with sudo isn't wrapped again; its last word is the CLI.
line, delivery = spawn.render(record("o", { provider = "OMP", backend = "native-agent", command = "sudo -u ompwork -H -- omp", arguments = { "--approval-mode", "yolo" }, user = "ompwork", prompt = "Hello" }), prompt)
check(line == "SPAWN_PROVIDER=omp sudo -u ompwork -H -- omp --approval-mode yolo '/work-on example-project'", "omp under sudo: " .. tostring(line))
check(delivery == "argument", "OMP gets WORK's prompt, not its saved startup prompt")

line = spawn.render(record("r", { backend = "ssh-command", host = "box", user = "me", key_path = "/k/id", cwd = "~/glitch" }), prompt)
check(line == "SPAWN_PROVIDER=claude ssh -t -i /k/id -- me@box 'cd \"$HOME/\"'\\''glitch'\\'' && claude '\\''/work-on example-project'\\'''", "ssh remote command: " .. tostring(line))

local missing, _, problem = spawn.render(record("m", { command = "" }), prompt)
check(missing == nil and problem ~= nil, "no command, no launch")
missing, _, problem = spawn.render(record("q", { command = "claude 'unterminated" }), prompt)
check(missing == nil and problem ~= nil, "unparsable command refused")
missing = spawn.render(record("z", { arguments = { "a\27b" } }), prompt)
check(missing == nil, "terminal control bytes refused")

return true
