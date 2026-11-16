--!strict
-- Live Glitch workspace discovery. The registry is the same generated source that
-- workspaces.py and /work-on use; this pane owns no second project catalog.
local M = {}
local Config = require("./config")

type ConfiguredAgent = { kind: "acp" | "cli", argv: { string } }
type Workspace = {
	id: string,
	name: string,
	kind: string,
	path: string,
	remote: string?,
}
type Catalog = {
	items: { Workspace },
	root: string?,
	agent: ConfiguredAgent?,
}

local REGISTRY_MAX_BYTES = 4 * 1024 * 1024
local CONFIG_MAX_BYTES = 32 * 1024
local WORKSPACE_SLUG = "^[a-z0-9][a-z0-9%-]*$"

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

local function child_path(root: string, child: string): string
	return root .. (if string.sub(root, -1) == "/" then "" else "/") .. child
end

local function problem(code: string, message: string): string
	return code .. ": " .. message
end

local function host_config(): (any?, string?)
	local config_path = child_path(tern.plugin.data, "config.json")
	local exists_ok, exists = pcall(tern.fs.exists, config_path)
	if not exists_ok then
		return nil, problem("config_invalid", "Could not inspect WORK configuration: " .. config_path)
	end
	if exists then
		local read_ok, text = pcall(tern.fs.read, config_path, CONFIG_MAX_BYTES)
		if not read_ok then
			return nil, problem("config_invalid", "Could not read WORK configuration: " .. config_path)
		end
		local value, decode_problem = Config.decode(text, tern.json.decode)
		if value == nil then
			return nil, problem("config_invalid", tostring(decode_problem) .. ": " .. config_path)
		end
		local config, err = Config.validate(value, tern.runtime.os)
		if config ~= nil then return config, nil end
		if err == "setup_required" then
			local root = Config.normalize_root(value.glitch_root, tern.runtime.os)
			return { glitch_root = root }, problem("setup_required", "Configure an ACP or CLI agent argv in " .. config_path .. " on this host, then Refresh.")
		end
		return nil, problem("config_invalid", (err or "Invalid WORK configuration") .. ": " .. config_path)
	end

	local plugin_dir = Config.normalize_root(tern.plugin.dir, tern.runtime.os)
	local root = if plugin_dir ~= nil then string.match(plugin_dir, "^(.*)/_local/[^/]+$") else nil
	if root ~= nil and root ~= "" then
		return { glitch_root = root }, problem("setup_required", "Discovered Glitch folder " .. root .. ". Configure an ACP or CLI agent argv in " .. config_path .. " on this host, then Refresh.")
	end
	return nil, problem("setup_required", "Glitch folder not configured. Set glitch_root and an ACP or CLI agent argv in " .. config_path .. " on this host, then Refresh.")
end

local function json_object(value: any): boolean
	if type(value) ~= "table" then return false end
	local empty = true
	for key in pairs(value) do
		if type(key) ~= "string" then return false end
		empty = false
	end
	if not empty then return true end
	local encode_ok, encoded = pcall(tern.json.encode, value)
	return encode_ok and encoded == "{}"
end

local function sort_items(items: { Workspace })
	table.sort(items, function(left, right)
		local left_name = string.lower(left.name)
		local right_name = string.lower(right.name)
		if left_name == right_name then return left.id < right.id end
		return left_name < right_name
	end)
end

function M.empty(): Catalog
	return { items = {} }
end

-- Convert the generated registry into the small view model the pane needs.
-- Only active workspaces are projects. Worktrees, mirrors and failed entries
-- remain invisible because /work-on does not treat them as independent projects.
function M.decode_registry(value: any, root: string): (Catalog?, string?)
	if not json_object(value) or not json_object(value.workspaces) then
		return nil, "workspace registry is invalid"
	end
	if not valid_text(root) then
		return nil, "workspace registry root is invalid"
	end

	local catalog = M.empty()
	catalog.root = root
	for slug, entry in pairs(value.workspaces) do
		if valid_slug(slug) and type(entry) == "table" and entry.status == "active"
			and valid_slug(entry.path)
		then
			table.insert(catalog.items, {
				id = slug,
				name = slug,
				kind = if valid_text(entry.kind) then entry.kind else "workspace",
				path = child_path(root, "workspaces/" .. entry.path),
				remote = github_url(entry.remote),
			})
		end
	end
	sort_items(catalog.items)
	return catalog, nil
