-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.
-- Reads requires.json and checks a plugin's Tern/plugin minimums. Pure: no `tern` global.
local Version = require("./version")

local Requires = {}

local function is_semver(v: any): boolean
	return type(v) == "string" and Version.parse(v) ~= nil
end

function Requires.read(text: string, decode: (string) -> any): ({ tern: string?, plugins: { [string]: string } }?, string?)
	local ok, data = pcall(decode, text)
	if not ok then
		return nil, "requires.json isn't valid JSON: " .. tostring(data)
	end
	if type(data) ~= "table" then
		return nil, "requires.json must be an object"
	end
	if data.schema ~= 1 then
		return nil, "requires.json schema must be 1 (got " .. tostring(data.schema) .. ")"
	end
	local tern_min = data.tern
	if tern_min ~= nil and not is_semver(tern_min) then
		return nil, "requires.json tern must be a SemVer string"
	end
	local plugins: { [string]: string } = {}
	if data.plugins ~= nil then
		if type(data.plugins) ~= "table" then
			return nil, "requires.json plugins must be an object"
		end
		-- An empty table may come back from the decoder as an empty array; treat as empty map.
		for id, min in data.plugins do
			if type(id) ~= "string" then
				return nil, "requires.json plugins must be an object"
			end
			if not is_semver(min) then
				return nil, "requires.json plugins." .. id .. " must be a SemVer string"
			end
			plugins[id] = min
		end
	end
	return { tern = tern_min, plugins = plugins }, nil
end

function Requires.tern_version(stdout: string): string?
	if type(stdout) ~= "string" then
		return nil
	end
	local v = string.match(stdout, "^%s*tern%s+(%S+)")
	if v and Version.parse(v) then
		return v
	end
	return nil
end

function Requires.check(req: { tern: string?, plugins: { [string]: string } }, tern: string?, installed: { [string]: string }): string?
	if req.tern then
		if tern == nil or Version.parse(tern) == nil then
			return "Can't tell this Tern's version; update Tern to " .. req.tern .. " or later first"
		end
		if Version.compare(tern, req.tern) == -1 then
			return "Needs Tern " .. req.tern .. " or later (this is " .. tern .. ")"
		end
	end
	local ids = {}
	for id in req.plugins do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local min = req.plugins[id]
		local have = installed[id]
		if have == nil then
			return "Install " .. id .. " " .. min .. " or later first"
		end
		local cmp = Version.compare(have, min)
		if cmp == nil or cmp == -1 then
			return "Update " .. id .. " to " .. min .. " or later first (you have " .. tostring(have) .. ")"
		end
	end
	return nil
end

return Requires
