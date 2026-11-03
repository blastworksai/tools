-- Callback/consent regressions; run in Tern's isolated fixture driver.
local root = ...
local runtime, environment = tern, getfenv()
local checks = 0
local function check(ok, why) assert(ok, why); checks += 1 end
local state
local fake = table.clone(runtime)
local function forbidden() error("Setup must not create a pane, shell, credential store or privilege grant") end
fake.process, fake.fetch = { run = forbidden }, forbidden
fake.chrome = { refresh = function() end }
fake.kv = { get = function(key) return state.kv[key] end, set = function(key, value) state.kv[key] = value end }
local modules = { companion = {
	set_client = function() end,
	ensure = function(callback, options) table.insert(state.rpc, { op = "ensure", callback = callback, options = options }) end,
	request = function(op, payload, callback) table.insert(state.rpc, { op = op, payload = payload, callback = callback }) end,
	invalidate = function() end,
} }
local function load(name)
	name = name:gsub("^%./", "")
	if modules[name] ~= nil then return modules[name] end
	local chunk = assert(loadstring(runtime.fs.read(root .. "/" .. name .. ".luau"), name))
	setfenv(chunk, setmetatable({ require = load, tern = fake }, { __index = environment }))
	modules[name] = chunk()
	return modules[name]
end
local setup = load("setup")
local id = "11111111-1111-4111-8111-111111111111"
local other = "22222222-2222-4222-8222-222222222222"
local function fresh()
	state.context += 1
	local own = state.context
	local cx = { settings = {}, hosts = {}, new_block = forbidden }
	local function live() assert(own == state.context, "An async continuation used a stale WindowCx") end
	function cx:window_key() live(); return "fixture" end
	function cx:toast(_level, title, detail) live(); table.insert(state.toasts, { title, detail }) end
	function cx:copy(value) live(); table.insert(state.clipboard, value) end
	function cx:open(url) live(); state.opened = url end
	function cx.settings:get() live(); return state.status_bar end
	function cx.settings:set(_key, value) live(); state.status_bar = value; state.setting_writes += 1 end
	function cx.hosts:list() live(); return state.hosts end
	local function ui(kind, options)
		live()
		local pending = { kind = kind, options = options }
		table.insert(state.ui, pending)
		return { next = function(_self, callback) pending.callback = callback end }
	end
	function cx:pick(options) return ui("pick", options) end
	function cx:prompt(options) return ui("prompt", options) end
	return cx
end
local function start()
	state = { rpc = {}, ui = {}, clipboard = {}, toasts = {}, kv = {}, context = 0, status_bar = false, setting_writes = 0, changed = 0, hosts = {} }
	state.source = { source = { device_id = id },
		settings = { role = "standalone", metadata_enabled = false, export_enabled = false, sharing_bind = runtime.json.null, sharing_port = 0 },
		peers = {}, hub = runtime.json.null, certificate_fingerprint = string.rep("a", 64) }
	state.diagnostics = { group_id = id, export_fields = { "provider", "principal/account identity", "organization/workspace/tenant scope", "account label", "subscription", "quota windows", "reset/observation times", "source/agent label" } }
	state.entry = setup.new(function(cx) cx:toast("info", "changed"); state.changed += 1 end)
	state.entry:open(fresh())
	return state
end
local function reply(op, value, err)
	local pending = table.remove(state.rpc, 1)
	assert(pending ~= nil and pending.op == op, "Expected " .. op)
	pending.callback(value, err, fresh())
	return pending
end
local function answer(value)
	local pending = table.remove(state.ui, 1)
	assert(pending ~= nil, "Expected a prompt or picker")
	pending.callback(value, nil, fresh())
	return pending
end
local function choose(action)
	local pending = state.ui[1]
	assert(pending and pending.kind == "pick", "Expected a picker")
	for _, item in pending.options.items do
		if item.action == action or item.value == action or item.label == action then return answer(item) end
	end
	error("Missing choice " .. action)
end
local function menu()
	reply("ensure", { ok = true })
	reply("setup_state", state.source)
	reply("diagnostics", state.diagnostics)