end

function M.load(context_only: boolean?): (Catalog, string?)
	local config, config_problem = host_config()
	if config == nil then return M.empty(), config_problem end
	local root = config.glitch_root
	if config_problem ~= nil and not (context_only and root ~= nil and string.match(config_problem, "^setup_required:")) then
		local catalog = M.empty()
		catalog.root = root
		return catalog, config_problem
	end
	local registry_path = child_path(root, "workspaces/registry.json")
	local read_ok, text = pcall(tern.fs.read, registry_path, REGISTRY_MAX_BYTES)
	if not read_ok or type(text) ~= "string" then
		return M.empty(), problem("registry_unreadable", "Could not read Glitch's workspace registry: " .. registry_path)
	end

	local decode_ok, value = pcall(tern.json.decode, text)
	if not decode_ok then
		return M.empty(), problem("registry_invalid", "Glitch's workspace registry is not valid JSON: " .. registry_path)
	end

	local catalog, registry_problem = M.decode_registry(value, root)
	if catalog == nil then return M.empty(), problem("registry_invalid", assert(registry_problem)) end
	catalog.agent = config.agent
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

function M.root_snapshot(): any
	local path = child_path(tern.plugin.data, "config.json")
	local ok, exists = pcall(tern.fs.exists, path)
	if not ok then return { error = "Cannot inspect WORK configuration." } end
	if not exists then return { exists = false } end
	local read_ok, bytes = pcall(tern.fs.read, path, CONFIG_MAX_BYTES)
	if not read_ok then return { error = "Cannot read WORK configuration." } end
	return { exists = true, text = bytes }
end

-- Root setup uses WORK's existing configuration, preserving any standalone agent.
-- No root is committed until its real host registry has been read and validated.
function M.configure_root(value: any, expected: any): (boolean, string?)
	local root = Config.normalize_root(value, tern.runtime.os)
	if root == nil or #root > 2048 then return false, "Enter an absolute Glitch folder on this execution host (at most 2048 bytes, without '..')." end
	local current = M.root_snapshot()
	if current.error then return false, current.error end
	if type(expected) ~= "table" or expected.error or current.exists ~= expected.exists or current.text ~= expected.text then return false, "WORK configuration changed. Refresh before saving the folder; no file was written." end
	local document = {}
	if current.exists then
		local decoded, problem = Config.decode(current.text, tern.json.decode)
		if decoded == nil then return false, problem end
		local valid, err = Config.validate(decoded, tern.runtime.os)
		if valid == nil and err ~= "setup_required" then return false, "Existing WORK configuration needs recovery before changing its folder: " .. tostring(err) end
		document = decoded
	end
	local read_ok, bytes = pcall(tern.fs.read, child_path(root, "workspaces/registry.json"), REGISTRY_MAX_BYTES)
	if not read_ok then return false, "Cannot read workspaces/registry.json in that folder on this execution host." end
	local decoded, registry = pcall(tern.json.decode, bytes)
	if not decoded or M.decode_registry(registry, root) == nil then return false, "That folder has no valid Glitch workspace registry." end
	document.glitch_root = root
	local encoded = tern.json.encode(document)
	if #encoded > CONFIG_MAX_BYTES then return false, "WORK configuration exceeds its size limit; no file was written." end
	local path = child_path(tern.plugin.data, "config.json")
	local write_ok, err = pcall(tern.fs.write, path, encoded)
	if not write_ok then return false, "Could not save the WORK folder: " .. tostring(err) end
	local saved = M.root_snapshot()
	if saved.text ~= encoded then return false, "WORK could not verify the saved folder. Inspect external edits before retrying." end
	return true, nil
end

