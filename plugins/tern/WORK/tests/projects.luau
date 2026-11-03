--!strict
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local modules = {}
local environment = getfenv()
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	local module = chunk()
	modules[name] = module
	return module
end
local projects = load("./projects")

local function check(condition: boolean, message: string)
	if not condition then error(message) end
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

return true
