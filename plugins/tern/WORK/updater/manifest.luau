-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.
-- Reads the top-level `id` and `version` from a plugin.toml.
-- Only top-level keys count: reading stops at the first table header ("[x]" / "[[x]]"),
-- so `[[blocks]]` ids never shadow the plugin id. Never raises.
local Manifest = {}

local BOM = "\239\187\191"

local SIMPLE_ESCAPES = {
	b = "\b",
	t = "\t",
	n = "\n",
	f = "\f",
	r = "\r",
	e = "\27",
	['"'] = '"',
	["\\"] = "\\",
}

-- True when only whitespace or a comment follows position i.
local function rest_ok(s: string, i: number): boolean
	local rest = string.sub(s, i)
	return string.match(rest, "^[ \t]*$") ~= nil or string.match(rest, "^[ \t]*#") ~= nil
end

local function codepoint(hex: string): string?
	local n = tonumber(hex, 16)
	if not n or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF) then
		return nil
	end
	return utf8.char(n)
end

-- s starts just after the opening quote of a single-line basic string.
local function basic(s: string): string?
	local out = {}
	local i = 1
	local len = #s
	while i <= len do
		local c = string.sub(s, i, i)
		if c == '"' then
			if not rest_ok(s, i + 1) then
				return nil
			end
			return table.concat(out)
		elseif c == "\\" then
			local e = string.sub(s, i + 1, i + 1)
			local simple = SIMPLE_ESCAPES[e]
			if simple then
				table.insert(out, simple)
				i += 2
			elseif e == "u" or e == "U" or e == "x" then
				local n = if e == "u" then 4 elseif e == "U" then 8 else 2
				local hex = string.sub(s, i + 2, i + 1 + n)
				if #hex ~= n or not string.match(hex, "^%x+$") then
					return nil
				end
				local ch = codepoint(hex)
				if not ch then
					return nil
				end
				table.insert(out, ch)
				i += 2 + n
			else
				return nil
			end
		else
			table.insert(out, c)
			i += 1
		end
	end
	return nil -- unterminated
end

-- s starts just after the opening quote of a literal string.
local function literal(s: string): string?
	local close = string.find(s, "'", 1, true)
	if not close or not rest_ok(s, close + 1) then
		return nil
	end
	return string.sub(s, 1, close - 1)
end

local function string_value(v: string): string?
	local first = string.sub(v, 1, 1)
	if first == '"' then
		return basic(string.sub(v, 2))
	elseif first == "'" then
		return literal(string.sub(v, 2))
	end
	return nil
end

-- Net bracket depth change across a line, ignoring brackets inside strings and comments.
local function depth_delta(line: string): number
	local delta = 0
	local quote: string? = nil
	local i = 1
	local len = #line
	while i <= len do
		local c = string.sub(line, i, i)
		if quote then
			if quote == '"' and c == "\\" then
				i += 1
			elseif c == quote then
				quote = nil
			end
		elseif c == '"' or c == "'" then
			quote = c
		elseif c == "#" then
			break
		elseif c == "[" or c == "{" then
			delta += 1
		elseif c == "]" or c == "}" then
			delta -= 1
		end
		i += 1
	end
	return delta
end

local function match_key(t: string): (string?, string?)
	local key, v = string.match(t, "^([%w_-]+)[ \t]*=[ \t]*(.*)$")
	if not key then
		key, v = string.match(t, '^"([^"\\]*)"[ \t]*=[ \t]*(.*)$')
	end
	if not key then
		key, v = string.match(t, "^'([^']*)'[ \t]*=[ \t]*(.*)$")
	end
	return key, v
end

function Manifest.read(text: any): { id: string?, version: string? }
	local result = {}
	if type(text) ~= "string" then
		return result
	end
	pcall(function()
		local body = text
		if string.sub(body, 1, 3) == BOM then
			body = string.sub(body, 4)
		end
		local multiline: string? = nil -- closing delimiter of an open multi-line string
		local depth = 0 -- open brackets of a multi-line array / inline table
		for raw in string.gmatch(body .. "\n", "([^\n]*)\n") do
			local line = (string.gsub(raw, "\r$", ""))
			if multiline then
				if string.find(line, multiline, 1, true) then
					multiline = nil
				end
			elseif depth > 0 then
				depth = math.max(0, depth + depth_delta(line))
			else
				local t = (string.gsub(line, "^[ \t]+", ""))
				if string.sub(t, 1, 1) == "[" then
					break
				end
				local key, v = match_key(t)
				if key and v then
					local opener = string.sub(v, 1, 3)
					local first = string.sub(v, 1, 1)
					if opener == '"""' or opener == "'''" then
						if not string.find(v, opener, 4, true) then
							multiline = opener
						end
					elseif first == "[" or first == "{" then
						depth = math.max(0, depth_delta(v))
					elseif (key == "id" or key == "version") and result[key] == nil then
						result[key] = string_value(v)
					end
				end
			end
		end
	end)
	return result
end

return Manifest
