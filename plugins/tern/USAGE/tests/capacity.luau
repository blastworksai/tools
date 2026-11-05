-- Read-only native surface and original correlation; real module, synthetic I/O.
local root = ...
local runtime, environment = tern, getfenv()
local checks, calls, definition = 0, {}, nil
local function check(value, why) assert(value, why); checks += 1 end
local fake = table.clone(runtime)
fake.block = { define = function(name, value) check(name == "capacity", "native name"); definition = value end }
local companion = { request = function(op, payload, callback) table.insert(calls, { op = op, payload = payload, callback = callback }) end }
local chunk = assert(loadstring(runtime.fs.read(root .. "/capacity.luau")))
setfenv(chunk, setmetatable({ tern = fake, require = function(name) assert(name == "./companion"); return companion end }, { __index = environment }))
local module = chunk()
module.install()
local cx = { render = function() end }
local state = definition.init(cx, {}, nil)
local request = { version = 1, request_id = "one", op = "snapshot" }
check(module.decode(runtime.json.encode(request)).request_id == "one", "decode bounded request")
for _, op in { "configure", "usage_refresh", "shutdown", "profile_metadata", "pair_accept" } do
	check(module.decode(runtime.json.encode({ version = 1, request_id = "one", op = op })) == nil, "reject mutation " .. op)
end
check(module.decode(string.rep("x", 4097)) == nil, "bounded ingress")
check(module.decode(runtime.json.encode({ version = 1, request_id = "one", op = "snapshot", token = "secret" })) == nil, "no hidden fields")
definition.event(state, { ev = "action", act = "usage.capacity", value = runtime.json.encode(request) }, cx)
check(#calls == 1 and calls[1].op == "capacity", "only capacity RPC")
check(state.response.request_id == "one" and state.response.status == "pending", "pending correlation")
definition.event(state, { ev = "action", act = "usage.capacity", value = runtime.json.encode(request) }, cx)
check(#calls == 1, "one in-flight request per block")
calls[1].callback({ response = { version = 1, request_id = "one", op = "snapshot", ok = false, status = "export_disabled" } }, nil)
check(state.response.status == "export_disabled" and not state.busy, "producer denial preserved")
local view = definition.view(state, cx)
check(view.main ~= nil, "native response rendered")
local encoded = runtime.json.encode(view)
check(encoded:find(module.NODE, 1, true) ~= nil and encoded:find("USAGE_CAPACITY v1", 1, true) ~= nil, "keyed versioned response")
definition.event(state, { ev = "action", act = "configure", value = "{}" }, cx)
check(#calls == 1, "unrelated actions cannot mutate")
return "PASS " .. checks .. " capacity checks"
