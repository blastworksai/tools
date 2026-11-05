-- Host-run Setup on the config block: bounded requests onto this host's own companion; real module, synthetic I/O.
local root = ...
local runtime, environment = tern, getfenv()
local checks, calls, changes = 0, {}, 0
local function check(value, why) assert(value, why); checks += 1 end
local companion = {
	ensure = function(callback, options) table.insert(calls, { op = "ensure", options = options, callback = callback }) end,
	request = function(op, payload, callback) table.insert(calls, { op = op, payload = payload, callback = callback }) end,
}
local chunk = assert(loadstring(runtime.fs.read(root .. "/host_setup.luau")))
setfenv(chunk, setmetatable({ tern = runtime, require = function(name) assert(name == "./companion"); return companion end }, { __index = environment }))
local module = chunk()
local renders = 0
local cx = { render = function() renders += 1 end }
local state = module.new()
local function changed() changes += 1 end
local serial = 0
local function request(op, payload)
	serial += 1
	return { version = 1, request_id = "window-" .. tostring(serial), op = op, payload = payload }
end
local function send(value)
	module.event(state, { ev = "action", act = module.ACTION, value = runtime.json.encode(value) }, cx, changed)
	return value
end
local function reply(op, value, err)
	local pending = table.remove(calls, 1)
	assert(pending ~= nil and pending.op == op, "Expected " .. op)
	pending.callback(value, err, nil)
	return pending
end
local function rejects(op, payload, why)
	check(module.decode(runtime.json.encode(request(op, payload))) == nil, why)
end
for _, op in { "usage_refresh", "pair_accept", "pair_offer", "unpair", "capacity", "diagnostics", "usage_publish", "register_client" } do
	rejects(op, {}, "host Setup cannot select companion operation " .. op)
end
rejects("configure", { changes = { export_enabled = true }, consent = { export = true } }, "sharing/export is never configurable from an attached window")
rejects("configure", { changes = { role = "hub" } }, "role changes are never configurable from an attached window")
rejects("configure", { changes = { metadata_enabled = true } }, "enabling headless reads needs its own consent")
rejects("configure", { changes = { metadata_enabled = true, capacity_enabled = true }, consent = { metadata = true, capacity = true } }, "one setting per confirmed change")
rejects("configure", { changes = { capacity_enabled = true }, consent = { metadata = true } }, "consent must name the setting it changes")
rejects("configure", { binding_action = { operation = "bind", scope_id = "s", id = "a", definition_revision = "r", canonical_id = "c" } }, "a binding needs binding consent")
rejects("configure", { binding_action = { operation = "bind", scope_id = "s", id = "a", definition_revision = "r", canonical_id = "c", extra = "x" }, consent = { binding = true } }, "binding actions have no hidden fields")
rejects("configure", { binding_action = { operation = "revoke", scope_id = "s", id = "a" }, changes = { capacity_enabled = true }, consent = { capacity = true } }, "a binding action changes nothing else")
rejects("ensure", { install_dependencies = false }, "the host Setup ensure is only the explicit dependency install")
rejects("setup_state", { token = "x" }, "reads take no payload")
check(module.decode(runtime.json.encode({ version = 1, request_id = "one", op = "setup_state", token = "secret" })) == nil, "no hidden request fields")
check(module.decode(string.rep("x", 16385)) == nil, "bounded ingress")
check(module.decode(runtime.json.encode(request("configure", { changes = { metadata_enabled = false }, consent = { metadata = false } }))) ~= nil,
	"stopping headless reads is the same confirmed shape as local Setup")