-- Metadata discovery moved from ORCH's catalog adapter. This is a bounded
-- locator list, not a workflow parser: ORCH validates/parses the selected file.
function M.discover_plans(catalog: any, files: { any }): any
	local result = { items = {}, rejected = {} }
	local seen = {}
	for _, file in ipairs(files) do
		local name = file.name
		if type(name) ~= "string" or #name > 256 or name:find("[%c/\\]") or name:sub(1, 1) == "." or name:sub(-3):lower() ~= ".md" or name:lower():sub(-11) == "-archive.md" then continue end
		if seen[name] then
			for index = #result.items, 1, -1 do
				if result.items[index].name == name then table.remove(result.items, index) end
			end
			table.insert(result.rejected, name .. ": duplicate path")
			continue
		end
		seen[name] = true
		local bytes = file.bytes
		if type(bytes) ~= "string" or #bytes > 1024 * 1024 or utf8.len(bytes) == nil or bytes:find("%z") then
			table.insert(result.rejected, name .. ": unreadable or oversized plan")
			continue
		end
		local title, home, homes, section, fence = nil, nil, 0, nil, nil
		for line in (bytes .. "\n"):gmatch("(.-)\n") do
			line = line:gsub("\r$", "")
			local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
			if marker then
				if fence == nil then fence = marker:sub(1, 1)
				elseif marker:sub(1, 1) == fence then fence = nil end
				continue
			end
			if fence ~= nil then continue end
			local level, heading = line:match("^(#+)%s+(.+)$")
			if level then
				if #level <= 2 then section = if #level == 2 then heading else nil end
				if #level == 1 and title == nil then title = heading:match("^Feature:%s*(.+)$") end
			elseif section == "Build choices" then
				local value = line:match("^home:%s*(.-)%s*$")
				if value ~= nil then home = value; homes += 1 end
			end
		end
		if title ~= nil and #title > 256 then
			local offset = utf8.offset(title, 257)
			if offset ~= nil then title = title:sub(1, offset - 1) .. "…" end
		end
		local hint = if homes == 1 and home ~= nil then home:match("^workspace:([%w%-]+)$") else nil
		local workspace = if hint ~= nil then M.find(catalog, hint) else nil
		table.insert(result.items, { name = name, title = title or name, path = child_path(catalog.root, "plans/" .. name),
			workspace_id = if workspace ~= nil then workspace.id else nil, needs_project_choice = workspace == nil })
	end
	table.sort(result.items, function(a, b) return if a.title == b.title then a.path < b.path else a.title < b.title end)
	return result
end

function M.load_plans(catalog: any): any
	if catalog.root == nil then return { items = {}, rejected = { "Glitch root is unavailable." } } end
	local ok, names = pcall(tern.fs.list, child_path(catalog.root, "plans"))
	if not ok or type(names) ~= "table" or #names > 512 then return { items = {}, rejected = { "Plans directory is unreadable or exceeds 512 entries." } } end
	table.sort(names)
	local files, budget = {}, 8 * 1024 * 1024
	for _, name in ipairs(names) do
		if type(name) ~= "string" or #name > 256 or name:find("[%c/\\]") or name:sub(1, 1) == "." or name:sub(-3):lower() ~= ".md" or name:lower():sub(-11) == "-archive.md" then continue end
		if budget <= 0 then return { items = {}, rejected = { "Plan discovery exceeds the 8 MiB budget; narrow the plans folder." } } end
		local read_ok, bytes = pcall(tern.fs.read, child_path(catalog.root, "plans/" .. name), math.min(budget, 1024 * 1024))
		if read_ok and type(bytes) == "string" then budget -= #bytes end
		table.insert(files, { name = name, bytes = if read_ok then bytes else nil })
	end
	return M.discover_plans(catalog, files)
end

local function url_encode(value: string): string
	return (string.gsub(value, "([^%w%-_%.~])", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

-- Configured WORK ACP/CLI launches use the configured host agent. SPAWN rows are
-- held on every OS pending a native single-winner claim.
function M.work_on_url(workspace_id: string, cwd: string?, launch: any?): string
	local url = string.format("tern://work?workspace=%s", url_encode(workspace_id))
	if cwd ~= nil then url = url .. "&cwd=" .. url_encode(cwd) end
	if launch ~= nil then
		url = url .. "&agent=" .. url_encode(launch.agent)
			.. "&label=" .. url_encode(launch.label)
			.. "&delivery=" .. url_encode(launch.delivery)
			.. "&command=" .. url_encode(launch.command)
	end
	return url
end

return M
