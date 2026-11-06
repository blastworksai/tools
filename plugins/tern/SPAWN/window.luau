--!strict
-- Window aliases are usable only inside the verified native client incarnation.
-- The host owns configuration, execution, replies and all durable launch outcomes.
local Config = require("./config")
local Launch = require("./launch_state")
local Native = require("./native_cli")
local BLOCK = "spawn.spawner"
local PREFIX = "SPAWN_STATE_V2 "
local MAX_QUEUE = 64
local POLL_MS = 250
-- Spawn all starts each submitted launch this far apart so start-up memory spikes don't stack.
local BATCH_INTERVAL_MS = 5000
local MODES = { ["native-agent"] = "Native OMP", ["local-terminal"] = "Terminal", ["ssh-command"] = "SSH terminal" }
local COLORS = { claude = "orange", codex = "green", kimi = "teal", muse = "blue", agy = "red", grok = "yellow", omp = "purple" }
local ICONS = { claude = "provider-anthropic", codex = "provider-openai-codex", kimi = "provider-kimi-code", muse = "provider-meta", agy = "provider-google-antigravity", grok = "provider:xai", omp = "pi-mark" }
local icon_errors = {}
local ARTWORK = {
	kimi = "light-dark(url(assets/icons/kimi-light.svg), url(assets/icons/kimi-dark.svg))",
	muse = "url(assets/icons/muse.svg)",
	agy = "url(assets/icons/agy.svg)",
	grok = "light-dark(url(assets/icons/grok-light.svg), url(assets/icons/grok-dark.svg))",
}
local artwork_css = ""
for program, icon in pairs(ICONS) do
	-- POSIX launch lines start with SPAWN_PROVIDER=<p>, which Tern reports as the command name.
	for _, name in ipairs({ program, "SPAWN_PROVIDER=" .. program }) do
		local ok, err = pcall(tern.chrome.program_icon, name, icon)
		if not ok then table.insert(icon_errors, name .. ": " .. tostring(err)) end
	end
end

local observer: any = nil
local observer_key: string? = nil
local observer_loading = false
local observer_waiters = {}
local queues: any = {}
local authority_panes: any = {}
local parked_origins: any = {}
local tracked: any = {}
local setup: any = nil
local batches: any = {}
local next_local_id = 0
local open_running: any
local reconcile: any
local pump: any
local collect_setup: any

local function nonempty(value: any): string?
	if type(value) ~= "string" or not value:find("%S") then return nil end
	return value
end
local function integer(value: any): boolean
	return type(value) == "number" and value >= 0 and value % 1 == 0 and value <= 9007199254740991
