--!strict
-- Owner-local administration. Every mutation follows an explicit confirmation;
-- invitations exist only in the prompt/RPC/explicit clipboard action, never KV.
-- When the window's current Tern host is remote, that host is USAGE's source: its runtime,
-- permissions and bindings are configured through its own config block (host_setup.luau).
local companion = require("./companion")
local host_setup = require("./host_setup")
local setup = {}
local function array(values: any): any
	local result = tern.json.array()
	for _, value in values do table.insert(result, value) end
	return result
end
local function text(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("%c")
end
-- How long a window waits for its attached host's answer: the host companion's own
-- deadlines (ensure 390 s, requests 30 s) plus transport margin.
local HOST_WAIT_MS: { [string]: number } = { ensure = 400000, setup_state = 400000 }
local HOST_REQUEST_MS = 40000
local HOST_POLL_MS = 250
-- The attached machine's name when the current Tern host is remote, else nil (this machine).
-- Also used by the window's Refresh command: the remote host is then the source.
local function attached(cx: any): string?
	local ok, host = pcall(function() return cx.hosts:current() end)
	if ok and type(host) == "table" and host.kind == "remote" and text(host.name, 256) then return host.name end
	return nil
end
setup.attached = attached
local function response_node(node: any, depth: number): any?
	if type(node) ~= "table" or depth > 4 then return nil end
	if type(node.p) == "table" and node.p.role == host_setup.NODE then return node end
	for _, child in (if type(node.c) == "table" then node.c else {}) do
		local found = response_node(child, depth + 1)
		if found ~= nil then return found end
	end
	return nil
end
-- The host config block's latest answer, read from its native surface: the keyed node, else the
-- whole (small) configuration view.
local function host_response(cx: any, pane: number): any?
	local limit = host_setup.MAX + #host_setup.PREFIX
	local function find(options: any): any?
		local ok, tree = pcall(function() return cx.session:surface(pane, options) end)
		return if ok and type(tree) == "table" then response_node(tree.main, 0) else nil
	end
	local node = find({ root = "main." .. host_setup.NODE, nodes = 4, depth = 2, max_chars = limit })
		or find({ nodes = 500, max_chars = limit * 2 })
	if node == nil then return nil end
	-- Spans arrive as one string, one span or a one-element list of either.
	local spans = node.p.spans
	local span = if type(spans) == "table" and #spans == 1 then spans[1] else spans
	return host_setup.parse(if type(span) == "table" then span.t else span)
end
-- The current host's config pane: the one already used, else any, else (when `open`) a new one
-- beside focus. The second result says a pane was just opened; a just-opened pane that is not
-- listed yet is kept rather than opened again.
local function config_pane(cx: any, known: number?, open: boolean): (number?, boolean)
	local found = nil
	for _, item in cx.session:panes() do
		if item.block == "usage.config" then
			if item.pane == known then return known, false end
			found = found or item.pane
		end
	end
	if found ~= nil then return found, false end
	if not open then return known, false end
	return cx:new_block("usage.config", {}, "beside", { focus = false }), true
end

function setup.new(changed: (any) -> ()): any
	local self: any = { generation = 0, requests = 0 }
	local function fail(cx: any, err: any?)
		cx:toast("error", "USAGE setup did not complete", if err ~= nil then err.message else "The local operation is unavailable. Retry USAGE Setup.")
	end
	local function pick(cx: any, own: number, title: string, items: any, done: (any, any) -> ())
		cx:pick({ placeholder = title, icon = "gauge", items = items }):next(function(item, err, fresh)
			if own ~= self.generation or fresh == nil then return end
			if err ~= nil then fail(fresh, nil); return end
			if item ~= nil then done(item, fresh) end
		end)
	end
	local function prompt(cx: any, own: number, title: string, initial: string?, maximum: number, done: (string, any) -> ())
		cx:prompt({ placeholder = title, value = initial, icon = "gauge" }):next(function(value, err, fresh)
			if own ~= self.generation or fresh == nil then return end
			if err ~= nil then fail(fresh, nil); return end
			if value == nil then return end
			if not text(value, maximum) then fresh:toast("error", "Enter a nonempty bounded value without control characters"); return end
			done(value, fresh)
		end)
	end
	local function confirm(cx: any, own: number, title: string, detail: string, done: (any) -> ())
		-- Picker details are a single clipped line. Put the full disclosure
		-- in bounded selectable rows; inspecting a row never authorizes a change.
		local items = { { label = "Cancel", action = "cancel" }, { label = "Confirm", detail = "Approve the disclosure below", action = "confirm" } }
		local line = ""
		local function flush()
			table.insert(items, { label = line, action = "inspect" })
			line = ""
		end
		for word in detail:gmatch("%S+") do
			if #line + #word + 1 > 44 and #line > 0 then flush() end
			if #word <= 44 then
				line ..= (if line == "" then "" else " ") .. word
			else
				-- Pins and long selectors must not remain one clipped token.
				for _, point in utf8.codes(word) do
					local character = utf8.char(point)
					if #line + #character > 44 then flush() end
					line ..= character
				end
			end
		end
		if line ~= "" then table.insert(items, { label = line, action = "inspect" }) end
		pick(cx, own, title, items, function(item, fresh)
			if item.action == "confirm" then done(fresh)
			elseif item.action == "inspect" then confirm(fresh, own, title, detail, done) end
		end)
	end
	local function rpc(own: number, operation: string, payload: any, done: (any, any) -> ())
		companion.request(operation, payload, function(value, err, fresh)
			if own ~= self.generation or fresh == nil then return end
			if value == nil then fail(fresh, err); return end
			done(value, fresh)
		end)
	end
	local function saved(_value: any, fresh: any)
		fresh:toast("info", "USAGE configuration saved")
		changed(fresh)
	end
	-- Where Setup's companion operations run: `here` is this window's machine (wording unchanged),
	-- `remote(name)` the attached host through its config block.
	local here = { rpc = rpc, where = "this installation", prefix = "", saved = saved }
	local host_request: any
	local function remote(name: string): any
		local target: any = { host = name, where = "host " .. name, prefix = "Host " .. name .. " · " }
		target.rpc = function(own: number, operation: string, payload: any, done: (any, any) -> ())
			host_request(target, own, operation, payload, done, nil)
		end
		target.saved = function(_value: any, fresh: any) fresh:toast("info", "USAGE configuration saved on host " .. name) end
		return target
	end
	-- One request through the attached host's config block, polled on this window's timer.
	-- `failed(err, cx)` replaces the default failure toast.
	host_request = function(target: any, own: number, operation: string, payload: any, done: (any, any) -> (), failed: ((any, any) -> ())?)
		self.requests += 1
		local opened = false
		local id = "setup-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 2147483647)) .. "-" .. tostring(self.requests)
		local bytes = tern.json.encode({ version = 1, request_id = id, op = operation, payload = payload })
		local deadline = tern.now() + (HOST_WAIT_MS[operation] or HOST_REQUEST_MS)
		local function failure(cx: any, err: any)
			if failed ~= nil then failed(err, cx) else fail(cx, err) end
		end
		local step: any
		step = function(cx: any?)
			if own ~= self.generation then return end
			if cx == nil then tern.timer(HOST_POLL_MS, step); return end
			local pane, created = config_pane(cx, target.pane, not opened)
			target.pane, opened = pane, opened or created
			if target.pane == nil then
				failure(cx, { code = "host_unavailable", message = "USAGE is not ready on host " .. target.host .. ". Install or reload USAGE there, then retry." })
				return
			end
			local response = host_response(cx, target.pane)
			if response ~= nil and response.request_id == id and response.status ~= "pending" then
				if response.ok then done(response.value, cx)
				else failure(cx, { code = if type(response.code) == "string" then response.code else "internal_error",
					message = if text(response.message, 512) then response.message else "Host " .. target.host .. " could not complete the USAGE operation." }) end
				return
			end
			if tern.now() >= deadline then
				failure(cx, { code = "timeout", message = "Host " .. target.host .. " did not answer USAGE Setup in time." })
				return
			end
			-- An idle block showing another answer has not taken this request yet: (re)send it.
			-- The block never runs a request it has already answered.
			if response ~= nil and response.status ~= "pending" then
				cx.session:event(target.pane, { ev = "action", act = host_setup.ACTION, value = bytes })
			end
			tern.timer(HOST_POLL_MS, step)
		end
		tern.timer(0, step)
	end
	local function configure(own: number, payload: any, target: any?)
		local via = target or here
		via.rpc(own, "configure", payload, via.saved)
	end
	function self:show_summary(cx: any)
		-- Only this explicit action writes the setting. Poll/reload never restores
		-- a bar the owner subsequently hides.
		if cx.settings:get("status_bar") ~= true then cx.settings:set("status_bar", true) end
		tern.chrome.refresh()
		cx:toast("info", "USAGE summary enabled", "You can hide the status bar later; USAGE will respect that choice.")
	end
	local function runtime(cx: any, own: number, err: any)
		pick(cx, own, "USAGE runtime — " .. (err.message or "Setup required"), {
			{ label = "Install private dependencies", action = "install", detail = "Use Python 3.11+ to install hash-locked packages into USAGE's private environment. No system packages or privileges change." },
			{ label = "Open official Python installer page", action = "python", detail = "Python 3.11+ is a prerequisite. Return here and Retry after graphical installation." },
			{ label = "Select existing Python interpreter", action = "interpreter", detail = "Executable path only, not a command or shell arguments." },
			{ label = "Retry runtime check", action = "retry" },
		}, function(item, fresh)
			if item.action == "python" then fresh:open("https://www.python.org/downloads/")
			elseif item.action == "retry" then self:open(fresh, "local")
			elseif item.action == "interpreter" then
				prompt(fresh, own, "Existing Python 3.11+ executable path (no arguments)", nil, 4096, function(path, next_cx)
					if path:sub(1, 1) == "-" then next_cx:toast("error", "An executable path is required"); return end
					confirm(next_cx, own, "Use this local interpreter?", path, function(current)
						tern.kv.set("usage_python", path)
						companion.invalidate()
						self:open(current, "local")
					end)
				end)
			elseif item.action == "install" then
				confirm(fresh, own, "Install USAGE's private runtime?", "Download and verify the package's hash-locked dependencies. No provider login, sharing, headless-read permission, or status-bar change.", function(current)
					current:toast("info", "Installing USAGE private runtime")
					companion.ensure(function(value, failure, latest)
						if own ~= self.generation or latest == nil then return end
						if value == nil then runtime(latest, own, failure or {}); return end
						changed(latest)
						self:open(latest, "local")
					end, { install_dependencies = true })
				end)
			end
		end)
	end
	local function standalone(cx: any, own: number, state: any)
		confirm(cx, own, "Use USAGE only on this installation?", "Disable export/listener, leave the hub and revoke every listed peer. Headless-read permission is unchanged. Previously received data cannot be recalled.", function(_fresh)
			local peers = {}
			for _, peer in state.peers do if not peer.revoked then table.insert(peers, peer.device_id) end end
			local index = 0
			local function next_peer()
				index += 1
				if peers[index] ~= nil then rpc(own, "unpair", { device_id = peers[index] }, next_peer)
				else
					rpc(own, "unpair", {}, function(result, fresh)
						if result.remote_revoked == false and type(state.hub) == "table" then fresh:toast("info", "Local unpair complete", "The remote hub could not confirm revocation; already received data cannot be recalled.") end
						configure(own, { changes = { role = "standalone", export_enabled = false } })
					end)
				end
			end
			next_peer()
		end)
	end
	local function share(cx: any, own: number, state: any, diagnostics: any)
		if state.settings.role == "member" then cx:toast("info", "Unpair from the current hub before enabling Share", "Use Setup → Revoke peer / unpair; no existing recipient is changed implicitly."); return end
		prompt(cx, own, "Share bind IP (explicit interface; no wildcard)", if type(state.settings.sharing_bind) == "string" then state.settings.sharing_bind else nil, 128, function(address, fresh)
			prompt(fresh, own, "TLS port (1024–65535)", tostring(if state.settings.sharing_port > 0 then state.settings.sharing_port else 49443), 5, function(raw, next_cx)
				local port = tonumber(raw)
				if port == nil or port % 1 ~= 0 or port < 1024 or port > 65535 then next_cx:toast("error", "Choose a port from 1024 through 65535"); return end
				prompt(next_cx, own, "Recipient group identifier", diagnostics.group_id, 128, function(group, latest)
					local disclosure = "Export: " .. table.concat(diagnostics.export_fields, ", ") .. ". Recipient group: " .. group .. ". TLS bind: " .. address .. ":" .. tostring(port) .. ". Certificate SHA256: " .. state.certificate_fingerprint .. ". Only explicitly invited peers. No firewall changes; headless-read permission is separate."
					confirm(latest, own, "Enable sharing and normalized export?", disclosure, function()
						configure(own, { changes = { role = "hub", export_enabled = true, sharing_bind = address, sharing_port = port, group_id = group },
							consent = { export = true, fields = array(diagnostics.export_fields), recipient_group = group, bind = true, bind_address = address, bind_port = port } })
					end)
				end)
			end)
		end)
	end
	local function invitation(cx: any, own: number, state: any, diagnostics: any)
		if state.settings.role ~= "hub" or not state.settings.export_enabled then cx:toast("info", "Enable Share before creating an invitation"); return end
		confirm(cx, own, "Create and copy a one-use invitation?", "Recipient group: " .. diagnostics.group_id .. ". Endpoint: " .. tostring(diagnostics.peer_endpoint) .. ". Certificate SHA256: " .. state.certificate_fingerprint .. ". Exports: " .. table.concat(diagnostics.export_fields, ", ") .. ". Clipboard contains a pairing secret; share privately. Expires in ten minutes.", function()
			rpc(own, "pair_offer", {}, function(result, fresh)
				fresh:copy(tern.json.encode(result.invitation))
				fresh:toast("info", "One-use invitation copied", "Paste privately into the other installation's USAGE Setup → Join. Clipboard is not cleared automatically.")
			end)
		end)
	end
	local function join(cx: any, own: number, diagnostics: any, state: any)
		if state.settings.role ~= "standalone" then cx:toast("info", "Choose Standalone / stop sharing before joining another hub", "Existing peers and recipient consent are never replaced implicitly."); return end
		prompt(cx, own, "Paste private USAGE invitation (never a login credential)", nil, 8192, function(raw, fresh)
			local ok, invite = pcall(tern.json.decode, raw)
			if not ok or type(invite) ~= "table" or not text(invite.endpoint, 2048) or not text(invite.device_id, 36)
				or not text(invite.fingerprint, 64) or not text(invite.group_id, 128) then fresh:toast("error", "Invalid USAGE invitation"); return end
			pick(fresh, own, "Join — choose export consent (headless reads are separate)", {
				{ label = "Receive only", export = false, detail = "Do not export this installation's accounts." },
				{ label = "Share normalized accounts with the group", export = true, detail = table.concat(diagnostics.export_fields, ", ") },
			}, function(choice, next_cx)
				confirm(next_cx, own, "Confirm recipient and pinned certificate independently", "Hub: " .. invite.device_id .. ". Group: " .. invite.group_id .. ". Endpoint: " .. invite.endpoint .. ". SHA256: " .. invite.fingerprint .. ". Local peer bind: none. Export: " .. (if choice.export then table.concat(diagnostics.export_fields, ", ") else "none") .. ". Refresh and its interval use the paired source's SPAWN accounts.", function()
					rpc(own, "pair_accept", { invitation = invite, consent = { export = choice.export,
						fields = array(diagnostics.export_fields), recipient_group = invite.group_id,
						pair_confirmation = { device_id = invite.device_id, fingerprint = invite.fingerprint } } }, saved)
				end)
			end)
		end)
	end
	local function revoke(cx: any, own: number, state: any)
		local items = {}
		if type(state.hub) == "table" then table.insert(items, { label = "Leave paired hub", detail = state.hub.device_id, hub = true }) end
		if state.settings.role ~= "member" then
			for _, peer in state.peers do if not peer.revoked then table.insert(items, { label = "Revoke peer", detail = peer.device_id, device_id = peer.device_id }) end end
		end
		if #items == 0 then cx:toast("info", "No active pairing to remove"); return end
		pick(cx, own, "Remove pairing", items, function(item, fresh)
			confirm(fresh, own, "Revoke this installation's access?", item.detail .. ". Advertised records and authority are removed; already received data cannot be recalled.", function()
				rpc(own, "unpair", if item.hub then {} else { device_id = item.device_id }, function(value, latest)
					saved(value, latest)
					if value.remote_revoked == false and item.hub then latest:toast("info", "Local unpair complete; remote revocation unconfirmed", "The hub may be offline. Previously received data cannot be recalled.") end
				end)
			end)
		end)
	end
	-- Setting key `metadata_enabled` is the stored name of this permission.
	local function metadata(cx: any, own: number, state: any, target: any)
		local enabled = not state.settings.metadata_enabled
		confirm(cx, own, if enabled then "Allow headless usage reads on " .. target.where .. "?" else "Stop headless usage reads on " .. target.where .. "?",
			if enabled then "Read the signed-in provider identity and usage for accounts defined in SPAWN, without opening an agent session. Required for Refresh. No login, model turn, owner-pane input, credential export or new user privileges. Sharing consent remains separate."
			else "Stop manual and scheduled usage reads on " .. target.where .. ". Existing received data cannot be recalled.", function()
				configure(own, { changes = { metadata_enabled = enabled }, consent = { metadata = enabled } }, target)
			end)
	end
	local function capacity(cx: any, own: number, state: any, target: any)
		local enabled = not state.settings.capacity_enabled
		confirm(cx, own, target.prefix .. (if enabled then "Enable read-only capacity export?" else "Revoke capacity export?"),
			if enabled then "Allow same-user Tern plugins such as ORCH+ to read account, source and SPAWN binding evidence, and the quota of accounts you bound. No credentials or source selectors. Tern block events do not authenticate plugins or humans. No refresh, configuration or launch authority is granted."
			else "Invalidate capacity snapshots immediately. Already received data cannot be recalled.", function()
				configure(own, { changes = { capacity_enabled = enabled }, consent = { capacity = enabled } }, target)
			end)
	end
	local function bindings(cx: any, own: number, target: any)
		target.rpc(own, "binding_candidates", {}, function(candidates, fresh)
			local items = {}
			for _, account in candidates.accounts do
				table.insert(items, { label = account.provider_label .. " · " .. account.account_label .. " → " .. (account.principal or "no current reading"),
					detail = if account.bound then "Bound. Choose to revoke." elseif account.canonical_id ~= nil then "Choose to bind this login."
						else "Refresh first; only a current headless reading can be bound.", account = account })
			end
			if #items == 0 then fresh:toast("info", "SPAWN defines no accounts on " .. target.where); return end
			pick(fresh, own, target.prefix .. "Bind SPAWN accounts — capacity export carries quota only for bound accounts", items, function(item, next_cx)
				local account = item.account
				if account.bound then
					confirm(next_cx, own, target.prefix .. "Revoke this account binding?", "SPAWN record: " .. account.id .. ". Capacity export stops carrying its quota and any OMP association with it. Already received data cannot be recalled.", function()
						configure(own, { binding_action = { operation = "revoke", scope_id = account.scope_id, id = account.id } }, target)
					end)
				elseif account.canonical_id == nil then
					next_cx:toast("info", "No current reading to bind", "Run USAGE Refresh for this account, then bind it.")
				else
					confirm(next_cx, own, target.prefix .. "Bind this SPAWN account to its signed-in login?", "Provider: " .. account.provider_label .. ". SPAWN record: " .. account.id .. " (" .. account.account_label .. "). Principal: " .. account.principal .. ". Identity and scope: " .. account.canonical_id .. ". SPAWN scope: " .. account.scope_id .. ". Capacity export may then carry this account's quota. Editing the SPAWN record or a reading of another login drops the binding.", function()
						configure(own, { binding_action = { operation = "bind", scope_id = account.scope_id, id = account.id,
							definition_revision = account.definition_revision, canonical_id = account.canonical_id }, consent = { binding = true } }, target)
					end)
				end
			end)
		end)
	end
	local function associations(cx: any, own: number, target: any)
		target.rpc(own, "binding_candidates", {}, function(candidates, fresh)
			local items = {}
			for _, consumer in candidates.consumers do
				local current = consumer.account_ids[1]
				table.insert(items, { label = consumer.label .. (if current ~= nil then " → " .. current else ""),
					detail = if current ~= nil then "Associated. Choose to remove." else "Choose the bound account whose quota it uses.", consumer = consumer })
			end
			if #items == 0 then fresh:toast("info", "SPAWN defines no OMP records on " .. target.where); return end
			pick(fresh, own, target.prefix .. "Associate OMP records with a bound account", items, function(item, next_cx)
				local consumer = item.consumer
				if consumer.account_ids[1] ~= nil then
					confirm(next_cx, own, target.prefix .. "Remove this OMP association?", "OMP record: " .. consumer.id .. ". Capacity export stops naming an account for it.", function()
						configure(own, { binding_action = { operation = "dissociate", scope_id = consumer.scope_id, id = consumer.id } }, target)
					end)
					return
				end
				local accounts = {}
				for _, account in candidates.accounts do
					if account.bound and account.scope_id == consumer.scope_id then
						table.insert(accounts, { label = account.provider_label .. " · " .. account.account_label, detail = account.principal or account.id, account = account })
					end
				end
				if #accounts == 0 then next_cx:toast("info", "Bind a SPAWN account first", "Use Bind SPAWN accounts, then associate this OMP record."); return end
				pick(next_cx, own, target.prefix .. "Which bound account's quota does " .. consumer.id .. " use?", accounts, function(choice, latest)
					local account = choice.account
					confirm(latest, own, target.prefix .. "Associate this OMP record?", "OMP record: " .. consumer.id .. ". Uses the quota of SPAWN account " .. account.id .. " (" .. account.provider_label .. ", " .. (account.principal or "bound") .. "). Owner-declared: USAGE cannot read OMP's own login. Editing either record or revoking the account's binding removes it.", function()
						configure(own, { binding_action = { operation = "associate", scope_id = consumer.scope_id, id = consumer.id,
							definition_revision = consumer.definition_revision, account_id = account.id }, consent = { association = true } }, target)
					end)
				end)
			end)
		end)
	end
	-- The attached host's Setup: only what configures its own acquisition source. Pairing,
	-- summary and interpreter choice stay with this window's machine ("instead" row).
	local host_menu: any
	local function host_runtime(cx: any, own: number, target: any, err: any)
		local name = target.host
		pick(cx, own, target.prefix .. "USAGE runtime — " .. (err.message or "Setup required"), {
			{ label = "Install private dependencies on " .. name, action = "install", detail = "Runs on " .. name .. ": its Python 3.11+ installs hash-locked packages into USAGE's private environment there. No system packages or privileges change." },
			{ label = "Retry runtime check on " .. name, action = "retry" },
			{ label = "Configure this window's machine instead", action = "local", detail = "Runtime, pairing, summary and permissions of the machine running this window." },
		}, function(item, fresh)
			if item.action == "retry" then host_menu(own, target)
			elseif item.action == "local" then self:open(fresh, "local")
			elseif item.action == "install" then
				confirm(fresh, own, "Install USAGE's private runtime on host " .. name .. "?", "On " .. name .. ", download and verify the package's hash-locked dependencies. No provider login, sharing, headless-read permission, or status-bar change.", function(current)
					current:toast("info", "Installing USAGE private runtime on host " .. name)
					host_request(target, own, "ensure", { install_dependencies = true }, function(_value, _latest) host_menu(own, target) end,
						function(failure, latest) host_runtime(latest, own, target, failure) end)
				end)
			end
		end)
	end
	host_menu = function(own: number, target: any)
		local name = target.host
		local function failed(failure: any, latest: any) host_runtime(latest, own, target, failure) end
		host_request(target, own, "setup_state", {}, function(state, latest)
			if type(state) ~= "table" or type(state.settings) ~= "table" or type(state.source) ~= "table" or type(state.source.device_id) ~= "string" then
				failed({ code = "decode_failed", message = "Host " .. name .. " returned an invalid USAGE Setup state." }, latest); return
			end
			local items = {
				{ label = (if state.settings.metadata_enabled then "Stop headless usage reads on " else "Allow headless usage reads on ") .. name, action = "metadata",
					detail = "Lets Refresh on " .. name .. " read usage for its SPAWN accounts without typing into agent sessions." },
				{ label = (if state.settings.capacity_enabled then "Revoke capacity export on " else "Enable capacity export on ") .. name, action = "capacity",
					detail = "Read-only evidence for ORCH+ quota routing in windows attached to " .. name .. "." },
			}
			if state.settings.metadata_enabled then
				table.insert(items, { label = "Bind SPAWN accounts on " .. name .. "…", action = "bind", detail = "Confirm which signed-in login each of its SPAWN accounts uses." })
				table.insert(items, { label = "Associate OMP records on " .. name .. "…", action = "associate", detail = "Declare which bound account's quota an OMP record uses." })
			end
			table.insert(items, { label = "Configure this window's machine instead", action = "local", detail = "Runtime, pairing, summary and permissions of the machine running this window." })
			pick(latest, own, "USAGE Setup — host " .. name .. " (attached source) · " .. state.settings.role .. " · " .. state.source.device_id, items, function(item, selected_cx)
				if item.action == "metadata" then metadata(selected_cx, own, state, target)
				elseif item.action == "capacity" then capacity(selected_cx, own, state, target)
				elseif item.action == "bind" then bindings(selected_cx, own, target)
				elseif item.action == "associate" then associations(selected_cx, own, target)
				elseif item.action == "local" then self:open(selected_cx, "local") end
			end)
		end, failed)
	end
	-- `scope = "local"` keeps Setup on this window's machine even while a remote host is current.
	function self:open(cx: any, scope: string?)
		if cx == nil then return end
		self.generation += 1
		local own = self.generation
		local host = if scope == "local" then nil else attached(cx)
		if host ~= nil then
			cx:toast("info", "USAGE Setup configures host " .. host, "It is the source of this window's readings. Its USAGE Configuration pane carries the changes you confirm here.")
			host_menu(own, remote(host))
			return
		end
		companion.set_client("window:" .. cx:window_key(), "window")
		companion.ensure(function(value, err, fresh)
			if own ~= self.generation or fresh == nil then return end
			if value == nil then runtime(fresh, own, err or {}); return end
			rpc(own, "setup_state", {}, function(state, _state_cx)
				rpc(own, "diagnostics", {}, function(diagnostics, latest)
					local items = {
						{ label = "Enable summary / Show Summary", action = "summary", detail = "Explicitly enable Tern's status bar once; later hides are respected." },
						{ label = "Copy installation UUID", action = "copy_identity", detail = state.source.device_id },
						{ label = "Standalone / stop sharing", action = "standalone" }, { label = "Share from this installation", action = "share" },
						{ label = "Create invitation and copy", action = "invitation" }, { label = "Join using an invitation", action = "join" },
						{ label = "Revoke peer / unpair", action = "revoke" },
						{ label = if state.settings.metadata_enabled then "Stop headless usage reads" else "Allow headless usage reads", action = "metadata",
							detail = "Lets Refresh read usage for SPAWN accounts without typing into agent sessions." },
						{ label = if state.settings.capacity_enabled then "Revoke capacity export" else "Enable capacity export", action = "capacity",
							detail = "Read-only evidence for same-user plugins such as ORCH+ quota routing." },
					}
					if state.settings.metadata_enabled then
						table.insert(items, { label = "Bind SPAWN accounts…", action = "bind", detail = "Confirm which signed-in login each SPAWN account uses." })
						table.insert(items, { label = "Associate OMP records…", action = "associate", detail = "Declare which bound account's quota an OMP record uses." })
					end
					pick(latest, own, "USAGE Setup — " .. state.settings.role .. " · " .. state.source.device_id, items, function(item, selected_cx)
						if item.action == "summary" then self:show_summary(selected_cx)
						elseif item.action == "copy_identity" then selected_cx:copy(state.source.device_id); selected_cx:toast("info", "USAGE installation UUID copied")
						elseif item.action == "standalone" then standalone(selected_cx, own, state)
						elseif item.action == "share" then share(selected_cx, own, state, diagnostics)
						elseif item.action == "invitation" then invitation(selected_cx, own, state, diagnostics)
						elseif item.action == "join" then join(selected_cx, own, diagnostics, state)
						elseif item.action == "revoke" then revoke(selected_cx, own, state)
						elseif item.action == "metadata" then metadata(selected_cx, own, state, here)
						elseif item.action == "capacity" then capacity(selected_cx, own, state, here)
						elseif item.action == "bind" then bindings(selected_cx, own, here)
						elseif item.action == "associate" then associations(selected_cx, own, here) end
					end)
				end)
			end)
		end)
	end
	return self
end
return setup
