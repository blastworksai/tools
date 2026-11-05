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
-- Window timers run only when the fixture ticks them, each with a fresh WindowCx.
fake.timer = function(_delay, callback) table.insert(state.timers, callback); return { cancel = function() end } end
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
-- The attached remote host: its config block is the real host_setup module over that host's own companion.
local host_modules = { companion = {
	ensure = function(callback, options) table.insert(state.host_rpc, { op = "ensure", callback = callback, options = options }) end,
	request = function(op, payload, callback) table.insert(state.host_rpc, { op = op, payload = payload, callback = callback }) end,
} }
local host_chunk = assert(loadstring(runtime.fs.read(root .. "/host_setup.luau"), "host_setup"))
setfenv(host_chunk, setmetatable({ tern = runtime, require = function(name)
	local module = host_modules[(name:gsub("^%./", ""))]
	assert(module ~= nil, "host Setup reaches only the host's companion")
	return module
end }, { __index = environment }))
local host_block = host_chunk()
local function role_node(node, role)
	if type(node) ~= "table" then return nil end
	if type(node.p) == "table" and node.p.role == role then return node end
	for _, child in node.c or {} do
		local found = role_node(child, role)
		if found ~= nil then return found end
	end
	return nil
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
	if state.remote ~= nil then
		local remote = state.remote
		function cx.hosts:current() live(); return { id = 2, kind = "remote", name = remote.name, state = "connected" } end
		cx.session = {}
		function cx.session:panes() live(); return remote.panes end
		function cx.session:surface(pane, options)
			live()
			if remote.block == nil or pane ~= remote.pane then return nil end
			local node = role_node(host_block.view(remote.block), host_block.NODE)
			return { surface = { id = "config", role = "plugin.usage.config", mode = "block" }, main = { id = options.root, k = node.k, p = node.p } }
		end
		function cx.session:event(pane, event)
			live()
			assert(pane == remote.pane, "Setup sends only to the host's config block")
			table.insert(remote.events, event)
			host_block.event(remote.block, event, { render = function() end }, function() remote.changes += 1 end)
		end
		function cx:new_block(kind, _args, _how, options)
			live()
			assert(kind == "usage.config" and options.focus == false, "only the host's config block is opened, without stealing focus")
			remote.opened += 1
			remote.pane, remote.block = 77, host_block.new()
			table.insert(remote.panes, { pane = 77, block = kind })
			return 77
		end
	elseif state.local_host then
		function cx.hosts:current() live(); return { id = 1, kind = "local", name = "this-machine", state = "connected" } end
	end
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
local function start(remote, local_host)
	state = { rpc = {}, ui = {}, clipboard = {}, toasts = {}, kv = {}, context = 0, status_bar = false, setting_writes = 0, changed = 0, hosts = {},
		timers = {}, host_rpc = {}, local_host = local_host,
		remote = if remote then { name = remote, panes = {}, events = {}, opened = 0, changes = 0 } else nil }
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
local function has(action)
	for _, item in state.ui[1].options.items do if item.action == action then return true end end
	return false
