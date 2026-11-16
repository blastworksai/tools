--!strict
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local environment = getfenv()
local function module_loader(host_tern: any)
	local modules = {}
	local function load_module(name: string)
		name = name:gsub("^%./", "")
		if modules[name] ~= nil then return modules[name] end
		local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
		setfenv(chunk, setmetatable({ tern = host_tern, require = load_module }, { __index = environment }))
		local module = chunk()
		modules[name] = module
		return module
	end
	return load_module
end
local load = module_loader(tern)
local projects = load("./projects")
local Config = load("./config")

local function check(condition: boolean, message: string)
	if not condition then error(message) end
end

local function problem_code(value: any): string?
	if type(value) ~= "string" then return nil end
	return string.match(value, "^([a-z_]+):")
end

local function check_problem(value: any, expected: string, message: string)
	check(problem_code(value) == expected, message .. ": " .. tostring(value))
end

local function encoded_config(glitch_root: string, kind: string?, argv: any?): string
	return tern.json.encode({
		glitch_root = glitch_root,
		agent = { kind = kind or "cli", argv = argv or { "agent", "--prompt" } },
	})
end

local registry = {
	workspaces = {
		["zeta-project"] = {
			status = "active",
			kind = "coding",
			path = "zeta-project",
			remote = "https://github.com/example/zeta-project.git",
		},
		["alpha-project"] = {
			status = "active",
			kind = "operations",
			path = "alpha-project",
			remote = "https://github.com/example/alpha-project",
		},
		["alpha-project--task"] = {
			status = "worktree",
			kind = "worktree-of:alpha-project",
			path = "alpha-project--task",
		},
		["hidden-project"] = {
			status = "failed",
			kind = "coding",
			path = "hidden-project",
		},
	},
}