end
local function identity(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum and not value:find("%c")
end
local function valid_attempt(attempt: any): boolean
	if type(attempt) ~= "table" or type(attempt.id) ~= "string" then return false end
	local number = tonumber(attempt.id:match("^attempt%-(%d+)$"))
	if number == nil then return false end
	return Launch.validate({ version = 1, revision = 0, next_attempt = number + 1, attempts = { attempt } }) ~= nil
end
local function valid_origin(origin: any): boolean
	return type(origin) == "table" and integer(origin.host) and integer(origin.session) and identity(origin.host_key, 2048) and identity(origin.authority_id, 256) and identity(origin.session_key, 2048) and integer(origin.pane) and integer(origin.config_revision)
end
local function active(attempt: any): boolean
	return attempt.phase == "Starting" or attempt.phase == "Running" or attempt.phase == "Waiting for input"
end
local function fail(cx: any, message: any)
	cx:toast("error", "SPAWN", tostring(message))
end
local function label(record: any): string
	return record.provider .. " — " .. record.account_label
end
local function host_key(host: any): string
	for _, key in ipairs({ "name", "address", "id", "kind" }) do
		local value = host[key]
		if (type(value) == "string" and value ~= "") or type(value) == "number" then return "host:" .. string.lower(tostring(value)) end
	end
	return "host:unknown"
end
local function contains(values: any, wanted: any): boolean
	if type(values) ~= "table" then return false end
	for _, value in values do if value == wanted then return true end end
	return false
end
local function capture(cx: any): (any?, string?)
	local ok, host, session = pcall(function() return cx.hosts:current(), cx.sessions:current() end)
	if not ok or type(host) ~= "table" or type(session) ~= "table" then return nil, "The active host/session is unavailable" end
	if host.state ~= "connected" then return nil, "The active Tern host is " .. tostring(host.state) .. "; no launch or reconnect was attempted" end
	if session.host ~= host.id or not contains(host.sessions, session.id) then return nil, "The active session's host membership is unknown" end
	return { host = host.id, session = session.id, host_key = host_key(host), host_info = { id = host.id, name = host.name, kind = host.kind, address = host.address } }, nil
end
local function context_error(cx: any, origin: any, require_current: boolean?): string?
	local ok, hosts, sessions = pcall(function() return cx.hosts:list(), cx.sessions:list() end)
	if not ok then return "The captured host/session is unavailable" end
	local found_host, found_session = false, false
	for _, host in hosts do
		if host.id == origin.host then
			if host.state ~= "connected" then return "The captured Tern host is " .. tostring(host.state) end
			if host_key(host) ~= origin.host_key or not contains(host.sessions, origin.session) then return "The captured host identity or session membership changed" end
			found_host = true
		end
	end
	for _, session in sessions do if session.id == origin.session and session.host == origin.host then found_session = true end end
	if not found_host or not found_session then return "The captured host/session is no longer attached" end
	if require_current then
		local current, err = capture(cx)
		if current == nil then return err end
		if current.host ~= origin.host or current.session ~= origin.session then return "The active host/session changed; return to the original session and choose the action again" end
	end
	return nil
end
local function pane_member(cx: any, origin: any, pane: number, require_local: boolean?): boolean
	local ok, result = pcall(function()
		local tab = cx.session:tab_of(pane)
		if tab == nil then return false end
		local in_session = false
		for _, candidate in cx.session:tabs() do if candidate.id == tab and candidate.session == origin.session then in_session = true end end
		for _, host in cx.hosts:list() do if host.id == origin.host then return in_session and contains(host.panes, pane) and (not require_local or host.kind == "local") end end
		return false
	end)
	return ok and result == true
end
local function ticket_association(cx: any, origin: any, ticket: string, inventory: any?): (number?, string?, any?)
	local changed = context_error(cx, origin, false)
	if changed ~= nil then return nil, changed, nil end
	local read_ok, agents = pcall(function() return inventory or cx.agents:list() end)
	if not read_ok or type(agents) ~= "table" then return nil, "This window's ticket inventory is unavailable", nil end
	local matched, count = nil, 0
	for _, agent in agents do
		count += 1
		if count > 1024 then return nil, "Ticket association inventory exceeds its bound", nil end
		if type(agent) == "table" and agent.command == ticket and integer(agent.pane) and pane_member(cx, origin, agent.pane) then
			-- Verify native membership only for exact-ticket candidates, not
			-- every unrelated agent once per saved job.
			if matched ~= nil then return nil, "More than one pane has this execution ticket; association is ambiguous", nil end
			matched = agent
		end
	end
	if matched == nil then return nil, "The execution ticket has no visible pane in the captured host/session", nil end
	return matched.pane, nil, matched
end
local function native_detail(cx: any, pane: number, agent: any): string?
	local ok, tree = pcall(function() return cx.session:surface(pane, { as = "table", nodes = 1, depth = 1, max_chars = 1024 }) end)
	if not ok or type(tree) ~= "table" or type(tree.surface) ~= "table" or tree.surface.role ~= "omp.session" then return nil end
	if agent.state == "working" then return "Native OMP UI: working" end
	if agent.state == "waiting_input" or agent.state == "idle" then return "Native OMP UI: waiting for input (not a sign-in diagnosis)" end
	return "Native OMP UI: " .. tostring(agent.state or "observed")
end
local function refresh_artwork(cx: any)
	local rules = {}
	if observer ~= nil then
		for _, track in tracked do
			local image = ARTWORK[string.lower(track.job.provider)]
			if image == nil or track.job.backend == "native-agent" or track.closed or track.authority_error ~= nil or not integer(track.pane) or track.job.pane_reused then continue end
			if track.attempt.scope ~= track.origin.session_key or track.attempt.record_id ~= track.job.record_id then continue end
			-- Remote SDK IDs differ from native chrome IDs; emitting them can
			-- collide with another identity domain. Only verified local panes
			-- can receive artwork until Tern exposes a supported identity bridge.
			if context_error(cx, track.origin, false) ~= nil or not pane_member(cx, track.origin, track.pane, true) then continue end
			local associated = ticket_association(cx, track.origin, track.job.ticket)
			if associated ~= track.pane then continue end
			if track.attempt.phase == "Unknown" or track.job.stage == "admitted" or track.job.stage == "claimed" or track.job.stage == "submission_intent" then continue end
			local pane = string.format("%.0f", track.pane)
			local face = ".tn-face[data-pane='" .. pane .. "']"
			local tile = ".tn-dk-c[data-pane='" .. pane .. "']"
			-- Keep native box geometry, tile color and status/badge children.
			-- Opacity hides only the replaced glyph without collapsing its box.
			table.insert(rules, face .. ", " .. tile .. " { background-image: " .. image .. "; background-position: center; background-size: contain; background-repeat: no-repeat; }\n"
				.. face .. " > svg.ico, " .. tile .. " > svg.ico { opacity: 0; }")
		end
	end
	table.sort(rules)
	local source = table.concat(rules, "\n")
	if source ~= artwork_css then
		tern.css("provider-artwork", source)
		artwork_css = source
	end
end
-- tern.kv cannot list keys: a per-namespace index bounds per-connection journals.
-- Drop this window's older incarnations and keep the 8 most recently saved keys.
local observer_index: string? = nil
local observer_window: string? = nil
local function prune_journals()
	if observer_index == nil or observer_key == nil then return end
	local index = tern.kv.get(observer_index)
	if type(index) ~= "table" then index = {} end
	index[observer_key] = { window = observer_window, saved = os.time() }
	local keys = {}
	for key, entry in index do
		if type(key) ~= "string" or key:sub(1, 16) ~= "window-observer:" or type(entry) ~= "table" or type(entry.saved) ~= "number" then index[key] = nil
		elseif key ~= observer_key and entry.window == observer_window then tern.kv.set(key, nil); index[key] = nil
		else table.insert(keys, key) end
	end
	table.sort(keys, function(a, b)
		if a == observer_key or b == observer_key then return a == observer_key and b ~= observer_key end
		return index[a].saved > index[b].saved
	end)
	for position = 9, #keys do tern.kv.set(keys[position], nil); index[keys[position]] = nil end
	tern.kv.set(observer_index, index)
end
local function save_observer(cx: any): boolean
	if observer == nil or observer_key == nil then fail(cx, "The window observer identity is unavailable"); return false end
	observer.tracked = tracked
	observer.setup = setup
	local ok, err = pcall(tern.kv.set, observer_key, observer)
	if not ok then fail(cx, "Could not persist this window's launch journal: " .. tostring(err)) end
	if ok then pcall(prune_journals) end
	return ok
end

-- Never use the host's numeric pane IDs or a shared client KV observer ID.
-- The local native client connection's (window, conn, since) is the incarnation.
local function ensure_observer(cx: any, callback: any)
	if observer ~= nil then callback(cx, nil); return end
	if #observer_waiters >= MAX_QUEUE then callback(cx, "Window initialization queue is full"); return end
	table.insert(observer_waiters, callback)
	if observer_loading then return end
	observer_loading = true
	local window = cx:window_key()
	local started, start_error = pcall(function()
		Native.inspect(window, { timeout_ms = 5000 }, function(result, err, fresh)
			if fresh == nil then return end
			local problem = err
			local client = nil
			if problem == nil and (result == nil or result.status ~= 0 or result.timed_out) then problem = "Could not inspect this native client incarnation" end
			if problem == nil then
				local decoded, inventory = pcall(tern.json.decode, result.stdout)
				if not decoded or type(inventory) ~= "table" or type(inventory.clients) ~= "table" then problem = "Native client inventory is invalid"
				else
					for _, entry in inventory.clients do
						if entry.kind == "window" and entry.window == window then
							if client ~= nil then problem = "Native client incarnation is ambiguous"; break end
							client = entry
						end
					end
				end
			end
			if problem == nil and (client == nil or not integer(client.conn) or not integer(client.since)) then problem = "Native client incarnation is unavailable; existing reservations remain unresolved" end
			if problem == nil then
				local loaded, data = pcall(function()
					local namespace = tern.kv.get("window-observer-namespace")
					if namespace == nil then
						namespace = tostring(os.time()) .. "-" .. tostring(math.random(1, 2147483647))
						tern.kv.set("window-observer-namespace", namespace)
					end
					if not identity(namespace, 96) then error("Invalid client observer namespace") end
					local id = "window-" .. namespace .. "-" .. tostring(client.conn) .. "-" .. string.format("%.0f", client.since) .. "-" .. window
					if not identity(id, 200) then error("Native observer identity exceeds the supported length") end
					observer_key = "window-observer:" .. id
					observer_index, observer_window = "window-observer-index:" .. namespace, window
					pcall(prune_journals)
					local saved = tern.kv.get(observer_key)
					if saved == nil then saved = { version = 2, id = id, transports = {}, tracked = {}, next_run = 1 } end
					if type(saved) ~= "table" or saved.version ~= 2 or saved.id ~= id or type(saved.transports) ~= "table" or type(saved.tracked) ~= "table" or not integer(saved.next_run) then error("Unsupported or invalid window launch journal; expected version 2. The saved journal was preserved, not reset or replayed") end
					for authority_id, state in saved.transports do
						if not identity(authority_id, 256) or type(state) ~= "table" or not integer(state.sequence) or type(state.acknowledgments) ~= "table" then error("Invalid saved authority transport; no request was replayed") end
						local count, seen = 0, {}
						for index, request_id in state.acknowledgments do
							count += 1
							if count > 64 or not integer(index) or index < 1 or index > #state.acknowledgments or not identity(request_id, 512) or seen[request_id] then error("Invalid saved request acknowledgment journal") end
							seen[request_id] = true
						end
						if count ~= #state.acknowledgments then error("Invalid sparse request acknowledgment journal") end
						if state.pending ~= nil then
							local ops = { refresh = true, import_records = true, launch_record = true, start_setup = true, resolve_attempt = true, resolve_lost_attempts = true }
							if type(state.pending) ~= "table" or not identity(state.pending.request_id, 512) or not ops[state.pending.op] then error("Invalid pending request journal; inspect Config without replaying it") end
						end
					end
					for key, track in saved.tracked do
						if type(key) ~= "string" or type(track) ~= "table" or not valid_attempt(track.attempt) or Launch.validate_execution_projection(track.job) == nil or not valid_origin(track.origin) or type(track.allocation_intent) ~= "boolean" or (track.pane ~= nil and not integer(track.pane)) then error("Invalid saved launch association; preserved for inspection") end
						if key ~= track.attempt.id .. "@" .. track.origin.authority_id or track.job.attempt_id ~= track.attempt.id or track.job.record_id ~= track.attempt.record_id or track.job.session_key ~= track.origin.session_key or track.attempt.scope ~= track.origin.session_key then error("Saved execution association identity mismatch") end
					end
					if saved.setup ~= nil and (type(saved.setup) ~= "table" or not identity(saved.setup.id, 256) or not valid_origin(saved.setup.origin) or not identity(saved.setup.job_id, 96) or not identity(saved.setup.ticket, 512) or type(saved.setup.initial_prompt) ~= "string" or #saved.setup.initial_prompt > 120000 or (saved.setup.pane ~= nil and not integer(saved.setup.pane))) then error("Invalid saved setup run; use Config paste recovery") end
					-- Optional, additive within version 2: one shown host-restart notice per session.
					if saved.restart_notices ~= nil then
						if type(saved.restart_notices) ~= "table" then error("Invalid saved host restart notices") end
						local notices = 0
						for session_key, restart_id in saved.restart_notices do
							notices += 1
							if notices > 64 or not identity(session_key, 2048) or not identity(restart_id, 64) then error("Invalid saved host restart notices") end
						end
					end
					return saved
				end)
				if loaded then observer = data; tracked = data.tracked; setup = data.setup else problem = tostring(data) end
			end
			observer_loading = false
			local waiting = observer_waiters; observer_waiters = {}
			for _, ready in waiting do ready(fresh, problem) end
		end)
	end)
	if not started then
		observer_loading = false
		local waiting = observer_waiters; observer_waiters = {}
		for _, ready in waiting do ready(cx, tostring(start_error)) end
	end
end

local function validate_snapshot(value: any): (any?, string?)
	if type(value) ~= "table" or value.version ~= 2 or type(value.ready) ~= "boolean" then return nil, "Unsupported authority snapshot" end
	if not identity(value.host_key, 2048) or not identity(value.authority_id, 256) or not identity(value.session_key, 2048) then return nil, "Authority identity is invalid" end
	if value.namespace ~= nil and not identity(value.namespace, 256) then return nil, "Authority namespace is invalid" end
	if not integer(value.config_revision) or not integer(value.attempt_revision) then return nil, "Authority revision is invalid" end
	local records, err = Config.validate_records(value.records)
	if records == nil then return nil, "Invalid authority roster: " .. tostring(err) end
	if type(value.attempts) ~= "table" then return nil, "Invalid authority launch history" end
	local next_attempt = 1
	local attempts = {}
	for _, attempt in value.attempts do
		if type(attempt) ~= "table" or type(attempt.id) ~= "string" then return nil, "Invalid authority attempt" end
		local number = tonumber(attempt.id:match("^attempt%-(%d+)$"))
		if number == nil then return nil, "Invalid authority attempt ID" end
		next_attempt = math.max(next_attempt, number + 1)
		if attempt.scope ~= value.session_key then return nil, "Authority attempt scope mismatch" end
		attempts[attempt.id] = attempt
	end
	local state, state_error = Launch.validate({ version = 1, revision = value.attempt_revision, next_attempt = next_attempt, attempts = value.attempts })
	if state == nil then return nil, "Invalid authority launch history: " .. tostring(state_error) end
	if type(value.jobs) ~= "table" then return nil, "Authority execution jobs are missing" end
	local jobs, attempt_jobs, job_count, ordinary_count = {}, {}, 0, 0
	for _, attempt in value.attempts do
		if attempt.purpose ~= "managed" then ordinary_count += 1 end
	end
	for index, job in value.jobs do
		job_count += 1
		if job_count > 128 or not integer(index) or index < 1 or index > #value.jobs or Launch.validate_execution_projection(job) == nil then return nil, "Invalid authority execution projection" end
		local attempt = attempts[job.attempt_id]
		if jobs[job.id] or attempt_jobs[job.attempt_id] or attempt == nil or attempt.purpose == "managed" or job.session_key ~= value.session_key or job.record_id ~= attempt.record_id or MODES[job.backend] ~= attempt.mode or (job.purpose == "setup") ~= (attempt.purpose == "setup") or job.config_revision > value.config_revision then return nil, "Authority execution association mismatch" end
		jobs[job.id] = job
		attempt_jobs[job.attempt_id] = job
	end
	if job_count ~= #value.jobs or job_count ~= ordinary_count then return nil, "Authority job/attempt history is incomplete" end
	if type(value.replies) ~= "table" or type(value.request_sequences) ~= "table" then return nil, "Authority transport state is missing" end
	local count = 0
	for id, reply in value.replies do
		count += 1
		if count > 64 or not identity(id, 512) or type(reply) ~= "table" or reply.request_id ~= id or not identity(reply.observer_id, 256) or not integer(reply.request_sequence) or type(reply.ok) ~= "boolean" or not integer(reply.config_revision) or not integer(reply.attempt_revision) or (reply.error ~= nil and type(reply.error) ~= "string") then return nil, "Invalid authority reply envelope" end
	end
	count = 0
	for id, sequence in value.request_sequences do
		count += 1
		if count > 64 or not identity(id, 256) or not integer(sequence) then return nil, "Invalid authority request watermark" end
	end
	if value.error ~= nil and type(value.error) ~= "string" then return nil, "Invalid authority error" end
	if value.host_restart ~= nil then
		local restart = value.host_restart
		local valid = type(restart) == "table" and identity(restart.restart_id, 64) and type(restart.attempts) == "table"
		if valid then
			for name in restart do if name ~= "restart_id" and name ~= "attempts" then valid = false end end
		end
		if valid then
			local listed, seen = 0, {}
			for index, id in restart.attempts do
				listed += 1
				local attempt = if type(id) == "string" then attempts[id] else nil
				if listed > 128 or not integer(index) or index < 1 or index > #restart.attempts or attempt == nil or seen[id]
					or attempt.phase ~= "Unknown" or attempt.unresolved ~= true or attempt.purpose == "managed" then valid = false; break end
				seen[id] = true
			end
			if valid and (listed == 0 or listed ~= #restart.attempts) then valid = false end
		end
		if not valid then return nil, "Invalid host restart notice" end
	end
	value.records = records
	return value, nil
end
local function snapshot(cx: any, origin: any, readonly: boolean?): (any?, string?)
	local problem = context_error(cx, origin, false)
	if problem ~= nil then return nil, problem end
	if not pane_member(cx, origin, origin.pane) then
		local pane = cx.session:pane(origin.pane)
		local parked_here = false
		for _, host in cx.hosts:list() do
			if host.id == origin.host and contains(host.panes, origin.pane) then parked_here = true end
		end
		-- Parking removes tab membership, not the already-bound status source.
		-- Writes still require visible membership; canonical scope is checked below.
		if not readonly or origin.authority_id == nil or pane == nil or not pane.parked or not parked_here then
			return nil, "The SPAWN authority is no longer visible in the captured session"
		end
	end
	local ok, tree = pcall(function()
		local pane = cx.session:pane(origin.pane)
		if pane == nil or pane.block ~= BLOCK then error("The captured block is not SPAWN Config") end
		return cx.session:surface(origin.pane, { as = "table", root = "main.spawn-state", nodes = 4, depth = 2, max_chars = 128000 })
	end)
	if not ok then return nil, tostring(tree) end
	if type(tree) ~= "table" or type(tree.surface) ~= "table" or tree.surface.role ~= "plugin.spawn.spawner" or (tree.more ~= nil and tree.more ~= 0) then return nil, "The authority surface is unavailable or clipped" end
	local node = tree.main
	if type(node) ~= "table" or node.id ~= "main.spawn-state" or node.k ~= "text" or type(node.p) ~= "table" or (node.more ~= nil and node.more ~= 0) then return nil, "The exact authority snapshot node is unavailable" end
	local spans = node.p.spans
	if type(spans) ~= "table" then return nil, "The authority text spans are unavailable" end
	local parts, bytes = {}, 0
	for index, span in ipairs(spans) do
		if type(span) ~= "table" or type(span.t) ~= "string" then return nil, "The authority text span is invalid" end
		bytes += #span.t
		if bytes > 120000 then return nil, "The authority snapshot exceeds its byte limit" end
		parts[index] = span.t
	end
	local text = table.concat(parts)
	if text:sub(1, #PREFIX) ~= PREFIX then return nil, "The authority snapshot prefix is missing" end
	local decoded, raw = pcall(tern.json.decode, text:sub(#PREFIX + 1))
	if not decoded then return nil, "The authority snapshot is incomplete or invalid JSON" end
	local value, err = validate_snapshot(raw)
	if value == nil then return nil, err end
	-- The persisted roster key is not this client's display/route alias.
	-- Verified pane membership and canonical authority/session IDs bind scope.
	if origin.authority_id ~= nil and (value.authority_id ~= origin.authority_id or value.session_key ~= origin.session_key) then return nil, "The authority identity changed; choose the action again" end
	if not readonly and not value.ready then return nil, value.error or "Config requires review before this host is ready" end
	if not readonly and value.error ~= nil then return nil, value.error end
	return value, nil
end
local function block_args(cx: any, origin: any): { string }
	local context: any = { kind = "context", host = origin.host_info, native_window = cx:window_key() }
	local ok, legacy = pcall(tern.kv.get, "config")
	if not ok then error("Could not read the legacy client roster for conflict review: " .. tostring(legacy)) end
	if legacy ~= nil then context.client_config = legacy end
	local encoded = tern.json.encode(context)
	if #encoded > 120000 then error("Legacy client configuration is too large; preserve it and review Config manually") end
	return { encoded }
end
local function find_authority(cx: any, origin: any): number?
	local key = tostring(origin.host) .. "/" .. tostring(origin.session)
	local remembered = authority_panes[key]
	if remembered ~= nil and pane_member(cx, origin, remembered) then
		local info = cx.session:pane(remembered)
		if info ~= nil and info.block == BLOCK then return remembered end
	end
	local legacy = tern.kv.get("config")
	for _, pane in cx.session:panes() do
		if pane.block ~= BLOCK or not pane_member(cx, origin, pane.pane) then continue end
		if legacy == nil then return pane.pane end
		local candidate = table.clone(origin)
		candidate.pane = pane.pane
		local value = snapshot(cx, candidate, true)
		-- Reuse a visible authority this observer already contacted, including
		-- after reload. A new client's legacy copy still requires its own review.
		if value ~= nil and observer ~= nil and observer.transports[value.authority_id] ~= nil then return pane.pane end
	end
	-- Unpark only a parked Config whose read-only snapshot proves an authority
	-- already bound to this host/session (remembered at park time or tracked).
	-- Native session IDs differ from SDK IDs, so unknown parked blocks are never
	-- adopted. Several matches: the lowest pane ID is reused, others untouched.
	local known = {}
	if parked_origins[key] ~= nil then known[parked_origins[key].authority_id] = parked_origins[key] end
	for _, track in tracked do
		local bound = track.origin
		if bound.host == origin.host and bound.session == origin.session then known[bound.authority_id] = bound end
	end
	local chosen: number? = nil
	for _, pane in cx.session:panes() do
		if not pane.parked or pane.block ~= BLOCK or (chosen ~= nil and pane.pane >= chosen) then continue end
		for _, bound in known do
			local candidate = table.clone(bound)
			candidate.pane = pane.pane
			if snapshot(cx, candidate, true) ~= nil then chosen = pane.pane; break end
		end
	end
	if chosen == nil then return nil end
	local restored, err = cx.layout:unpark(chosen, { focus = false })
	if not restored then error("Could not reopen SPAWN Config: " .. tostring(err)) end
	return chosen
end
local function with_authority(cx: any, callback: any, readonly: boolean?)
	local origin, capture_error = capture(cx)
	if origin == nil then fail(cx, capture_error); return end
	ensure_observer(cx, function(fresh, identity_error)
		if identity_error ~= nil then fail(fresh, identity_error); return end
		local changed = context_error(fresh, origin, true)
		if changed ~= nil then fail(fresh, changed); return end
		local opened, pane = pcall(function()
			return find_authority(fresh, origin) or fresh:new_block(BLOCK, block_args(fresh, origin), "beside", { focus = false })
		end)
		if not opened or pane == nil then fail(fresh, "Could not open host Config: " .. tostring(pane)); return end
		origin.pane = pane
		authority_panes[tostring(origin.host) .. "/" .. tostring(origin.session)] = pane
		local polls = 0
		local function read_ready(next_cx: any)
			if next_cx == nil then return end
			local changed_now = context_error(next_cx, origin, true)
			if changed_now ~= nil then fail(next_cx, changed_now); return end
			local value, err = snapshot(next_cx, origin, readonly)
			if value ~= nil then
				origin.authority_id, origin.session_key = value.authority_id, value.session_key
				origin.config_revision = value.config_revision
				callback(next_cx, origin, value)
				return
			end
			polls += 1
			if polls >= 240 then fail(next_cx, tostring(err) .. ". Review the visible Config block; no command was launched."); return end
			tern.timer(POLL_MS, read_ready)
		end
		read_ready(fresh)
	end)
end
local function open_config(cx: any)
	local origin, err = capture(cx)
	if origin == nil then fail(cx, err); return end
	local ok, pane = pcall(function()
		local existing = find_authority(cx, origin)
		if existing ~= nil then cx.layout:focus(existing); return existing end
		return cx:new_block(BLOCK, block_args(cx, origin), "beside", { focus = true })
	end)
	if not ok or pane == nil then fail(cx, "Could not open Config: " .. tostring(pane))
	else authority_panes[tostring(origin.host) .. "/" .. tostring(origin.session)] = pane end
end

local function transport(origin: any): any
	local value = observer.transports[origin.authority_id]
	if value == nil then value = { sequence = 0, acknowledgments = {} }; observer.transports[origin.authority_id] = value end
	return value
end
local function request(cx: any, origin: any, op: string, data: any, callback: any)
	local queue = queues[origin.authority_id]
	if queue == nil then queue = { items = {}, busy = false }; queues[origin.authority_id] = queue end
	if #queue.items >= MAX_QUEUE then callback(cx, nil, "The authority request queue is full"); return end
	table.insert(queue.items, { origin = origin, expected_config_revision = origin.config_revision, op = op, data = data, callback = callback })
	pump(cx, queue)
end
pump = function(cx: any, queue: any)
	if queue.busy or #queue.items == 0 then return end
	local item = table.remove(queue.items, 1)
	queue.busy = true
	local origin = item.origin
	local finished = false
	local function finish(fresh: any, reply: any, err: any)
		if finished then return end
		finished = true
		-- Reply validation and pane allocation must not share one UI budget.
		tern.timer(1, function(next_cx)
			if next_cx == nil then return end
			queue.busy = false
			local handled, callback_error = pcall(item.callback, next_cx, reply, err)
			if not handled then fail(next_cx, "Authority action callback failed; no action was replayed. Inspect Config and retained panes: " .. tostring(callback_error)) end
			pump(next_cx, queue)
		end)
	end
	local prepared, prepare_error = pcall(function()
	local value, err = snapshot(cx, origin)
	if item.op ~= "refresh" then
		local changed = context_error(cx, origin, true)
		if changed ~= nil then finish(cx, nil, changed); return end
	end
	if value == nil then finish(cx, nil, err); return end
	local state = transport(origin)
	if type(state) ~= "table" or not integer(state.sequence) or type(state.acknowledgments) ~= "table" then finish(cx, nil, "The saved observer transport is invalid"); return end
	if state.pending ~= nil then
		local pending, prior_acknowledgments = state.pending, state.acknowledgments
		local refused = value.replies[pending.request_id]
		if not Launch.refused_pending(pending, refused, observer.id) then
			finish(cx, nil, "An earlier " .. tostring(pending.op) .. " request has an unreviewed outcome. Open SPAWN: Running agents → Transport review → acknowledge it, then try again."); return
		end
		-- A definitive refusal executed nothing; settle it exactly as the poll does.
		state.acknowledgments = { pending.request_id }
		state.pending = nil
		if not save_observer(cx) then
			state.pending, state.acknowledgments = pending, prior_acknowledgments
			finish(cx, nil, "An earlier " .. tostring(pending.op) .. " request has an unreviewed outcome. Open SPAWN: Running agents → Transport review → acknowledge it, then try again."); return
		end
		cx:toast("info", "Cleared an earlier refused SPAWN request", "The host refused " .. tostring(pending.op) .. " (" .. tostring(refused.error) .. "); nothing ran. Continuing with your new request.")
	end
	state.sequence = math.max(state.sequence, value.request_sequences[observer.id] or 0) + 1
	local id = observer.id .. ":" .. tostring(state.sequence)
	local acknowledged = {}
	for index, request_id in ipairs(state.acknowledgments) do acknowledged[index] = request_id end
	local payload = { version = 2, request_id = id, authority_id = origin.authority_id, observer_id = observer.id, request_sequence = state.sequence, acknowledged_requests = acknowledged, expected_config_revision = item.expected_config_revision, op = item.op, data = item.data }
	state.pending = { request_id = id, op = item.op }
	if not save_observer(cx) then finish(cx, nil, "Request was not sent because its journal could not be saved"); return end
	local sent, send_error = pcall(function()
		local encoded = tern.json.encode(payload)
		if #encoded > 120000 then error("Request exceeds the authority byte limit") end
		cx.session:event(origin.pane, { ev = "action", id = "main", act = "spawn.request", value = encoded })
	end)
	if not sent then finish(cx, nil, "Request delivery is uncertain: " .. tostring(send_error) .. "; inspect Config before another launch"); return end
	local polls = 0
	local function poll(fresh: any)
		if fresh == nil or finished then return end
		local read_ok, read_failure = pcall(function()
		local latest, read_error = snapshot(fresh, origin, true)
		if latest ~= nil then
			local reply = latest.replies[id]
			if reply ~= nil then
				if reply.request_id ~= id or reply.observer_id ~= observer.id or reply.request_sequence ~= payload.request_sequence then finish(fresh, nil, "Authority reply identity mismatch"); return end
				-- A rejected stale action stays rejected. Retain the host's revision
				-- only for the next deliberate action, including saved setup recovery.
				origin.config_revision = reply.config_revision
				state.acknowledgments = { id }
				state.pending = nil
				if not save_observer(fresh) then finish(fresh, nil, "Reply consumption could not be persisted; no launch was authorized"); return end
				finish(fresh, reply, if reply.ok then nil else reply.error or "Authority rejected the request")
				return
			end
		end
		polls += 1
		if polls >= 240 then finish(fresh, nil, "Authority acknowledgment timed out: " .. tostring(read_error or "no matching durable reply") .. ". No automatic resend; inspect Config for the retained result."); return end
		tern.timer(POLL_MS, poll)
		end)
		if not read_ok then finish(fresh, nil, "Authority reply handling failed; request outcome remains uncertain and was not replayed: " .. tostring(read_failure)) end
	end
	tern.timer(POLL_MS, poll)
	end)
	if not prepared then finish(cx, nil, "Authority request handling failed; no request was replayed. Inspect Config before another launch: " .. tostring(prepare_error)) end
end


local function batch_summary(cx: any, batch: any)
	local counts = { Starting = 0, Running = 0, ["Waiting for input"] = 0, Exited = 0, Failed = batch.failed, Unknown = 0 }
	for _, attempt_id in batch.attempts do
		local track = tracked[attempt_id .. "@" .. batch.origin.authority_id]
		if track ~= nil then
			local phase = track.attempt.phase
			if active(track.attempt) and (track.authority_error ~= nil or track.allocation_error ~= nil or context_error(cx, track.origin, false) ~= nil) then phase = "Unknown" end
			counts[phase] += 1
		end
	end
	cx:toast(if counts.Failed > 0 then "error" else "info", "SPAWN batch observations", string.format("%d starting · %d running · %d waiting · %d exited · %d failed · %d unknown · %d skipped", counts.Starting, counts.Running, counts["Waiting for input"], counts.Exited, counts.Failed, counts.Unknown, batch.skipped))
	if not batch.completed or batch.dismissed or counts.Starting > 0 or counts.Failed > 0 or counts.Unknown > 0 then return end
	local origin = batch.origin
	-- Never hide Config under other in-flight work for this authority.
	local queue, state = queues[origin.authority_id], observer and observer.transports[origin.authority_id]
	if (queue ~= nil and (queue.busy or #queue.items > 0)) or (state ~= nil and state.pending ~= nil) then return end
	for _, other in batches do
		if other ~= batch and other.origin.authority_id == origin.authority_id and not other.completed and not other.stopped then return end
	end
	if context_error(cx, origin, true) ~= nil then return end
	local value = snapshot(cx, origin)
	if value == nil then return end
	for _, attempt in value.attempts do
		if batch.record_ids[attempt.record_id] and (attempt.phase == "Starting" or (attempt.phase == "Unknown" and attempt.unresolved)) then return end
	end
	-- Hide only the ready view that started this batch, and never while focused.
	local info = cx.session:pane(origin.pane)
	if info == nil or info.focused then return end
	local parked, err = cx.layout:park(origin.pane)
	if not parked then fail(cx, "Spawning finished, but SPAWN Config could not be hidden: " .. tostring(err)); return end
	batch.dismissed = true
	local key = tostring(origin.host) .. "/" .. tostring(origin.session)
	authority_panes[key], parked_origins[key] = origin.pane, table.clone(origin)
end
local function sync_snapshot(cx: any, origin: any, value: any)
	local attempts, present, changed_batches = {}, {}, {}
	for _, attempt in value.attempts do attempts[attempt.id] = attempt end
	local inventory_ok, inventory = pcall(function() return cx.agents:list() end)
	local changed = false
	for _, job in value.jobs do
		local key = job.attempt_id .. "@" .. origin.authority_id
		present[key] = true
		local attempt = attempts[job.attempt_id]
		local track = tracked[key]
		if track == nil then
			track = { origin = origin, job = job, attempt = attempt, allocation_intent = false }
			tracked[key] = track
			changed = true
		elseif track.job.ticket ~= job.ticket then
			track.authority_error = "The host execution ticket changed; the saved association was preserved"
			continue
		end
		local old_job, old_attempt = track.job, track.attempt
		local progressed = old_attempt.sequence ~= attempt.sequence or old_job.stage ~= job.stage or old_job.pane_reused ~= job.pane_reused or old_job.native_pane ~= job.native_pane or old_job.native_window ~= job.native_window or old_job.native_tab ~= job.native_tab or old_job.shell_program ~= job.shell_program
		if progressed or track.authority_error ~= nil then changed = true end
		if track.origin.host == origin.host and track.origin.session == origin.session and track.origin.pane ~= origin.pane then track.origin.pane = origin.pane; changed = true end
		track.job, track.attempt, track.authority_error = job, attempt, nil
		if progressed and track.batch ~= nil then changed_batches[track.batch] = true end
		local pane, association_error, agent = nil, "This window's ticket inventory is unavailable", nil
		if inventory_ok then pane, association_error, agent = ticket_association(cx, track.origin, job.ticket, inventory) end
		if pane ~= nil and track.pane ~= nil and pane ~= track.pane then
			pane, association_error = nil, "The ticket no longer matches this window's retained SDK pane; no identity was rebound"
		end
		if track.association_error ~= association_error then changed = true end
		track.association_error = association_error
		track.native_detail = nil
		if pane ~= nil then
			if track.pane == nil or track.closed then changed = true end
			track.pane, track.closed = pane, false
			if track.allocation_error ~= nil and job.native_pane ~= nil then track.allocation_error = nil; changed = true; if track.batch ~= nil then changed_batches[track.batch] = true end end
			if active(attempt) and not job.pane_reused and job.backend == "native-agent" then track.native_detail = native_detail(cx, pane, agent) end
			if setup ~= nil and setup.job_id == job.id and setup.origin.authority_id == origin.authority_id and setup.ticket == job.ticket then
				if setup.pane ~= pane or setup.closed then changed = true end
				setup.pane, setup.closed = pane, false
			end
		end
	end
	-- An explicit host history cleanup is authoritative; it is not a launch.
	for key, track in tracked do
		if track.origin.authority_id == origin.authority_id and not present[key] then tracked[key] = nil; changed = true end
	end
	refresh_artwork(cx)
	if changed then save_observer(cx) end
	local restart = value.host_restart
	if restart ~= nil and observer ~= nil then
		local notices = observer.restart_notices or {}
		if notices[value.session_key] ~= restart.restart_id then
			if notices[value.session_key] == nil then
				local entries = 0
				for _ in notices do entries += 1 end
				if entries >= 64 then notices[(next(notices))] = nil end
			end
			notices[value.session_key] = restart.restart_id
			observer.restart_notices = notices
			save_observer(cx)
			local lost = #restart.attempts
			cx:toast("info", "Host restarted — " .. tostring(lost) .. " SPAWN " .. (if lost == 1 then "agent was" else "agents were") .. " lost", "Nothing was relaunched. Running agents → Mark all lost agents no longer running after review.")
		end
	end
	for id in changed_batches do if batches[id] ~= nil then batch_summary(cx, batches[id]) end end
end
local function admission_result(reply: any, origin: any, record_id: string, purpose: string, run_id: string?): (any?, any?, string?)
	local result = reply.result
	if type(result) ~= "table" or not valid_attempt(result.attempt) or Launch.validate_execution_projection(result.job) == nil or (result.replayed ~= nil and type(result.replayed) ~= "boolean") then return nil, nil, "Invalid execution admission reply" end
	local job, attempt = result.job, result.attempt
	if job.id ~= attempt.id or job.record_id ~= record_id or attempt.record_id ~= record_id or MODES[job.backend] ~= attempt.mode or (job.purpose == "setup") ~= (attempt.purpose == "setup") or job.observer_id ~= observer.id or job.session_key ~= origin.session_key or attempt.scope ~= origin.session_key or job.purpose ~= purpose or job.setup_run_id ~= run_id or job.config_revision > reply.config_revision then
		return nil, nil, "Execution admission identity mismatch"
	end
	return job, attempt, nil
end
local SUBMISSION_BOUNDARY = { submitted = true, running = true, completed = true, failed = true, unknown = true, resolved = true }
local function await_submission(cx: any, track: any, complete: any)
	local polls, finished = 0, false
	local function finish(fresh: any, problem: string?)
		if finished then return end
		finished = true
		tern.timer(1, function(next_cx)
			if next_cx == nil then return end
			local ok, err = pcall(complete, next_cx, problem)
			if not ok then fail(next_cx, "Execution continuation failed; no ticket or command was replayed: " .. tostring(err)) end
		end)
	end
	local function poll(fresh: any)
		if fresh == nil or finished then return end
		local ok, err = pcall(function()
			local changed = context_error(fresh, track.origin, true)
			if changed ~= nil then finish(fresh, changed .. "; already accepted host work stays in its original session"); return end
			local value, read_error = snapshot(fresh, track.origin, true)
			if value ~= nil then
				sync_snapshot(fresh, track.origin, value)
				local current = tracked[track.attempt.id .. "@" .. track.origin.authority_id]
				if current == nil then finish(fresh, "The admitted execution history is unavailable; no allocation was repeated"); return end
				if value.config_revision ~= current.job.config_revision then finish(fresh, "Saved configuration changed; later batch records were not admitted. Already accepted host work stays in its original session."); return end
				if SUBMISSION_BOUNDARY[current.job.stage] then finish(fresh, nil); return end
			else
				track.authority_error = read_error
			end
			polls += 1
			if polls >= 240 then finish(fresh, "Host submission was not confirmed within the bounded wait. Later batch records were not admitted; inspect Running agents. The ticket will not be allocated again."); return end
			tern.timer(POLL_MS, poll)
		end)
		if not ok then finish(fresh, "Host submission observation failed; no launch was replayed: " .. tostring(err)) end
	end
	tern.timer(POLL_MS, poll)
end
local function allocate_ticket(cx: any, origin: any, job: any, attempt: any, replayed: boolean?, batch: any?, complete: any)
	local key = attempt.id .. "@" .. origin.authority_id
	local track = tracked[key]
	if track == nil then
		track = { origin = origin, job = job, attempt = attempt, allocation_intent = false }
		tracked[key] = track
	end
	if batch ~= nil then track.batch = batch.id; table.insert(batch.attempts, attempt.id) end
	local changed = context_error(cx, origin, true)
	if changed ~= nil then
		track.allocation_error = changed .. "; the admitted ticket was not allocated"
		save_observer(cx); complete(cx, track.allocation_error); return
	end
	local value, read_error = snapshot(cx, origin, true)
	if value == nil then track.allocation_error = read_error; save_observer(cx); complete(cx, read_error); return end
	sync_snapshot(cx, origin, value)
	track = tracked[key]
	if track == nil or track.job.ticket ~= job.ticket then complete(cx, "The admitted ticket no longer has its exact host job; nothing was allocated"); return end
	if replayed or track.allocation_intent or track.job.stage ~= "admitted" then
		-- A retained reply or lost allocation acknowledgment is observation-only.
		await_submission(cx, track, complete)
		return
	end
	if value.config_revision ~= job.config_revision or not value.ready or value.error ~= nil then
		track.allocation_error = value.error or "Saved configuration changed before allocation; inspect the unresolved admitted job"
		save_observer(cx); complete(cx, track.allocation_error); return
	end
	track.allocation_intent = true
	if not save_observer(cx) then complete(cx, "Allocation intent could not be saved; no layout call was made"); return end
	local ok, allocation_error = pcall(function()
		local launch = { command = job.ticket }
		local target = cx.session:focused()
		local replacement, replacement_tab = nil, nil
		if job.purpose == "launch" and job.backend == "native-agent" and job.placement == "replace_if_alone" and target ~= nil and pane_member(cx, origin, target) then
			local info, tab = cx.session:pane(target), cx.session:tab_of(target)
			local layout = if tab ~= nil then cx.session:layout(tab) else nil
			if info ~= nil and info.kind == "terminal" and info.at_prompt == true and not info.busy and info.running == nil and info.exited == nil and layout ~= nil and layout.root ~= nil and layout.root.pane == target and type(layout.floats) == "table" and next(layout.floats) == nil then
				replacement, replacement_tab = target, tab
			end
		end
		local pane
		if replacement ~= nil or (job.placement == "split" and target ~= nil and pane_member(cx, origin, target)) then
			pane = cx.layout:split(target, "right", launch, { focus = true })
		else
			-- Terminal/SSH replace_if_alone retains its existing new-tab behavior.
			pane = cx.layout:new_tab(launch, { focus = true })
		end
		if not integer(pane) then error("Layout did not return a Window SDK pane") end
		track.pane = pane
		if setup ~= nil and setup.job_id == job.id and setup.origin.authority_id == origin.authority_id then setup.pane = pane end
		if not save_observer(cx) then error("The returned pane could not be journaled; allocation will not be repeated") end
		if not pane_member(cx, origin, pane) then error("The returned pane's captured host/session membership is unavailable") end
		if replacement ~= nil then
			-- One synchronous Window composition, not a cross-client atomic swap.
			local old = cx.session:pane(replacement)
			if cx.session:tab_of(pane) ~= replacement_tab or cx.session:tab_of(replacement) ~= replacement_tab or not pane_member(cx, origin, replacement) or old == nil or old.kind ~= "terminal" or not old.at_prompt or old.busy or old.running ~= nil or old.exited ~= nil then
				fail(cx, "The checked idle pane changed; both panes were retained instead of closing another program")
			else
				local closed, close_error = pcall(function() cx.layout:close(replacement) end)
				if not closed then fail(cx, "The ticket was allocated, but the checked idle pane was retained: " .. tostring(close_error)) end
			end
		end
		local styled, style_error = pcall(function()
			local tab = cx.session:tab_of(pane)
			if tab == nil then error("Returned pane tab is unavailable") end
			cx.layout:name_tab(tab, job.provider .. job.account_label)
			local color = COLORS[string.lower(job.provider)]
			if color ~= nil then cx.layout:color_tab(tab, color) end
		end)
		if not styled then fail(cx, "The ticket was allocated, but tab styling failed: " .. tostring(style_error)) end
	end)
	if not ok then
		track.allocation_error = "Ticket allocation is uncertain and will not be repeated: " .. tostring(allocation_error)
		fail(cx, track.allocation_error)
		if not save_observer(cx) then complete(cx, "The allocation journal could not be saved; later records were not admitted"); return end
		-- Continue only after the host reports a submission/failure boundary,
		-- including expiry of an unclaimed ticket. Never allocate it again.
		await_submission(cx, track, complete)
		return
	end
	await_submission(cx, track, complete)
end
local function run_batch(cx: any, origin: any, records: any)
	next_local_id += 1
	local batch = { id = tostring(next_local_id), origin = origin, config_revision = origin.config_revision, attempts = {}, failed = 0, skipped = 0, record_ids = {} }
	for _, record in records do batch.record_ids[record.id] = true end
	batches[batch.id] = batch
	local index = 0
	local admit: any
	-- paced is true only after a record reached the host submission boundary.
	-- Skipped, duplicate and disabled records continue at once; the first
	-- record is never delayed. No ticket or admission exists during the wait.
	local function next_record(fresh: any, stop: string?, paced: boolean?)
		if stop ~= nil then batch.stopped = true; fail(fresh, stop); batch_summary(fresh, batch); return end
		index += 1
		if index > #records then batch.completed = true; batch_summary(fresh, batch); return end
		if paced then
			tern.timer(BATCH_INTERVAL_MS, function(next_cx)
				if next_cx == nil then batch.stopped = true; return end
				admit(next_cx)
			end)
			return
		end
		admit(fresh)
	end
	admit = function(fresh: any)
		local changed = context_error(fresh, origin, true)
		if origin.config_revision ~= batch.config_revision then changed = "Saved configuration changed during this batch; choose Spawn again after review" end
		if changed ~= nil then batch.stopped = true; fail(fresh, changed); batch_summary(fresh, batch); return end
		local record = records[index]
		request(fresh, origin, "launch_record", { record_id = record.id }, function(admitted_cx, reply, err)
			if err ~= nil then
				if err == "skip" or err == "duplicate" or err == "disabled" then batch.skipped += 1 else batch.failed += 1 end
				fail(admitted_cx, label(record) .. ": " .. tostring(err) .. ". Inspect Running agents for unresolved work.")
				next_record(admitted_cx); return
			end
			local job, attempt, admission_error = admission_result(reply, origin, record.id, "launch", nil)
			if job == nil then batch.failed += 1; next_record(admitted_cx, admission_error); return end
			allocate_ticket(admitted_cx, origin, job, attempt, reply.result.replayed, batch, function(done_cx: any, problem: string?)
				next_record(done_cx, problem, true)
			end)
		end)
	end
	next_record(cx)
end
local function spawn_all(cx: any)
	with_authority(cx, function(fresh, origin, value)
		local selected = {}
		for _, record in value.records do if record.enabled and record.include_all then table.insert(selected, record) end end
		if #selected == 0 then fresh:toast("info", "SPAWN", "No enabled saved records are included in Spawn all"); return end
		run_batch(fresh, origin, selected)
	end)
end
local function spawn_specific(cx: any)
	with_authority(cx, function(fresh, origin, value)
		local items = {}
		for _, record in value.records do
			if record.enabled and not record.review_required and (record.backend ~= "native-agent" or nonempty(record.prompt) ~= nil) then table.insert(items, { label = label(record) .. " [" .. record.id .. "]", detail = MODES[record.backend], record = record }) end
		end
		if #items == 0 then fresh:toast("info", "SPAWN", "No enabled reviewed records are available; review Config"); return end
		fresh:pick({ items = items, placeholder = "Choose a saved agent", icon = "sparkle" }):next(function(item, err, next_cx)
			if next_cx == nil then return end
			if err ~= nil then fail(next_cx, err); return end
			if item ~= nil then run_batch(next_cx, origin, { item.record }) end
		end)
	end)
end

local function startup_delivered(cx: any, pane: number, prompt: string): boolean
	-- The transcript API is specific to native OMP, but its flattened text can
	-- contain reaction chrome. Compare the full raw message body, not that text.
	local ok, messages = pcall(function() return cx.agents:transcript(pane, { last = 1000 }) end)
	if not ok or type(messages) ~= "table" then return false end
	local native_user = false
	for _, message in messages do
		if message.role == "user" and type(message.text) == "string" then native_user = true; break end
	end
	if not native_user then return false end
	local read_ok, tree = pcall(function()
		return cx.session:surface(pane, { as = "table", nodes = 1000, depth = 20, max_chars = 128000 })
	end)
	if not read_ok or type(tree) ~= "table" or type(tree.surface) ~= "table" or tree.surface.role ~= "omp.session" then return false end
	local nodes = 0
	local function first_user(node: any, depth: number): (any?, boolean)
		nodes += 1
		if type(node) ~= "table" or nodes > 1000 or depth > 20 then return nil, true end
		if type(node.p) == "table" and node.p.role == "omp.user" then return node, true end
		if node.c ~= nil and type(node.c) ~= "table" then return nil, true end
		for _, child in ipairs(node.c or {}) do
			local found, stop = first_user(child, depth + 1)
			if stop then return found, true end
		end
		return nil, node.more ~= nil and node.more ~= 0
	end
	local card = first_user(tree.main, 0)
	if card == nil or (card.more ~= nil and card.more ~= 0) or type(card.c) ~= "table" then return false end
	local body, body_count = nil, 0
	for _, child in ipairs(card.c) do
		if type(child) ~= "table" or type(child.p) ~= "table" then return false end
		if child.k == "md" and type(child.p.text) == "string" then
			if (child.more ~= nil and child.more ~= 0) or (child.c ~= nil and (type(child.c) ~= "table" or next(child.c) ~= nil)) then return false end
			body, body_count = child.p.text, body_count + 1
		elseif child.p.role ~= "omp.user.tools" and child.p.role ~= "omp.user.badges" then
			return false
		end
	end
	-- Compare the FIRST complete raw user body, never a later matching message.
	-- Clipped dock/later-tool trees do not invalidate an earlier complete card.
	return body_count == 1 and body == prompt
end
reconcile = function(cx: any)
	if observer == nil then return end
	local origins = {}
	for _, track in tracked do origins[track.origin.authority_id] = track.origin end
	for _, origin in origins do
		local ok, value, read_error = pcall(snapshot, cx, origin, true)
		if ok and value ~= nil then
			sync_snapshot(cx, origin, value)
		else
			local problem = if ok then read_error else tostring(value)
			local notify = false
			for _, track in tracked do
				if track.origin.authority_id == origin.authority_id then
					if track.authority_error ~= problem then notify = true end
					track.authority_error, track.native_detail = problem, nil
				end
			end
			if notify then fail(cx, "Host observations unavailable: " .. tostring(problem) .. ". Retained outcomes were not replaced and nothing was launched.") end
		end
	end
	refresh_artwork(cx)
end
tern.on("pane_closed", function(event, cx)
	if observer == nil then return end
	local changed = false
	for _, track in tracked do
		if track.pane == event.pane then track.closed = true; track.native_detail = nil; changed = true end
	end
	if setup ~= nil and setup.pane == event.pane then setup.closed = true; changed = true end
	if changed then save_observer(cx) end
	refresh_artwork(cx)
end)

open_running = function(cx: any)
	local current, active_error = capture(cx)
	if current == nil then
		ensure_observer(cx, function(fresh, err)
			if err ~= nil then fail(fresh, err); return end
			local items = {}
			for _, track in tracked do
				local terminal = track.attempt.phase == "Failed" or track.attempt.phase == "Exited"
				table.insert(items, { group = if terminal then "Failed/exited history" else "SPAWN launches", label = label(track.job) .. " · " .. (if terminal then track.attempt.phase else "Unknown"), detail = "Cached host history only · " .. track.origin.host_key .. " · " .. track.origin.session_key .. " · " .. (track.attempt.diagnostic or "") })
			end
			table.insert(items, { group = "Other Tern sessions", label = "Observation unavailable", detail = active_error })
			fresh:pick({ items = items, placeholder = "Running agents — host unavailable; no liveness or resolution inferred" }):next(function(_item, pick_error, next_cx)
				if next_cx ~= nil and pick_error ~= nil then fail(next_cx, pick_error) end
			end)
		end)
		return
	end
	with_authority(cx, function(fresh, origin, value)
		-- This refresh reads host outcomes and establishes only local UI aliases.
		sync_snapshot(fresh, origin, value)
		local items, owned, groups = {}, {}, {}
		local state = transport(origin)
		for _, track in tracked do
			if not track.closed and track.association_error == nil and track.pane ~= nil and ticket_association(fresh, track.origin, track.job.ticket) == track.pane then owned[track.pane] = true end
		end
		for _, attempt in value.attempts do
			local history = attempt.phase == "Failed" or attempt.phase == "Exited"
			local track = tracked[attempt.id .. "@" .. origin.authority_id]
			local verified = track ~= nil and not track.closed and track.association_error == nil and track.pane ~= nil and track.origin.host == origin.host and track.origin.session == origin.session and pane_member(fresh, origin, track.pane)
			local group = if history then "Failed/exited history" else "SPAWN launches"
			local detail = attempt.mode .. " · " .. attempt.id .. " · host stage " .. track.job.stage .. " · " .. value.host_key .. " · " .. value.session_key .. " · " .. (attempt.diagnostic or "")
			if track.allocation_error ~= nil then detail ..= " · Window allocation: " .. track.allocation_error end
			if track.association_error ~= nil then detail ..= " · Window association: " .. track.association_error end
			if active(attempt) and verified and track.native_detail ~= nil then detail ..= " · " .. track.native_detail end
			groups[group] = true
			table.insert(items, { group = group, label = label(track.job) .. " · Host " .. attempt.phase, detail = detail, attempt = attempt, job = track.job, verified = verified })
		end
		-- The host alone decides which attempts are lost; a pane this window still
		-- verifies is never offered for bulk release.
		if value.host_restart ~= nil then
			local verified_ids, lost = {}, {}
			for _, item in items do if item.attempt ~= nil and item.verified then verified_ids[item.attempt.id] = true end end
			for _, id in value.host_restart.attempts do if not verified_ids[id] then table.insert(lost, id) end end
			if #lost > 0 then
				table.insert(items, 1, { group = "Host restart", label = "Host restarted — " .. tostring(#lost) .. " SPAWN " .. (if #lost == 1 then "agent was" else "agents were") .. " lost", detail = "The execution host's daemon restarted; their panes cannot be verified. Nothing was relaunched.", lost = lost })
			end
		end
		local pane_hosts, tab_sessions = {}, {}
		for _, host in fresh.hosts:list() do for _, pane in host.panes do pane_hosts[pane] = host end end
		for _, tab in fresh.session:tabs() do tab_sessions[tab.id] = tab.session end
		for _, pane in fresh.session:panes() do
			if not owned[pane.pane] and (pane.kind == "terminal" or pane.kind == "agent") then
				local host = pane_hosts[pane.pane]
				local scope = if host ~= nil then tostring(host.name or host.id) .. " · session " .. tostring(tab_sessions[pane.tab]) else "Unknown host membership"
				local phase = if host == nil or host.state ~= "connected" then "Unknown" else "Window-observed pane"
				groups["Other Tern sessions"] = true
				table.insert(items, { group = "Other Tern sessions", label = tostring(pane.title or pane.pane) .. " · " .. phase, detail = "Read-only client observation, not a SPAWN provider outcome · " .. scope .. " · pane " .. tostring(pane.pane), other = true })
			end
		end
		for _, group in ipairs({ "SPAWN launches", "Failed/exited history", "Other Tern sessions" }) do
			if not groups[group] then table.insert(items, { group = group, label = "None observed", other = true }) end
		end
		if value.error ~= nil then table.insert(items, { group = "Host configuration", label = value.error, detail = "Review Config; existing host history remains read-only", other = true }) end
		if state.pending ~= nil then
			local reply = value.replies[state.pending.request_id]
			local busy = queues[origin.authority_id] ~= nil and queues[origin.authority_id].busy
			table.insert(items, { group = "Transport review", label = (if busy then "Awaiting " else "Review interrupted ") .. state.pending.op, detail = if reply ~= nil then tern.json.encode(reply) else "No retained reply is visible. Inspect Config before clearing the local wait; any admitted job remains unresolved.", transport = not busy, other = busy, pending_id = state.pending.request_id, reply = reply })
		end
		fresh:pick({ items = items, placeholder = "Running agents — observations, not saved configuration", icon = "sparkle" }):next(function(item, err, next_cx)
			if next_cx == nil then return end
			if err ~= nil then fail(next_cx, err); return end
			if item == nil or item.other then return end
			if item.lost ~= nil then
				local ids = item.lost
				next_cx:pick({ items = {
					{ label = "Keep reservations", action = "keep" },
					{ label = "Mark all " .. tostring(#ids) .. " lost agents no longer running", detail = "Only after inspection. Releases duplicate blocking for exactly these attempts; does not stop or close a program.", action = "release" },
				}, placeholder = "Host restart · lost SPAWN agents" }):next(function(choice, choice_error, decision_cx)
					if decision_cx == nil then return end
					if choice_error ~= nil then fail(decision_cx, choice_error); return end
					if choice == nil or choice.action ~= "release" then return end
					request(decision_cx, origin, "resolve_lost_attempts", { attempt_ids = ids, attempt_revision = value.attempt_revision }, function(done_cx, reply, release_error)
						if release_error ~= nil then fail(done_cx, release_error); return end
						local released = if type(reply) == "table" and type(reply.result) == "table" then reply.result.released else #ids
						done_cx:toast("info", "SPAWN", "Released " .. tostring(released) .. " lost reservations; no pane was closed")
					end)
				end)
				return
			end
			if item.transport then
				next_cx:pick({ items = {
					{ label = "Keep waiting state", action = "keep" },
					{ label = "I reviewed the outcome; acknowledge without launching", detail = item.detail, action = "acknowledge" },
				}, placeholder = "Review interrupted request — never replay its launch" }):next(function(choice, review_error, review_cx)
					if review_cx == nil then return end
					if review_error ~= nil then fail(review_cx, review_error); return end
					if choice == nil or choice.action ~= "acknowledge" then return end
					if context_error(review_cx, origin, true) ~= nil then fail(review_cx, "Return to the captured host/session before reviewing its result"); return end
					if state.pending == nil or state.pending.request_id ~= item.pending_id then fail(review_cx, "The pending request changed; reopen Running agents"); return end
					if item.reply ~= nil and (item.reply.request_id ~= item.pending_id or item.reply.observer_id ~= observer.id) then fail(review_cx, "The retained reply does not belong to this observer"); return end
					if item.reply ~= nil and not contains(state.acknowledgments, item.reply.request_id) then table.insert(state.acknowledgments, item.reply.request_id) end
					state.pending = nil
					if not save_observer(review_cx) then return end
					request(review_cx, origin, "refresh", {}, function(done_cx, _, refresh_error)
						if refresh_error ~= nil then fail(done_cx, refresh_error) else done_cx:toast("info", "SPAWN", "Reviewed result acknowledged; no launch was replayed. Reopen Running agents to refresh observations.") end
					end)
				end)
				return
			end
			local attempt = item.attempt
			local choices = { { label = "Keep reservation", action = "keep" } }
			if item.verified then table.insert(choices, { label = "Inspect retained pane", action = "inspect" }) end
			if item.verified and item.job.purpose == "setup" then table.insert(choices, { label = "Review this setup result", action = "setup" }) end
			if attempt.unresolved then table.insert(choices, { label = "Mark no longer running", detail = "Only after inspection. Releases duplicate blocking; does not stop or close a program.", action = "resolve" }) end
			next_cx:pick({ items = choices, placeholder = attempt.record_id .. " · " .. attempt.phase }):next(function(choice, choice_error, decision_cx)
				if decision_cx == nil then return end
				if choice_error ~= nil then fail(decision_cx, choice_error); return end
				if choice == nil then return end
				if choice.action == "inspect" or choice.action == "setup" then
					local track = tracked[attempt.id .. "@" .. origin.authority_id]
					local pane, association_error = ticket_association(decision_cx, origin, item.job.ticket)
					if track == nil or track.closed or context_error(decision_cx, origin, true) ~= nil or pane == nil or pane ~= track.pane then fail(decision_cx, association_error or "The captured ticket association changed"); return end
					if choice.action == "inspect" then decision_cx.layout:focus(pane)
					else
						setup = { id = item.job.setup_run_id, job_id = item.job.id, ticket = item.job.ticket, initial_prompt = item.job.initial_prompt, origin = origin, pane = pane }
						if save_observer(decision_cx) then collect_setup(decision_cx) end
					end
				elseif choice.action == "resolve" then
					request(decision_cx, origin, "resolve_attempt", { attempt_id = attempt.id, attempt_revision = value.attempt_revision }, function(done_cx, _, resolve_error)
						if resolve_error ~= nil then fail(done_cx, resolve_error) else done_cx:toast("info", "SPAWN", "Reservation resolved; no pane was closed") end
					end)
				end
			end)
		end)
	end, true)
end

local function review_setup(cx: any, run: any, result: any)
	if type(result) ~= "table" or result.schema ~= 2 or result.setup_run_id ~= run.id or result.confirmed ~= true then fail(cx, "Setup result is not confirmed for this active run; use Config → Paste JSON import for manual recovery"); return end
	local records, err = Config.validate_records(result.agents)
	if records == nil then fail(cx, "The whole setup result was rejected: " .. tostring(err)); return end
	run.reviewing = true
	local items = {}
	for _, record in records do
		table.insert(items, { label = label(record) .. " [" .. record.id .. "]", detail = tern.json.encode(record), action = "record" })
	end
	table.insert(items, { label = "Import all reviewed records", detail = "Conflicting existing IDs require an explicit Config edit; nothing will launch", action = "import" })
	table.insert(items, { label = "Copy complete JSON for Config paste recovery", action = "copy" })
	table.insert(items, { label = "Cancel without saving", action = "cancel" })
	cx:pick({ items = items, placeholder = "Review the complete setup result (" .. tostring(#records) .. " records)" }):next(function(item, pick_error, fresh)
		if fresh == nil then return end
		run.reviewing = false
		if pick_error ~= nil then fail(fresh, pick_error); return end
		if item == nil or item.action == "cancel" then run.cancelled = true; save_observer(fresh); return end
		if item.action == "copy" then fresh:copy(tern.json.encode(result)); fresh:toast("info", "SPAWN", "Complete JSON copied; open Config → Paste JSON import on the original host"); return end
		if item.action == "record" then fresh:toast("info", item.label, item.detail); review_setup(fresh, run, result); return end
		local changed = context_error(fresh, run.origin, true)
		if changed ~= nil then fail(fresh, changed .. "; result remains in the setup conversation for manual Config paste recovery"); return end
		request(fresh, run.origin, "import_records", { setup_run_id = run.id, records = records }, function(import_cx, reply, import_error)
			if import_error ~= nil then fail(import_cx, "Import failed: " .. tostring(import_error) .. ". Use Config → Paste JSON import on the original host; no account was launched."); return end
			if type(reply.result) ~= "table" or not integer(reply.result.imported) then fail(import_cx, "Import acknowledgment is invalid; inspect Config before repeating it"); return end
			run.imported = true; setup = run; save_observer(import_cx)
			import_cx:toast("success", "SPAWN", "Saved " .. tostring(reply.result.imported) .. " reviewed records. Review Config before spawning.")
			open_config(import_cx)
		end)
	end)
end
collect_setup = function(cx: any, manual: boolean?)
	if setup == nil or setup.imported or setup.reviewing or (setup.cancelled and not manual) then return end
	if manual then setup.cancelled = nil end
	if setup.closed then fail(cx, "The original setup pane closed; use its saved result through Config paste recovery"); return end
	local pane, association_error = ticket_association(cx, setup.origin, setup.ticket)
	if pane == nil or (setup.pane ~= nil and setup.pane ~= pane) then fail(cx, association_error or "Setup's exact ticket association changed; use Config paste recovery on the original host"); return end
	if setup.pane == nil then setup.pane = pane; if not save_observer(cx) then return end end
	local track = tracked[setup.job_id .. "@" .. setup.origin.authority_id]
	if track ~= nil and track.job.pane_reused then fail(cx, "The setup wrapper was reused for another command; use the original saved result through Config paste recovery"); return end
	if nonempty(setup.initial_prompt) == nil or not startup_delivered(cx, pane, setup.initial_prompt) then
		fail(cx, "The first complete native OMP user body is not verified for this host-issued setup run; use Config → Paste JSON import")
		return
	end
	local ok, messages = pcall(function() return cx.agents:transcript(pane, { last = 1000 }) end)
	if not ok or type(messages) ~= "table" then fail(cx, "Could not read the verified OMP setup conversation; use Config → Paste JSON import"); return end
	for index = #messages, 1, -1 do
		local message = messages[index]
		if message.role ~= "assistant" or type(message.text) ~= "string" then continue end
		local text = message.text
		local begin_marker, end_marker = "SPAWN_RESULT_BEGIN", "SPAWN_RESULT_END"
		local first = text:find(begin_marker, 1, true)
		local last = if first ~= nil then text:find(end_marker, first + #begin_marker, true) else nil
		if first ~= nil and last ~= nil then
			local decoded, result = pcall(tern.json.decode, text:sub(first + #begin_marker, last - 1))
			if not decoded then fail(cx, "Setup returned invalid JSON; use Config → Paste JSON import after correcting the complete result"); return end
			review_setup(cx, setup, result)
			return
		end
	end
end
local function start_setup(cx: any)
	with_authority(cx, function(fresh, origin, value)
		local choices = {}
		for _, record in value.records do
			if record.backend == "native-agent" and string.lower(record.provider) == "omp" and not record.review_required then table.insert(choices, { label = label(record), record = record }) end
		end
		if #choices == 0 then fail(fresh, "No verified OMP setup command is available. Use Config → Paste JSON import or add a reviewed OMP record; the default Tern agent is not assumed to be OMP."); open_config(fresh); return end
		fresh:pick({ items = choices, placeholder = "Choose the reviewed OMP command for guided setup" }):next(function(item, pick_error, next_cx)
			if next_cx == nil then return end
			if pick_error ~= nil then fail(next_cx, pick_error); return end
			if item == nil then return end
			local changed = context_error(next_cx, origin, true)
			if changed ~= nil then fail(next_cx, changed); return end
			local run_id = observer.id .. ":setup:" .. tostring(observer.next_run)
			observer.next_run += 1
			if not save_observer(next_cx) then return end
			request(next_cx, origin, "start_setup", { record_id = item.record.id, setup_run_id = run_id }, function(admitted_cx, reply, admission_error)
				if admission_error ~= nil then fail(admitted_cx, "Setup admission failed: " .. tostring(admission_error) .. ". Use Config → Paste JSON import or inspect Running agents."); return end
				local job, attempt, result_error = admission_result(reply, origin, item.record.id, "setup", run_id)
				if job == nil then fail(admitted_cx, tostring(result_error) .. "; no ticket was allocated. Use Config paste recovery."); return end
				setup = { id = run_id, job_id = job.id, ticket = job.ticket, initial_prompt = job.initial_prompt, origin = origin }
				if not save_observer(admitted_cx) then return end
				allocate_ticket(admitted_cx, origin, job, attempt, reply.result.replayed, nil, function(done_cx, allocation_error)
					if allocation_error ~= nil then fail(done_cx, allocation_error .. ". Use Config paste recovery on the original host."); return end
					local track = tracked[attempt.id .. "@" .. origin.authority_id]
					if track == nil or not active(track.attempt) then
						fail(done_cx, "Setup helper is not active: " .. (if track then track.attempt.diagnostic or track.attempt.phase else "host history unavailable") .. ". Inspect its retained pane or use Config paste recovery.")
						return
					end
					done_cx:toast("info", "SPAWN", "Host setup command submitted. Complete guided setup; only its verified native OMP conversation and confirmed assistant result can be reviewed for import.")
				end)
			end)
		end)
	end)
end
tern.on("agent_finished", function(event, cx)
	if setup ~= nil and event.pane == setup.pane then collect_setup(cx) end
	reconcile(cx)
end)
tern.on("agent_state", function(_event, cx) reconcile(cx) end)

local function menu(cx: any)
	for _, message in icon_errors do fail(cx, "Provider icon registration failed: " .. message) end
	cx:pick({ items = {
		{ label = "Guided setup", detail = "Verified OMP setup on the captured execution host", action = "setup" },
		{ label = "Config", detail = "Saved records and manual Paste JSON import", action = "config" },
		{ label = "Spawn all", detail = "Enabled records explicitly included in this session", action = "all" },
		{ label = "Spawn specific", detail = "One reviewed saved account", action = "specific" },
		{ label = "Running agents", detail = "SPAWN launches, failed/exited history, other observations", action = "running" },
		{ label = "Review setup result", detail = "Recover the confirmed result from this window's active setup run", action = "result" },
	}, placeholder = "SPAWN", icon = "sparkle" }):next(function(item, err, fresh)
		if fresh == nil then return end
		if err ~= nil then fail(fresh, err); return end
		if item == nil then return end
		if item.action == "setup" then start_setup(fresh)
		elseif item.action == "config" then open_config(fresh)
		elseif item.action == "all" then spawn_all(fresh)
		elseif item.action == "specific" then spawn_specific(fresh)
		elseif item.action == "running" then open_running(fresh)
		elseif item.action == "result" then ensure_observer(fresh, function(ready, problem) if problem then fail(ready, problem) else collect_setup(ready, true) end end) end
	end)
end
for _, command in ipairs({
	{ id = "spawn_config", title = "SPAWN: Config", run = open_config },
	{ id = "spawn_setup", title = "SPAWN: Guided setup", run = start_setup },
	{ id = "spawn_menu", title = "SPAWN", run = menu },
	{ id = "spawn_running", title = "SPAWN: Running agents", run = open_running },
}) do tern.command({ id = command.id, title = command.title, run = command.run, icon = "sparkle", group = "SPAWN" }) end
tern.css("provider-artwork", artwork_css)
tern.css("reset-danger", [[
[data-surface="plugin.spawn.spawner"] [data-row="setup-reset"],
[data-surface="plugin.spawn.spawner"] [data-row="setup-reset"] button { color: var(--error); }
[data-surface="plugin.spawn.spawner"] [data-row="setup-reset"] button { border-color: var(--error); }
]])
tern.chrome.status(function(_pane) return { { icon = "sparkle", text = "SPAWN", tone = "muted", command = "plugin.spawn.spawn_menu" } } end)
local function register_files()
	tern.files.button({ id = "spawn", title = "SPAWN", icon = "sparkle", run = function(_files, cx) menu(cx) end })
end
register_files()
-- Preserve the existing Files/WORK registration order; never override ordinary +.
tern.timer(250, function(cx)
	register_files()
	if cx ~= nil then
		for _, message in icon_errors do fail(cx, "Provider icon registration failed: " .. message) end
		ensure_observer(cx, function(fresh, err)
			if err ~= nil then fail(fresh, err); return end
			for _, track in tracked do
				track.batch, track.native_detail = nil, nil
				track.authority_error = "Host observations have not refreshed since this window reloaded"
			end
			if setup ~= nil then setup.reviewing = false end
			reconcile(fresh)
		end)
	end
end)
local function tick(cx: any)
	tern.timer(1000, tick)
	if cx ~= nil then
		local ok, err = pcall(reconcile, cx)
		if not ok then fail(cx, "Read-only host observation failed; no execution was repeated: " .. tostring(err)) end
	end
end
tern.timer(1000, tick)

-- Module initialization also runs after a VM reload; one executor timer per VM.
require("./dispatch_window").start()