end
start(); menu()
check(has("capacity") and not has("bind") and not has("associate"), "binding rows appear only once headless reads are allowed")
choose("capacity"); answer(nil)
check(#state.rpc == 0, "capacity export is never implied by opening or canceling setup")
start(); menu(); choose("capacity"); choose("confirm")
check(state.rpc[1].payload.changes.capacity_enabled == true and state.rpc[1].payload.consent.capacity == true
	and state.rpc[1].payload.changes.metadata_enabled == nil, "capacity export needs its own explicit consent")
local work = { scope_id = "device:host:local", id = "claude-work", provider = "claude", provider_label = "Claude",
	account_label = "Work", definition_revision = string.rep("a", 64), bound = false,
	principal = "work@example.test", canonical_id = "claude:email:work%40example.test", canonical_ids = { "claude:email:work%40example.test" } }
local unread = { scope_id = "device:host:local", id = "claude-spare", provider = "claude", provider_label = "Claude",
	account_label = "Spare", definition_revision = string.rep("c", 64), bound = false }
local agent = { scope_id = "device:host:local", id = "omp-agent", label = "OMP · Agent", definition_revision = string.rep("b", 64), account_ids = {} }
local function bindings_menu(accounts)
	start(); state.source.settings.metadata_enabled = true; menu(); choose("bind")
	reply("binding_candidates", { accounts = accounts, consumers = { agent } })
end
bindings_menu({ work, unread })
local labels = {}
for _, item in state.ui[1].options.items do table.insert(labels, item.label) end
check(labels[1] == "Claude · Work → work@example.test" and labels[2] == "Claude · Spare → no current reading",
	"each SPAWN account shows the login its current reading proved")
choose("Claude · Spare → no current reading")
check(#state.rpc == 0 and #state.ui == 0, "an account without a current reading cannot be bound")
bindings_menu({ work })
choose("Claude · Work → work@example.test")
local shown = {}
for _, item in state.ui[1].options.items do if item.action == "inspect" then table.insert(shown, item.label) end end
local disclosure = table.concat(shown, " ")
check(disclosure:find("Claude", 1, true) and disclosure:find("claude-work", 1, true) and disclosure:find("work@example.test", 1, true)
	and disclosure:gsub("%s", ""):find(work.canonical_id, 1, true), "bind confirmation shows provider, SPAWN record, principal and scope")
check(#state.rpc == 0, "showing the binding disclosure does not bind")
choose("confirm")
local bind = state.rpc[1].payload
check(state.rpc[1].op == "configure" and bind.binding_action.operation == "bind" and bind.consent.binding == true
	and bind.binding_action.canonical_id == work.canonical_id and bind.binding_action.definition_revision == work.definition_revision
	and bind.changes == nil, "confirming binds exactly the shown login and definition, nothing else")
local bound = table.clone(work); bound.bound = true
bindings_menu({ bound }); choose("Claude · Work → work@example.test"); choose("confirm")
check(state.rpc[1].payload.binding_action.operation == "revoke" and state.rpc[1].payload.consent == nil, "a bound account offers Revoke binding")
start(); state.source.settings.metadata_enabled = true; menu(); choose("associate")
reply("binding_candidates", { accounts = { bound, unread }, consumers = { agent } })
choose("OMP · Agent")
check(#state.ui[1].options.items == 1, "only bound accounts can carry an OMP record's quota")
choose("Claude · Work"); choose("confirm")
local associate = state.rpc[1].payload
check(associate.binding_action.operation == "associate" and associate.binding_action.account_id == "claude-work"
	and associate.binding_action.id == "omp-agent" and associate.consent.association == true, "an OMP association is an explicit owner declaration")
-- A window attached to a remote Tern host configures that host's companion through its config block.
local function tick()
	local due = state.timers
	state.timers = {}
	for _, callback in due do callback(fresh()) end
end
local function host_reply(op, value, err)
	local pending = table.remove(state.host_rpc, 1)
	assert(pending ~= nil and pending.op == op, "Expected host " .. op)
	pending.callback(value, err, nil)
	return pending
end
local function host_state(settings)
	return { source = { device_id = other, generation = "g", label = "Tern source" }, settings = settings,
		peers = { { device_id = id, revoked = false } }, hub = runtime.json.null, certificate_fingerprint = string.rep("d", 64) }
end
local function remote_menu(settings)
	start("vm-b"); tick()
	check(host_reply("ensure", { ok = true }).options.install_dependencies == false, "opening host Setup never installs on the host")
	host_reply("setup_state", host_state(settings)); tick()
end
remote_menu({ role = "standalone", metadata_enabled = false, capacity_enabled = false })
check(#state.rpc == 0, "Setup on a window attached to a remote host does not configure this window's companion")
check(state.remote.opened == 1 and state.remote.events[1].act == "usage.setup", "the request goes to the attached host's config block")
check(state.toasts[1][1] == "USAGE Setup configures host vm-b"
	and state.ui[1].options.placeholder == "USAGE Setup — host vm-b (attached source) · standalone · " .. other,
	"Setup names the attached machine it configures and that machine's installation")
local remote_labels = {}
for _, item in state.ui[1].options.items do remote_labels[item.action] = item.label end
check(remote_labels.metadata == "Allow headless usage reads on vm-b" and remote_labels.capacity == "Enable capacity export on vm-b"
	and remote_labels["local"] == "Configure this window's machine instead", "every host row is labelled with the host")
check(not has("share") and not has("join") and not has("summary") and not has("bind"), "host Setup offers only the source's own configuration")
choose("metadata")
check(state.ui[1].options.placeholder == "Allow headless usage reads on host vm-b?", "the consent names the host")
answer(nil)
check(#state.timers == 0 and #state.host_rpc == 0, "canceling host consent sends nothing to the host")
remote_menu({ role = "standalone", metadata_enabled = false, capacity_enabled = false })
choose("metadata"); choose("confirm"); tick()
local host_change = host_reply("configure", { settings = { metadata_enabled = true } })
check(host_change.payload.changes.metadata_enabled == true and host_change.payload.consent.metadata == true
	and host_change.payload.changes.capacity_enabled == nil and #state.rpc == 0, "confirmed headless reads are enabled on the host only")
tick()
check(state.toasts[#state.toasts][1] == "USAGE configuration saved on host vm-b" and state.remote.changes == 1,
	"the saved toast names the host and the host display follows the change")
remote_menu({ role = "standalone", metadata_enabled = true, capacity_enabled = true })
check(has("bind") and has("associate"), "host binding rows appear once the host allows headless reads")
choose("capacity")
check(state.ui[1].options.placeholder == "Host vm-b · Revoke capacity export?", "capacity consent names the host")
choose("confirm"); tick()
check(host_reply("configure", { settings = {} }).payload.consent.capacity == false, "capacity export is revoked on the host")
remote_menu({ role = "standalone", metadata_enabled = true, capacity_enabled = false })
choose("bind"); tick()
host_reply("binding_candidates", { accounts = { work }, consumers = { agent } }); tick()
choose("Claude · Work → work@example.test")
check(state.ui[1].options.placeholder == "Host vm-b · Bind this SPAWN account to its signed-in login?", "the binding consent names the host")
choose("confirm"); tick()
local host_bind = host_reply("configure", { binding_action = "bind" }).payload
check(host_bind.binding_action.canonical_id == work.canonical_id and host_bind.consent.binding == true and #state.rpc == 0,
	"the host's SPAWN account is bound on the host after the same confirmation")
remote_menu({ role = "standalone", metadata_enabled = true, capacity_enabled = false })
choose("associate"); tick()
host_reply("binding_candidates", { accounts = { bound }, consumers = { agent } }); tick()
choose("OMP · Agent"); choose("Claude · Work"); choose("confirm"); tick()
check(host_reply("configure", { binding_action = "associate" }).payload.binding_action.operation == "associate", "OMP association runs on the host")
-- A host without its private runtime is prepared there, only after explicit consent.
start("vm-b"); tick()
host_reply("ensure", nil, { code = "setup_required", message = "USAGE setup is required." }); tick()
check(state.ui[1].options.placeholder == "Host vm-b · USAGE runtime — USAGE setup is required.", "the host's runtime problem is labelled with the host")
choose("install"); answer(nil)
check(#state.timers == 0 and #state.host_rpc == 0 and #state.rpc == 0, "choosing install alone installs nothing on either machine")
start("vm-b"); tick()
host_reply("ensure", nil, { code = "setup_required", message = "USAGE setup is required." }); tick()
choose("install")
check(state.ui[1].options.placeholder == "Install USAGE's private runtime on host vm-b?", "the install consent names the host")
choose("confirm"); tick()
check(host_reply("ensure", { ok = true }).options.install_dependencies == true and #state.rpc == 0,
	"explicit consent installs the host's dependencies on the host, not on this window's machine")
tick(); tick()
check(#state.host_rpc == 1 and state.host_rpc[1].op == "ensure" and state.host_rpc[1].options.install_dependencies == false,
	"after installing, host Setup checks the host runtime again")
-- Local behaviour is unchanged: a local current host, or the explicit "instead" row, uses this window's companion.
start(nil, true)
check(#state.timers == 0 and state.rpc[1].op == "ensure", "a window on a local host configures its own companion")
menu()
check(state.ui[1].options.placeholder == "USAGE Setup — standalone · " .. id, "local Setup keeps its own title")
remote_menu({ role = "standalone", metadata_enabled = false, capacity_enabled = false })
choose("local")
check(state.rpc[1].op == "ensure" and #state.timers == 0, "the instead row opens this window's own Setup while attached")
menu()
check(has("share") and not has("local"), "this window's own Setup stays local")
return "PASS " .. tostring(checks) .. " setup consent/lifecycle checks"