local test_root = "/glitch"
local catalog, problem = projects.decode_registry(registry, test_root)
check(catalog ~= nil and problem == nil, "decode active registry")
check(#catalog.items == 2, "only active workspaces are listed")
check(catalog.items[1].id == "alpha-project", "active workspaces are sorted")
check(catalog.items[1].remote == "https://github.com/example/alpha-project", "remote normalized")
check(catalog.items[2].path == test_root .. "/workspaces/zeta-project", "workspace path resolved")

local selected = projects.selection(catalog, { workspace_id = "zeta-project" })
check(selected.workspace_id == "zeta-project", "selection retained")
local fallback = projects.selection(catalog, { workspace_id = "missing" })
check(fallback.workspace_id == "alpha-project", "stale selection falls back")
check(projects.selection(projects.empty(), nil).workspace_id == nil, "empty selection")

local invalid = projects.decode_registry({ workspaces = "bad" }, test_root)
check(invalid == nil, "reject malformed registry")
local invalid_path = projects.decode_registry({
	workspaces = {
		bad = { status = "active", path = "../outside" },
	},
}, test_root)
check(invalid_path ~= nil and #invalid_path.items == 0, "reject unsafe workspace path")
check(projects.decode_registry(tern.json.decode('{"workspaces":[]}'), test_root) == nil, "reject empty registry array")
check(projects.decode_registry(tern.json.decode('{"workspaces":[{"status":"active","path":"one"}]}'), test_root) == nil, "reject nonempty registry array")
check(projects.decode_registry(tern.json.decode("[]"), test_root) == nil, "reject registry root array")
local empty_object = projects.decode_registry(tern.json.decode('{"workspaces":{}}'), test_root)
check(empty_object ~= nil and #empty_object.items == 0, "accept empty registry object")

local acp, acp_err = Config.validate({
	glitch_root = "/glitch/",
	agent = { kind = "acp", argv = { "acp-agent", "--prompt", "", "two words", 'quote"', "λ" } },
}, "macos")
check(acp ~= nil and acp_err == nil, "validate ACP argv")
check(acp.glitch_root == "/glitch" and acp.agent.kind == "acp", "normalized ACP config")
check(#acp.agent.argv == 6 and acp.agent.argv[3] == "" and acp.agent.argv[4] == "two words", "ACP argv remains structured")
local cli, cli_err = Config.validate({
	glitch_root = "C:\\Users\\einh\\Glitch\\",
	agent = { kind = "cli", argv = { "C:\\Program Files\\agent\\agent.exe", "--flag", "value" } },
})
check(cli ~= nil and cli_err == nil, "validate CLI argv without host annotation")
check(cli.glitch_root == "C:/Users/einh/Glitch" and cli.agent.argv[1] == "C:\\Program Files\\agent\\agent.exe", "CLI executable and root are not command-parsed")
local opaque, opaque_err = Config.validate({
	glitch_root = "/glitch",
	agent = { kind = "cli", argv = { "agent --not-split" } },
}, "linux")
check(opaque ~= nil and opaque_err == nil and #opaque.agent.argv == 1, "argv elements are never split into commands")
local maximum_argv = {}
for index = 1, 64 do maximum_argv[index] = "arg" .. tostring(index) end
local maximum, maximum_err = Config.validate({ glitch_root = "/glitch", agent = { kind = "cli", argv = maximum_argv } }, "linux")
check(maximum ~= nil and maximum_err == nil and #maximum.agent.argv == 64, "bounded argv accepts its documented maximum")
local missing_agent, missing_agent_err = Config.validate({ glitch_root = "/glitch" }, "linux")
check(missing_agent == nil and missing_agent_err == "setup_required", "root-only config requires setup")

local literal_null = {
	glitch_root = "/null/glitch",
	agent = { kind = "cli", argv = { "agent", "null", 'quoted "null"', "backslash\\", '\\\"null' } },
}
local literal_decoded = assert(Config.decode(tern.json.encode(literal_null), tern.json.decode))
check(Config.validate(literal_decoded, "linux") ~= nil, "null text inside JSON strings remains valid")
for index, argument in ipairs(literal_null.agent.argv) do
	check(literal_decoded.agent.argv[index] == argument, "JSON string escapes retain literal argv")
end

local invalid_configs = {
	false,
	{},
	{ glitch_root = "/glitch", extra = true },
	{ glitch_root = "/glitch", agent = "cli" },
	{ glitch_root = "/glitch", agent = { kind = "ACP", argv = { "agent" } } },
	{ glitch_root = "/glitch", agent = { kind = "cli" } },
	{ glitch_root = "/glitch", agent = { kind = "cli", argv = "agent --combined" } },
	{ glitch_root = "/glitch", agent = { kind = "cli", argv = {} } },
	{ glitch_root = "/glitch", agent = { kind = "cli", argv = { "" } } },
	{ glitch_root = "/glitch", agent = { kind = "cli", argv = { "agent", [3] = "gap" } } },
	{ glitch_root = "/glitch", agent = { kind = "cli", argv = { command = "agent" } } },
	{ glitch_root = "/glitch", agent = { kind = "cli", argv = { "agent", false } } },
	{ glitch_root = "/glitch", agent = { kind = "cli", argv = { "agent", "line\nfeed" } } },
	{ glitch_root = "/glitch", agent = { kind = "cli", argv = { "agent", string.rep("x", 4097) } } },
	{ glitch_root = "/glitch", agent = { kind = "cli", argv = { "agent" }, extra = true } },
}
local too_many = {}
for index = 1, 65 do too_many[index] = "arg" end
table.insert(invalid_configs, { glitch_root = "/glitch", agent = { kind = "cli", argv = too_many } })
for index, value in invalid_configs do
	local normalized, err = Config.validate(value, "linux")
	check(normalized == nil and type(err) == "string" and err ~= "setup_required", "reject malformed agent config " .. tostring(index))
end

check(Config.normalize_root("C:\\", "windows") == "C:/", "normalize drive root")
check(Config.normalize_root("C:\\Users\\einh\\Glitch\\", "windows") == "C:/Users/einh/Glitch", "normalize drive path")
check(Config.normalize_root("\\\\server\\share\\Glitch\\", "windows") == "//server/share/Glitch", "normalize UNC path")
check(Config.normalize_root("/Users/einh/Library\\ Mobile/Glitch/", "macos") == "/Users/einh/Library\\ Mobile/Glitch", "preserve macOS backslash")
check(Config.normalize_root("/opt/Glitch\\Archive/", "linux") == "/opt/Glitch\\Archive", "preserve Linux backslash")
check(Config.normalize_root("C:/Users/einh/Glitch", "macos") == nil, "drive path is not absolute on macOS")
check(Config.normalize_root("\\\\server\\share\\Glitch", "linux") == nil, "UNC path is not absolute on Linux")
check(Config.normalize_root("/bad/../root", "linux") == nil, "reject parent path")
check(Config.normalize_root("/bad\nroot", "linux") == nil, "reject root control character")

local config_path = "/native-data/tern-work/config.json"
local registry_text = tern.json.encode(registry)
local function fixture(plugin_dir: string, files: any, unreadable: string?, host_os: string?)
	local fake_tern = {
		plugin = { dir = plugin_dir, data = "/native-data/tern-work" },
		runtime = { os = host_os or "linux" },
		json = tern.json,
		fs = {
			exists = function(path: string): boolean return files[path] ~= nil end,
			read = function(path: string, maximum: number): string
				if path == unreadable then error("permission denied") end
				local text = files[path]
				assert(type(text) == "string", "missing fixture file: " .. path)
				assert(#text <= maximum, "file exceeds read bound")
				return text
			end,
			write = function(path: string, bytes: string) files[path] = bytes end,
		},
	}
	return module_loader(fake_tern)("./projects")
end

local installed = "/native/plugins/tern-work"
local files = {
	[config_path] = encoded_config("/glitch/", "acp", { "acp-agent", "--stdio" }),
	["/glitch/workspaces/registry.json"] = registry_text,
}
local discovery = fixture(installed, files)
local found, found_problem = discovery.load()
check(found_problem == nil and #found.items == 2, "cold installed package reads configured host registry")
check(found.root == "/glitch" and found.items[1].path == "/glitch/workspaces/alpha-project", "catalog binds normalized root")
check(found.agent.kind == "acp" and #found.agent.argv == 2 and found.agent.argv[1] == "acp-agent", "catalog carries structured host agent")
files[config_path] = encoded_config("/another-brain", "cli", { "other-agent" })
check(found.root == "/glitch" and found.agent.kind == "acp", "loaded catalog retains root and agent when configuration changes")
local changed, changed_problem = discovery.load()
check_problem(changed_problem, "registry_unreadable", "missing configured registry is an unreadable-registry error")
check(changed.root == nil and changed.agent == nil and #changed.items == 0, "unreadable registry never retains another catalog")

local missing, missing_problem = fixture(installed, {}).load()
check_problem(missing_problem, "setup_required", "0.5.0 installed copy with no config requires setup")
check(missing.root == nil and #missing.items == 0, "missing config has no silent agent or root default")
local legacy, legacy_problem = fixture("/glitch/_local/tern-projects", {
	["/glitch/workspaces/registry.json"] = registry_text,
}).load()
check_problem(legacy_problem, "setup_required", "linked legacy copy with no agent config requires setup")
check(legacy.root == "/glitch", "linked upgrade exposes its discovered Glitch root during setup")
check(#legacy.items == 0 and legacy.agent == nil, "legacy discovery never falls back to a client agent")
local root_only, root_only_problem = fixture(installed, {
	[config_path] = tern.json.encode({ glitch_root = "/glitch/" }),
	["/glitch/workspaces/registry.json"] = registry_text,
}).load()
check_problem(root_only_problem, "setup_required", "0.5.1 root-only upgrade requires agent setup")
check(root_only.root == "/glitch", "root-only upgrade exposes its normalized explicit root during setup")
check(#root_only.items == 0 and root_only.agent == nil, "root-only upgrade never uses a default agent")

for _, configured in ipairs({
	"{",
	"false",
	"[]",
	"{}",
	'{"glitch_root":"relative"}',
	'{"glitch_root":"/bad/../root"}',
	'{"glitch_root":"/bad\\nroot"}',
	'{"glitch_root":"/glitch","agent":{"kind":"cli","argv":[]}}',
	'{"glitch_root":"/glitch","agent":{"kind":"cli","argv":"agent --combined"}}',
	'{"glitch_root":"/glitch","unknown":null}',
	'{"glitch_root":"/glitch","agent":null}',
	'{"glitch_root":"/glitch","agent":{"kind":"cli","argv":["agent"],"unknown":null}}',
	'{"glitch_root":"/glitch","agent":{"kind":"cli","argv":["agent",null]}}',
}) do
	local invalid_catalog, invalid_problem = fixture("/glitch/_local/tern-projects", {
		[config_path] = configured,
		["/glitch/workspaces/registry.json"] = registry_text,
	}).load()
	check_problem(invalid_problem, "config_invalid", "invalid explicit config must not fall back to linked root")
	check(invalid_catalog.root == nil and #invalid_catalog.items == 0, "invalid config returns no catalog")
end

local precedence, precedence_problem = fixture("/old/_local/tern-projects", {
	[config_path] = encoded_config("/glitch", "cli", { "host-agent", "--one" }),
	["/glitch/workspaces/registry.json"] = registry_text,
}).load()
check(precedence_problem == nil and precedence.root == "/glitch", "explicit config overrides legacy inference")
check(precedence.agent.kind == "cli" and precedence.agent.argv[2] == "--one", "explicit CLI config reaches catalog")
local unreadable, unreadable_problem = fixture("/glitch/_local/tern-projects", {
	[config_path] = "{}",
	["/glitch/workspaces/registry.json"] = registry_text,
}, config_path).load()
check_problem(unreadable_problem, "config_invalid", "unreadable config does not fall back")

for _, host_root in ipairs({ "C:\\Users\\einh\\Glitch\\", "\\\\server\\share\\Glitch\\" }) do
	local normalized = host_root:gsub("\\", "/"):gsub("/+$", "")
	local windows, windows_problem = fixture("C:/native/plugins/tern-work", {
		[config_path] = encoded_config(host_root, "cli", { "C:\\Tools\\agent.exe", "" }),
		[normalized .. "/workspaces/registry.json"] = registry_text,
	}, nil, "windows").load()
	check(windows_problem == nil and windows.root == normalized, "Windows host roots are normalized independently of package location")
	check(windows.items[2].path == normalized .. "/workspaces/zeta-project", "Windows workspace path uses configured host root")
	check(windows.agent.argv[1] == "C:\\Tools\\agent.exe" and windows.agent.argv[2] == "", "Windows argv is preserved exactly")
end

local mac_root = "/Users/einh/Glitch\\Archive/"
local mac_normalized = "/Users/einh/Glitch\\Archive"
local mac, mac_problem = fixture("/Users/einh/tern-work", {
	[config_path] = encoded_config(mac_root, "acp", { "acp-agent" }),
	[mac_normalized .. "/workspaces/registry.json"] = registry_text,
}, nil, "macos").load()
check(mac_problem == nil and mac.root == mac_normalized, "macOS backslash survives root normalization")
check(mac.items[1].path == mac_normalized .. "/workspaces/alpha-project", "macOS backslash survives workspace paths")

for _, contents in ipairs({
	"{",
	"[]",
	'{"workspaces":false}',
	'{"workspaces":[]}',
	'{"workspaces":[{"status":"active","path":"one"}]}',
}) do
	local broken, broken_problem = fixture(installed, {
		[config_path] = encoded_config("/glitch"),
		["/glitch/workspaces/registry.json"] = contents,
	}).load()
	check_problem(broken_problem, "registry_invalid", "invalid registry is an error, not an empty registry")
	check(#broken.items == 0 and broken.agent == nil, "invalid registry returns no agent catalog")
end
local empty, empty_problem = fixture(installed, {
	[config_path] = encoded_config("/glitch"),
	["/glitch/workspaces/registry.json"] = '{"workspaces":{}}',
}).load()
check(empty_problem == nil and #empty.items == 0 and empty.root == "/glitch", "valid empty registry object is successful")
check(empty.agent.kind == "cli" and #empty.agent.argv == 2, "empty registry still carries validated host agent")
local registry_unreadable, registry_unreadable_problem = fixture(installed, {
	[config_path] = encoded_config("/glitch"),
	["/glitch/workspaces/registry.json"] = registry_text,
}, "/glitch/workspaces/registry.json").load()
check_problem(registry_unreadable_problem, "registry_unreadable", "registry read failure is distinct from invalid JSON")

local context_catalog, context_problem = fixture(installed, {
	[config_path] = tern.json.encode({ glitch_root = "/glitch" }),
	["/glitch/workspaces/registry.json"] = registry_text,
}).load(true)
check(context_problem == nil and #context_catalog.items == 2 and context_catalog.agent == nil, "orchestration discovery does not require a standalone launch agent")
local root_files = { ["/configured/glitch/workspaces/registry.json"] = registry_text }
local root_setup = fixture(installed, root_files)
local snapshot = root_setup.root_snapshot()
check(root_setup.configure_root("/configured/glitch", snapshot), "clean installed WORK can save its real root without configuring an agent")
local configured_root = tern.json.decode(root_files[config_path])
check(configured_root.glitch_root == "/configured/glitch" and configured_root.agent == nil, "root-only setup creates no agent/default launch route")
check(#root_setup.load(true).items == 2, "configured root enables context discovery")
local before = root_files[config_path]
check(not root_setup.configure_root("/missing", root_setup.root_snapshot()), "missing host registry refuses root configuration")
check(root_files[config_path] == before, "invalid root leaves configuration unchanged")
local expected = root_setup.root_snapshot()
root_files[config_path] = encoded_config("/configured/glitch", "acp", { "real-acp", "--stdio" })
check(not root_setup.configure_root("/configured/glitch", expected), "external config edits refuse stale root setup")
check(root_setup.configure_root("/configured/glitch", root_setup.root_snapshot()), "root setup preserves a configured standalone agent")
check(tern.json.decode(root_files[config_path]).agent.argv[1] == "real-acp", "standalone ACP identity is preserved")
local plans = projects.discover_plans(catalog, {
	{ name = "active.md", bytes = "# Feature: Active\n## Build choices\nhome: workspace:alpha-project\n" },
	{ name = "ambiguous.md", bytes = "# Feature: Ambiguous\n## Build choices\nhome: workspace:alpha-project\nhome: workspace:zeta-project\n" },
	{ name = "unknown.md", bytes = "# Feature: Unknown\n## Build choices\nhome: workspace:missing\n" },
	{ name = "old-archive.md", bytes = "# Feature: Archived\n" },
	{ name = "archive/old.md", bytes = "# Feature: Archived directory\n" },
	{ name = "fenced.md", bytes = "# Feature: Fenced\n## Build choices\n```\nhome: workspace:alpha-project\n```\n" },
})
check(#plans.items == 4, "only root unarchived Markdown plans are discoverable")
local plan_by_name = {}
for _, plan in ipairs(plans.items) do plan_by_name[plan.name] = plan end
check(plan_by_name["active.md"].workspace_id == "alpha-project", "explicit home metadata associates the project")
check(plan_by_name["ambiguous.md"].needs_project_choice, "ambiguous homes require an explicit in-pane choice")
check(plan_by_name["unknown.md"].needs_project_choice, "missing registry association stays explicit")
check(plan_by_name["fenced.md"].needs_project_choice, "fenced examples cannot bind project context")
check(#projects.discover_plans(catalog, {
	{ name = "same.md", bytes = "# Feature: One\n" },
	{ name = "same.md", bytes = "# Feature: Two\n" },
}).items == 0, "duplicate plan paths are refused")

return true