-- setup_state: the runtime check never installs, and only public setup fields leave the host.
local first = send(request("setup_state", {}))
check(state.response.request_id == first.request_id and state.response.status == "pending", "pending correlation")
send(request("setup_state", {}))
check(#calls == 1, "one in-flight host Setup request per block")
check(reply("ensure", { ok = true }).options.install_dependencies == false, "opening host Setup never installs dependencies")
reply("setup_state", { source = { device_id = "11111111-1111-4111-8111-111111111111", generation = "g" },
	settings = { role = "standalone", metadata_enabled = false, capacity_enabled = true, sharing_bind = "10.0.0.2", sharing_port = 49443 },
	peers = { { device_id = "peer", revoked = false } }, certificate_fingerprint = string.rep("a", 64) })
local value = state.response.value
check(state.response.status == "done" and state.response.ok and value.settings.capacity_enabled == true and value.settings.metadata_enabled == false
	and value.source.device_id == "11111111-1111-4111-8111-111111111111", "host state answers with the settings Setup shows")
local encoded = runtime.json.encode(state.response)
check(encoded:find("peer", 1, true) == nil and encoded:find(string.rep("a", 64), 1, true) == nil and encoded:find("10.0.0.2", 1, true) == nil,
	"peers, certificate and sharing address never leave the host block")
check(changes == 0, "a read does not notify the host display")
send(first)
check(#calls == 0 and state.response.request_id == first.request_id, "a resent request that already has its answer is not run twice")

-- Dependency install: the explicit consent reaches this host's real installer option.
local install = send(request("ensure", { install_dependencies = true }))
check(reply("ensure", { ok = true, state = "ready" }).options.install_dependencies == true, "host install passes install_dependencies=true")
check(state.response.request_id == install.request_id and state.response.value.state == "ready" and changes == 1,
	"a completed install is reported and the host collector/display follow it")

-- Confirmed changes are forwarded exactly as local Setup sends them.
local enable = { changes = { capacity_enabled = true }, consent = { capacity = true } }
send(request("configure", enable))
local forwarded = reply("configure", { settings = { capacity_enabled = true, sharing_bind = "10.0.0.2" } })
check(forwarded.payload.changes.capacity_enabled == true and forwarded.payload.consent.capacity == true and forwarded.payload.changes.metadata_enabled == nil,
	"capacity export is configured on this host with its own consent")
check(state.response.value.saved == true and runtime.json.encode(state.response):find("10.0.0.2", 1, true) == nil and changes == 2,
	"configure answers only that it saved")
local bind = { binding_action = { operation = "bind", scope_id = "device:host:local", id = "claude-work", definition_revision = string.rep("a", 64),
	canonical_id = "claude:email:work%40example.test" }, consent = { binding = true } }
send(request("configure", bind))
forwarded = reply("configure", { binding_action = "bind" })
check(forwarded.payload.binding_action.canonical_id == bind.binding_action.canonical_id and forwarded.payload.consent.binding == true,
	"the confirmed binding reaches this host's companion unchanged")
send(request("binding_candidates", {}))
reply("binding_candidates", { accounts = { { id = "claude-work", scope_id = "device:host:local", bound = true } }, consumers = {} })
check(state.response.value.accounts[1].id == "claude-work", "binding candidates come from this host's SPAWN roster")

-- Failures keep the companion's own code and fixed text.
send(request("binding_candidates", {}))
reply("binding_candidates", nil, { code = "source_metadata_disabled", message = "Headless usage reads are off." })
check(not state.response.ok and state.response.status == "failed" and state.response.code == "source_metadata_disabled", "host refusal preserved")
send({ version = 1, request_id = "bad-one", op = "configure", payload = { changes = { role = "hub" } } })
check(#calls == 0 and state.response.request_id == "bad-one" and state.response.code == "invalid_request", "an invalid request is answered, never run")
module.event(state, { ev = "action", act = "usage.capacity", value = runtime.json.encode(request("setup_state", {})) }, cx, changed)
check(#calls == 0, "unrelated actions cannot reach host Setup")

local view = runtime.json.encode(module.view(state))
check(view:find(module.NODE, 1, true) ~= nil and view:find("USAGE_SETUP v1", 1, true) ~= nil, "keyed versioned response rendered")
local parsed = module.parse(module.PREFIX .. runtime.json.encode(state.response))
check(parsed ~= nil and parsed.request_id == "bad-one" and module.parse("USAGE_CAPACITY v1\n{}") == nil, "windows parse only this protocol's responses")
return "PASS " .. checks .. " host setup checks"
