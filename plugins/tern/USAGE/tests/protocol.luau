-- Run in real Tern with the same wire corpus consumed by Python.
local root = ...
assert(type(root) == "string", "pass the plugin directory")
local modules, environment = {}, getfenv()
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load }, { __index = environment }))
	modules[name] = chunk()
	return modules[name]
end
local snapshot = load("snapshot")
local function equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in a do if not equal(v, b[k]) then return false end end
	for k, v in b do if not equal(v, a[k]) then return false end end
	return true
end
local count = 0
for _, case in tern.json.decode(tern.fs.read(root .. "/tests/fixtures/snapshots.json")) do
	local value, diagnostic = snapshot.decode(case.raw)
	assert((value ~= nil) == case.accepted, case.name .. ": acceptance differs: " .. tostring(diagnostic))
	if value ~= nil then assert(equal(value, case.expected), case.name .. ": projection differs") end
	count += 1
	-- Yield between cases so no Tern driver slice accumulates several of them.
	if type(await) == "function" then await(tern.sleep(0)) end
end
return "PASS " .. tostring(count) .. " shared wire cases"
