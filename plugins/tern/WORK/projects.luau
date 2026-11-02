--!strict
-- Live Glitch workspace discovery. The registry is the same generated source that
-- workspaces.py and /work-on use; this pane owns no second project catalog.
local M = {}

local REGISTRY_MAX_BYTES = 4 * 1024 * 1024
local WORKSPACE_SLUG = "^[a-z0-9][a-z0-9%-]*$"

local function array()
	return {}
end

local function valid_text(value: any): boolean
	return type(value) == "string" and value ~= "" and not string.find(value, "[%c]", 1)
end

local function valid_slug(value: any): boolean
	return valid_text(value) and string.match(value, WORKSPACE_SLUG) ~= nil
end

local function valid_github_url(value: any): boolean
	return type(value) == "string"
		and string.match(value, "^https://github%.com/[^%s%c\"'<>]+$") ~= nil
end

local function github_url(value: any): string?
	if not valid_github_url(value) then return nil end
	local normalized = string.gsub(value, "%.git$", "")
	return normalized
end

local function brain_root(): string
	local plugin_dir = string.gsub(tern.plugin.dir, "\\", "/")
	local root = string.match(plugin_dir, "^(.*)/_local/[^/]+$")
	return if root ~= nil then root else plugin_dir
end

local function sort_items(items: { any })
	table.sort(items, function(left, right)
		local left_name = string.lower(left.name)
		local right_name = string.lower(right.name)
		if left_name == right_name then return left.id < right.id end
		return left_name < right_name
	end)
end

function M.empty()
	return { items = array() }
end

-- Convert the generated registry into the small view model the pane needs.
-- Only active workspaces are projects. Worktrees, mirrors and failed entries
-- remain invisible because /work-on does not treat them as independent projects.
function M.decode_registry(value: any, root: string)
	if type(value) ~= "table" or type(value.workspaces) ~= "table" then
		return nil, "workspace registry is invalid"
	end
	if not valid_text(root) then
		return nil, "workspace registry root is invalid"
	end

	local catalog = M.empty()
	for slug, entry in pairs(value.workspaces) do
		if valid_slug(slug) and type(entry) == "table" and entry.status == "active"
			and valid_slug(entry.path)
		then
			table.insert(catalog.items, {
				id = slug,
				name = slug,
				kind = if valid_text(entry.kind) then entry.kind else "workspace",
				path = root .. "/workspaces/" .. entry.path,
				remote = github_url(entry.remote),
			})
		end
	end
	sort_items(catalog.items)
	return catalog
end

function M.load()
	local root = brain_root()
	local registry_path = root .. "/workspaces/registry.json"
	local read_ok, text = pcall(tern.fs.read, registry_path, REGISTRY_MAX_BYTES)
	if not read_ok or type(text) ~= "string" then
		return M.empty(), "Could not read Glitch's workspace registry."
	end

	local decode_ok, value = pcall(tern.json.decode, text)
	if not decode_ok then
		return M.empty(), "Glitch's workspace registry is not valid JSON."
	end

	local catalog, problem = M.decode_registry(value, root)
	if catalog == nil then return M.empty(), problem end
	return catalog, nil
end

function M.find(catalog: any, workspace_id: string)
	for _, item in ipairs(catalog.items) do
		if item.id == workspace_id then return item end
	end
	return nil
end

function M.selection(catalog: any, selection: any)
	local selected_id = if type(selection) == "table" then selection.workspace_id else nil
	local item = if type(selected_id) == "string" then M.find(catalog, selected_id) else nil
	if item == nil then item = catalog.items[1] end
	return { workspace_id = if item then item.id else nil }
end

function M.load_selection(catalog: any)
	return M.selection(catalog, tern.kv.get("selection"))
end

function M.save_selection(selection: any)
	tern.kv.set("selection", selection)
end

function M.work_prompt(item: any): string
	return "Work on " .. item.name
end

local function url_encode(value: string): string
	return (string.gsub(value, "([^%w%-_%.~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

function M.work_on_url(workspace_id: string, cwd: string?): string
	local url = string.format("tern://work?workspace=%s", url_encode(workspace_id))
	if cwd ~= nil then url = url .. "&cwd=" .. url_encode(cwd) end
	return url
end

return M
