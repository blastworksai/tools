--!strict
-- SemVer 2.0 parsing and §11 precedence. Pure: never reads the `tern` global.
local Version = {}

export type Parsed = { major: number, minor: number, patch: number, pre: { string | number } }

local function numeric(s: string): number?
	if s:match("^%d+$") == nil then
		return nil
	end
	if #s > 1 and s:sub(1, 1) == "0" then
		return nil
	end
	return tonumber(s)
end

-- Splits a dot-separated identifier list; nil when any identifier is empty
-- or holds characters outside [0-9A-Za-z-].
local function identifiers(s: string): { string }?
	local out = {}
	local start = 1
	while true do
		local dot = s:find(".", start, true)
		local id = s:sub(start, (dot or #s + 1) - 1)
		if id == "" or id:match("^[%w%-]+$") == nil then
			return nil
		end
		table.insert(out, id)
		if dot == nil then
			return out
		end
		start = dot + 1
	end
end

function Version.parse(s: string): Parsed?
	if type(s) ~= "string" then
		return nil
	end
	local text = s
	if text:sub(1, 1) == "v" then
		text = text:sub(2)
	end
	local plus = text:find("+", 1, true)
	if plus then
		if identifiers(text:sub(plus + 1)) == nil then
			return nil
		end
		text = text:sub(1, plus - 1)
	end
	local ma, mi, pa, rest = text:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
	if ma == nil or mi == nil or pa == nil or rest == nil then
		return nil
	end
	local major, minor, patch = numeric(ma), numeric(mi), numeric(pa)
	if major == nil or minor == nil or patch == nil then
		return nil
	end
	local pre: { string | number } = {}
	if rest ~= "" then
		if rest:sub(1, 1) ~= "-" then
			return nil
		end
		local ids = identifiers(rest:sub(2))
		if ids == nil then
			return nil
		end
		for _, id in ids do
			if id:match("^%d+$") then
				local n = numeric(id)
				if n == nil then
					return nil
				end
				table.insert(pre, n)
			else
				table.insert(pre, id)
			end
		end
	end
	return { major = major, minor = minor, patch = patch, pre = pre }
end

local function cmp(x: any, y: any): number
	if x < y then
		return -1
	elseif x > y then
		return 1
	end
	return 0
end

function Version.compare(a: string, b: string): number?
	local x, y = Version.parse(a), Version.parse(b)
	if x == nil or y == nil then
		return nil
	end
	for _, key in { "major", "minor", "patch" } do
		local c = cmp((x :: any)[key], (y :: any)[key])
		if c ~= 0 then
			return c
		end
	end
	local px, py = x.pre, y.pre
	-- A pre-release sorts below its release.
	if #px == 0 or #py == 0 then
		return cmp(#py, #px)
	end
	for i = 1, math.min(#px, #py) do
		local ix, iy = px[i], py[i]
		local tx, ty = type(ix), type(iy)
		if tx ~= ty then
			-- Numeric identifiers sort below alphanumeric ones.
			return if tx == "number" then -1 else 1
		end
		local c = cmp(ix, iy)
		if c ~= 0 then
			return c
		end
	end
	return cmp(#px, #py)
end

return Version
