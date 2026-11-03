--!strict
-- Owner-local administration. Every mutation follows an explicit confirmation;
-- invitations exist only in the prompt/RPC/explicit clipboard action, never KV.
local companion = require("./companion")
local setup = {}
local function array(values: any): any
	local result = tern.json.array()
	for _, value in values do table.insert(result, value) end
	return result
end
local function text(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("%c")
end

function setup.new(changed: (any) -> ()): any
	local self: any = { generation = 0 }
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
	local function configure(own: number, payload: any)
		rpc(own, "configure", payload, saved)
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
			elseif item.action == "retry" then self:open(fresh)
			elseif item.action == "interpreter" then
				prompt(fresh, own, "Existing Python 3.11+ executable path (no arguments)", nil, 4096, function(path, next_cx)
					if path:sub(1, 1) == "-" then next_cx:toast("error", "An executable path is required"); return end
					confirm(next_cx, own, "Use this local interpreter?", path, function(current)
						tern.kv.set("usage_python", path)
						companion.invalidate()
						self:open(current)
					end)
				end)
			elseif item.action == "install" then
				confirm(fresh, own, "Install USAGE's private runtime?", "Download and verify the package's hash-locked dependencies. No provider login, sharing, headless-read permission, or status-bar change.", function(current)
					current:toast("info", "Installing USAGE private runtime")
					companion.ensure(function(value, failure, latest)
						if own ~= self.generation or latest == nil then return end
						if value == nil then runtime(latest, own, failure or {}); return end
						changed(latest)
						self:open(latest)
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
	local function metadata(cx: any, own: number, state: any)
		local enabled = not state.settings.metadata_enabled
		confirm(cx, own, if enabled then "Allow headless usage reads on this installation?" else "Stop headless usage reads on this installation?",
			if enabled then "Read the signed-in provider identity and usage for accounts defined in SPAWN, without opening an agent session. Required for Refresh. No login, model turn, owner-pane input, credential export or new user privileges. Sharing consent remains separate."
			else "Stop manual and scheduled usage reads on this installation. Existing received data cannot be recalled.", function()
				configure(own, { changes = { metadata_enabled = enabled }, consent = { metadata = enabled } })
			end)
	end
	function self:open(cx: any)
		if cx == nil then return end
		self.generation += 1
		local own = self.generation
		companion.set_client("window:" .. cx:window_key(), "window")
		companion.ensure(function(value, err, fresh)
			if own ~= self.generation or fresh == nil then return end
			if value == nil then runtime(fresh, own, err or {}); return end
			rpc(own, "setup_state", {}, function(state, _state_cx)
				rpc(own, "diagnostics", {}, function(diagnostics, latest)
					pick(latest, own, "USAGE Setup — " .. state.settings.role .. " · " .. state.source.device_id, {
						{ label = "Enable summary / Show Summary", action = "summary", detail = "Explicitly enable Tern's status bar once; later hides are respected." },
						{ label = "Copy installation UUID", action = "copy_identity", detail = state.source.device_id },
						{ label = "Standalone / stop sharing", action = "standalone" }, { label = "Share from this installation", action = "share" },
						{ label = "Create invitation and copy", action = "invitation" }, { label = "Join using an invitation", action = "join" },
						{ label = "Revoke peer / unpair", action = "revoke" },
						{ label = if state.settings.metadata_enabled then "Stop headless usage reads" else "Allow headless usage reads", action = "metadata",
							detail = "Lets Refresh read usage for SPAWN accounts without typing into agent sessions." },
					}, function(item, selected_cx)
						if item.action == "summary" then self:show_summary(selected_cx)
						elseif item.action == "copy_identity" then selected_cx:copy(state.source.device_id); selected_cx:toast("info", "USAGE installation UUID copied")
						elseif item.action == "standalone" then standalone(selected_cx, own, state)
						elseif item.action == "share" then share(selected_cx, own, state, diagnostics)
						elseif item.action == "invitation" then invitation(selected_cx, own, state, diagnostics)
						elseif item.action == "join" then join(selected_cx, own, diagnostics, state)
						elseif item.action == "revoke" then revoke(selected_cx, own, state)
						elseif item.action == "metadata" then metadata(selected_cx, own, state) end
					end)
				end)
			end)
		end)
	end
	return self
end
return setup
