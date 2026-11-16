--!strict
-- Native edit offsets are UTF-16; WORK's fallback key handlers retain byte cursors.
local M = {}
function M.length(text: string): number
	local count = 0
	for _, code in utf8.codes(text) do count += if code > 65535 then 2 else 1 end
	return count
end
local function boundary(text: string, units: any): number?
	if type(units) ~= "number" or units < 0 or units % 1 ~= 0 then return nil end
	local count = 0
	for byte, code in utf8.codes(text) do
		if count == units then return byte - 1 end
		count += if code > 65535 then 2 else 1
		if count > units then return nil end
	end
	return if count == units then #text else nil
end
function M.apply(text: string, event: any, maximum: number): (string?, number?)
	if event.len ~= M.length(text) or type(event.text) ~= "string" or utf8.len(event.text) == nil or event.text:find("%c") then return nil, nil end
	local first, last = boundary(text, event.from), boundary(text, event.to)
	if first == nil or last == nil or last < first then return nil, nil end
	if #text - (last - first) + #event.text > maximum then return nil, nil end
	local value = text:sub(1, first) .. event.text .. text:sub(last + 1)
	local cursor = boundary(value, event.cursor)
	if cursor == nil then return nil, nil end
	return value, cursor
end
function M.remember(history: any, text: string, cursor: number)
	if #history >= 30 then table.remove(history, 1) end
	table.insert(history, { text = text, cursor = cursor })
end
return M
