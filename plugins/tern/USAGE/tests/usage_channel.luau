-- Real closed export adapter; deterministic companion/carrier boundaries.
local root = ...
local runtime, environment = tern, getfenv()
local checks = 0
local function check(ok, why) assert(ok, why); checks += 1 end
local reads, sent, acknowledgements = {}, {}, {}
local messages, blocked = {}, false
local endpoint = {
	settle = function(limit) check(limit == 4, "bounded settlement turn"); return 0 end,
	receive = function(limit) check(limit == 4, "bounded receive turn"); return messages end,
	send = function(value)
		if blocked then return nil, { code = "backpressure" } end
		table.insert(sent, value); return { id = value.id }
	end,
	ack = function(value) table.insert(acknowledgements, value); messages = {}; return true end,
}
local function read(kind, raw, done) table.insert(reads, { kind = kind, raw = raw, done = done }) end
local dependencies = {
	["./capacity"] = { request = function(raw, done) read("capacity", raw, done) end },
	["./display"] = { request = function(cache, raw, done) check(cache.identity == "existing", "same host presentation cache"); read("display", raw, done) end },
}
local chunk = assert(loadstring(runtime.fs.read(root .. "/usage_channel.luau")))
setfenv(chunk, setmetatable({ tern = runtime, require = function(name) return assert(dependencies[name]) end }, { __index = environment }))
local module = chunk()
local adapter = module.new({ identity = "existing" }, endpoint)
local request = '{"version":1,"request_id":"read-one","op":"snapshot"}'
local message = { peer = "orchplus", recipient = "usage", incarnation = "host-one", id = "message-one",
	route = "usage.display.request", binding = "one-read-binding", body = request }
messages = { message }
adapter.pump()
check(#reads == 1 and reads[1].raw == request and #sent == 0 and #acknowledgements == 0,
	"exact original request reaches read adapter; async receipt is not acknowledgement")
adapter.pump()
check(#reads == 1, "repeated unacknowledged carrier delivery does not repeat an in-flight read")
local response = { version = 1, display_only = true, request_id = "read-one", op = "snapshot", ok = false, status = "display_disabled", records = runtime.json.array() }
reads[1].done(response)
blocked = true
adapter.pump()
check(#sent == 0 and #acknowledgements == 0 and #reads == 1 and adapter.status().code == "backpressure",
	"backpressure retains response and request without re-reading or premature ACK")
blocked = false
adapter.pump()
check(#sent == 1 and #acknowledgements == 1 and sent[1].body == runtime.json.encode(response),
	"durable exact response is sent before acknowledging original request")
check(sent[1].binding == message.binding and sent[1].route == "usage.display.response" and sent[1].peer == "orchplus",
	"response stays on exact read binding and closed response route")
adapter.pump()
check(#sent == 1 and #reads == 1, "idle turn creates no messages or companion work")
local other = table.clone(message); other.id = "capacity-one"; other.route = "usage.capacity.request"
messages = { other }; adapter.pump()
check(reads[2].kind == "capacity" and reads[2].raw == request, "capacity uses existing separate service adapter")
local bad = table.clone(message); bad.id = "bad"; bad.route = "configure"
messages = { bad }; adapter.pump()
check(#reads == 2 and adapter.status().code == "invalid_route", "unknown route never reaches companion")
messages = {}
for index = 1, 10 do
	local item = table.clone(message); item.id = "bounded-" .. tostring(index); table.insert(messages, item)
end
adapter.pump()
check(adapter.status().pending == 4 and #reads == 5, "at most four outstanding read jobs including existing capacity request")
-- A thrown read is durably rejected, not retained as an unanswerable slot.
dependencies["./display"].decode = runtime.json.decode
dependencies["./display"].request = function() error("private provider detail") end
reads, sent, acknowledgements = {}, {}, {}
messages = { message }
local failed = module.new({ identity = "existing" }, endpoint)
failed.pump()
check(#sent == 0 and #acknowledgements == 0, "read exception waits for durable bounded rejection")
failed.pump()
local rejected = runtime.json.decode(sent[1].body)
check(rejected.ok == false and rejected.status == "internal_error" and rejected.request_id == "read-one"
	and #acknowledgements == 1 and failed.status().pending == 0, "read failure releases request after rejection publish")
check(not sent[1].body:find("private provider detail", 1, true), "private exception never enters carrier response")
return "PASS " .. tostring(checks) .. " host channel adapter checks"