end
start(); menu(); choose("share"); answer("127.0.0.1"); answer("49443"); answer(id)
local disclosed = {}
for _, item in state.ui[1].options.items do if item.action == "inspect" then table.insert(disclosed, item.label) end end
local confirmation = table.concat(disclosed, ""):gsub("%s", "")
for _, label in disclosed do
	check(#label <= 44 and utf8.len(label) ~= nil, "consent rows fit the picker without clipping or broken Unicode")
end
for _, field in state.diagnostics.export_fields do
	check(confirmation:find(field:gsub("%s", ""), 1, true) ~= nil, "every exported field is disclosed")
end
check(confirmation:find(id, 1, true) and confirmation:find(state.source.certificate_fingerprint, 1, true),
	"recipient and complete certificate remain inspectable across bounded rows")
choose("inspect")
check(#state.rpc == 0, "inspecting a disclosure row never consents to export")
answer(nil)
check(#state.rpc == 0 and state.setting_writes == 0, "canceling share confirmation does not bind/export/change summary")
start(); menu(); choose("metadata"); answer(nil)
check(#state.rpc == 0, "headless usage reads are never implied by setup or canceled consent")
start(); menu()
local metadata_item = nil
for _, item in state.ui[1].options.items do if item.action == "metadata" then metadata_item = item end end
check(metadata_item.label == "Allow headless usage reads", "the permission is named for what it allows")
choose("metadata"); choose("confirm")
check(state.rpc[1].payload.changes.metadata_enabled and state.rpc[1].payload.consent.metadata and state.rpc[1].payload.changes.export_enabled == nil, "headless-read permission mutates that setting only, not export")
reply("configure", { ok = true })
check(state.changed == 1, "successful change resumes window collection with fresh context")
start(); reply("ensure", nil, { code = "setup_required", message = "Setup required" }); choose("install"); answer(nil)
check(#state.rpc == 0, "dependency picker choice alone does not install packages")
start(); reply("ensure", nil, { code = "setup_required", message = "Setup required" }); choose("install"); choose("confirm")
check(state.rpc[1].options.install_dependencies == true, "explicit dependency consent reaches the real installer option")
start(); menu(); choose("join")
local invite = { protocol = 1, endpoint = "https://127.0.0.1:49443", device_id = other, group_id = other, fingerprint = string.rep("b", 64), secret = "PRIVATE_INVITATION_SENTINEL", expires_at_ms = 9999999999999 }
answer(runtime.json.encode(invite)); choose("Receive only"); choose("confirm")
local request = state.rpc[1]
check(request.op == "pair_accept" and request.payload.consent.export == false and request.payload.consent.metadata == nil, "receive-only pairing never implies headless reads or export")
check(request.payload.consent.pair_confirmation.fingerprint == invite.fingerprint and request.payload.consent.recipient_group == invite.group_id, "pair acceptance uses explicitly confirmed recipient and pin")
check(next(state.kv) == nil and #state.clipboard == 0, "incoming invitation is not persisted or copied")
start(); menu(); choose("summary")
check(state.status_bar and state.setting_writes == 1 and next(state.kv) == nil, "explicit summary enable writes only the status-bar setting")
state.status_bar = false
state.entry:open(fresh()); menu(); answer(nil)
check(not state.status_bar and state.setting_writes == 1, "opening setup later respects the owner's later hide")
start(); menu(); choose("metadata")
local late = table.remove(state.ui, 1)
state.entry:open(fresh())
late.callback(late.options.items[2], nil, fresh())
check(#state.rpc == 1 and state.rpc[1].op == "ensure", "a reopened setup rejects late consent callbacks from the older flow")
start()
local pending = table.remove(state.rpc, 1)
pending.callback({ ok = true }, nil, nil)
check(#state.ui == 0 and #state.rpc == 0, "missing fresh context never resumes setup with a captured context")
local unicode_label = string.rep(utf8.char(0x754C), 30)
start(); menu(); choose("share"); answer("127.0.0.1"); answer("49443"); answer(unicode_label)
local unicode_rows = {}
for _, item in state.ui[1].options.items do
	if item.action == "inspect" then
		check(#item.label <= 44 and utf8.len(item.label) ~= nil, "long non-ASCII consent values remain readable valid Unicode")
		table.insert(unicode_rows, item.label)
	end
end
check(table.concat(unicode_rows, ""):gsub("%s", ""):find(unicode_label, 1, true) ~= nil,
	"wrapping preserves the entire recipient group before authorization")
return "PASS " .. tostring(checks) .. " setup consent/lifecycle checks"
