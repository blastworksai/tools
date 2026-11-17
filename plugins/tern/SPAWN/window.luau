--!strict
-- Window aliases are usable only inside the verified native client incarnation.
-- The host owns configuration, execution, replies and all durable launch outcomes.
local Config = require("./config")
local Codec = require("./wire/codec")
local Launch = require("./launch_state")
local Native = require("./native_cli")
local DispatchWindow = require("./dispatch_window")
-- Setup-only modules must not consume the native window-load budget.
local ManagedRoute: any = nil
local PageNavigation = require("./page_navigation")
local WindowJournal = require("./window_journal")
local status_prompt = require("./status/status_prompt")
local BLOCK = "spawn.spawner"
local PREFIX = "SPAWN_STATE_V2 "
local MAX_QUEUE = 64
local POLL_MS = 250
-- Config › Spawn agents / Setup clicks: the host block publishes a queue node of pending intents,
-- oldest first. HOST assigns one incarnation before this window journals and runs a click.
local INTENT_NODE, INTENT_ROLE, INTENT_JOURNAL = "spawn-launch-intent", "spawn.launch.intent", "spawn.intents.v1"
local INTENT_KINDS = { record = true, setup = true, result = true, readiness = true, discard = true }
-- Upgrade boundary: manual release requests from older versions are dropped, never replayed.
local OBSOLETE_OPS = { resolve_attempt = true, resolve_lost_attempts = true }
local OBSOLETE_NOTICE = "An old Mark-no-longer-running request was cleared; SPAWN now does this automatically"
local MODES = { ["native-agent"] = "Native OMP", ["local-terminal"] = "Terminal", ["ssh-command"] = "SSH terminal", ["setup-default"] = "Setup default" }
local COLORS: { [string]: string } = { claude = "orange", codex = "green", kimi = "teal", muse = "blue", agy = "red", grok = "yellow", omp = "purple" }
local ProviderIcons = require("./provider_icons")
local ICONS: { [string]: string } = ProviderIcons.ICONS
local icon_errors = {}
local ARTWORK: { [string]: string } = {
	kimi = "light-dark(url(assets/icons/kimi-light.svg), url(assets/icons/kimi-dark.svg))",
	muse = "url(assets/icons/muse.svg)",
	agy = "url(assets/icons/agy.svg)",
	grok = "light-dark(url(assets/icons/grok-light.svg), url(assets/icons/grok-dark.svg))",
}
local artwork_css = ""
for program, icon in pairs(ICONS) do
	-- POSIX launch lines start with SPAWN_PROVIDER=<p>, which Tern reports as the command name.
	for _, name in ipairs({ program, "SPAWN_PROVIDER=" .. program }) do
		local ok, err = pcall(function()
			tern.chrome.program_icon(name, icon)
			return nil
		end)
		if not ok then table.insert(icon_errors, name .. ": " .. tostring(err)) end
	end
end

local observer: any = nil
local observer_store: any = nil
local observer_loading = false
local observer_waiters = {}
local queues: any = {}
local authority_panes: any = {}
-- Config panes SPAWN itself opened to carry a launch; closed again once their batch settles.
-- A Config the user opened (SPAWN: Config, or clicked a launch in it) is never in this set.
local opened_for_batch: any = {}
-- with_authority calls still resolving their Config; a queued Config launch waits for them.
local starting = 0
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
local function effective_default(cx: any): (string?, string?)
	local ok, command = pcall(function() return cx.settings:get("agent_command") end)
	if not ok then return nil, "Could not read Tern's effective default agent: " .. tostring(command) end
	if command == nil or command == tern.json.null or (type(command) == "string" and not command:find("%S")) then
		return nil, "Set a default agent in Tern settings, then try setup again."
	end
	if type(command) ~= "string" then return nil, "Tern's effective default agent is not a command string; no setup was started" end
	-- This is an opaque native setting, not an argv or shell ticket to reinterpret.
	return command, nil
end
-- OMP silently moves to a temp folder when started in a home folder, so the helper would no
-- longer sit in the folder SPAWN bound it to. The flag is added only for OMP and only when the
-- chosen folder genuinely is a home folder; elsewhere the opaque command is passed untouched.
local function is_home_folder(cwd: string): boolean
	local path = cwd:gsub("[/\\]+$", "")
	return path == "/root" or path:match("^/home/[^/]+$") ~= nil or path:match("^/Users/[^/]+$") ~= nil
		or path:match("^%a:[/\\]Users[/\\][^/\\]+$") ~= nil
end
local function helper_command(command: string, cwd: string?): string
	if cwd == nil or not is_home_folder(cwd) or command:find("%-%-allow%-home") then return command end
	local first = command:match("^%s*(%S+)")
	local name = if first then first:match("([^/\\]+)$") else nil
	if name == "omp" or name == "omp.exe" then return command .. " --allow-home" end
	return command
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
local function job_association(cx: any, origin: any, job: any, inventory: any?): (number?, string?, any?)
	if job.backend ~= "setup-default" then return ticket_association(cx, origin, job.ticket, inventory) end
	local binding = job.setup
	if binding == nil or binding.window ~= cx:window_key() or not integer(binding.agent_pane) or job.pane_reused or not pane_member(cx, origin, binding.agent_pane) then return nil, "The original native setup pane is unavailable", nil end
	local ok, agents = pcall(function() return inventory or cx.agents:list() end)
	if not ok or type(agents) ~= "table" then return nil, "Native setup inventory is unavailable", nil end
	local found = nil
	for _, agent in agents do
		if agent.pane == binding.agent_pane then
			if found ~= nil or agent.command ~= binding.command then return nil, "Native setup pane association changed", nil end
			found = agent
		end
	end
	if found == nil then return nil, "The original native setup pane closed", nil end
	return found.pane, nil, found
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
local function save_observer(cx: any): boolean
	if observer == nil or observer_store == nil then fail(cx, "The window observer identity is unavailable"); return false end
	observer.tracked = tracked
	observer.setup = setup
	local ok, err = pcall(WindowJournal.save, observer_store, observer)
	if not ok then fail(cx, "Could not persist this window's launch journal: " .. tostring(err)) end
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
		local retirement = WindowJournal.capture()
		Native.inspect(window, { timeout_ms = 5000 }, function(result, err, fresh)
			if fresh == nil then return end
			local problem = err
			local store = nil
			if problem == nil then store, problem = WindowJournal.open(window, result, retirement) end
			if problem == nil then
				local cleared = false
				local loaded, data = pcall(function()
					observer_store = store
					local id, saved = store.id, store.observer
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
							local ops = { refresh = true, import_records = true, discard_setup_result = true, launch_record = true, start_setup = true, setup_claim = true, setup_begin = true, setup_bind = true, setup_uncertain = true }
							if type(state.pending) ~= "table" or not identity(state.pending.request_id, 512) or not (ops[state.pending.op] or OBSOLETE_OPS[state.pending.op]) then error("Invalid pending request journal; inspect Config without replaying it") end
							if OBSOLETE_OPS[state.pending.op] then
								-- Acknowledge it so the host may drop any retained reply; it is never sent again.
								if #state.acknowledgments >= 64 then table.remove(state.acknowledgments, 1) end
								if not seen[state.pending.request_id] then table.insert(state.acknowledgments, state.pending.request_id) end
								state.pending = nil
								cleared = true
							end
						end
					end
					for key, track in saved.tracked do
						if type(key) ~= "string" or type(track) ~= "table" or not valid_attempt(track.attempt) or Launch.validate_execution_projection(track.job) == nil or not valid_origin(track.origin) or type(track.allocation_intent) ~= "boolean" or (track.pane ~= nil and not integer(track.pane)) then error("Invalid saved launch association; preserved for inspection") end
						if key ~= track.attempt.id .. "@" .. track.origin.authority_id or track.job.attempt_id ~= track.attempt.id or track.job.record_id ~= track.attempt.record_id or track.job.session_key ~= track.origin.session_key or track.attempt.scope ~= track.origin.session_key then error("Saved execution association identity mismatch") end
					end
					if saved.setup ~= nil and (type(saved.setup) ~= "table" or not identity(saved.setup.id, 256) or not valid_origin(saved.setup.origin) or not identity(saved.setup.job_id, 96) or (saved.setup.command == nil and not identity(saved.setup.ticket, 512)) or type(saved.setup.initial_prompt) ~= "string" or #saved.setup.initial_prompt > 120000 or (saved.setup.pane ~= nil and not integer(saved.setup.pane))) then error("Invalid saved setup run; use Config paste recovery") end
					if saved.setup ~= nil and saved.setup.command ~= nil then
						local run = saved.setup
						if nonempty(run.command) == nil or nonempty(run.cwd) == nil or type(run.window) ~= "string" or not identity(run.binding, 256) or not identity(run.token, 384) or not identity(run.executor, 256) or not Launch.validate_setup_projection(run.bootstrap) or not integer(run.config_revision) or not integer(run.sequence) or (run.native_pane ~= nil and not integer(run.native_pane)) or (run.effect_intent ~= nil and type(run.effect_intent) ~= "boolean") then error("Invalid saved native setup binding; use Advanced manual recovery") end
					end
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
				if loaded then
					observer = data; tracked = data.tracked; setup = data.setup
					if cleared and save_observer(fresh) then fresh:toast("info", "SPAWN", OBSOLETE_NOTICE) end
				else problem = tostring(data) end
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
	if value.host_cwd~=nil and not identity(value.host_cwd,8192) then return nil,"Execution-host working folder is invalid" end
	if value.setup_refusal~=nil and (type(value.setup_refusal)~="string" or #value.setup_refusal>600) then return nil,"Setup refusal text is invalid" end
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
	-- A 0.4.0 host's lost-attempt list is ignored: nothing is resolved by hand any more.
	value.host_restart = nil
	-- Informational only: how many ordinary attempts the host ended after its daemon restarted.
	-- Count, or an attempts list to count; extra keys are ignored and a malformed notice is dropped.
	local notice = value.host_restart_notice
	value.host_restart_notice = nil
	if type(notice) == "table" and identity(notice.restart_id, 64) then
		local restart_count = notice.count
		if restart_count == nil and type(notice.attempts) == "table" then restart_count = #notice.attempts end
		if integer(restart_count) and restart_count >= 1 then value.host_restart_notice = { restart_id = notice.restart_id, count = restart_count } end
	end
	value.records = records
	return value, nil
end
-- Reads and validates the exact snapshot node of a SPAWN Config pane; no membership or scope check.
local function read_snapshot(cx: any, pane_id: number): (any?, string?)
	local ok, tree = pcall(function()
		local pane = cx.session:pane(pane_id)
		if pane == nil or pane.block ~= BLOCK then error("The captured block is not SPAWN Config") end
		return cx.session:surface(pane_id, { as = "table", root = "main.spawn-state", nodes = 4, depth = 2, max_chars = 128000 })
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
	return validate_snapshot(raw)
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
	local value, err = read_snapshot(cx, origin.pane)
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
local navigation_hooks = { capture = capture, context_error = context_error, member = pane_member }
local page_context_attempts: any = {}
local native_account_attempts: any = {}
local device_attempts: any = {}
local function poll_setup_devices(cx: any,pane: number,origin: any)
	if not PageNavigation.visible(cx,pane,BLOCK,origin,navigation_hooks,true) then return end
	local bytes=DispatchWindow.read_node(cx,pane,BLOCK,"spawn-setup-topology","spawn.setup.topology",32000)
	if bytes==nil then device_attempts[pane]=nil;return end
	local ok,topology=pcall(tern.json.decode,bytes)
	local request=if ok and type(topology)=="table" then topology.request else nil
	if type(request)~="table" or type(request.nonce)~="string" or #request.nonce>256 or topology.window~=cx:window_key() or device_attempts[pane]==request.nonce then return end
	device_attempts[pane]=request.nonce
	local listed,hosts,current=pcall(function()return cx.hosts:list(),cx.hosts:current()end)
	local observation,why
	local SetupDiscovery = require("./setup_discovery")
	if listed then observation,why=SetupDiscovery.devices(hosts,current) else why="Tern device discovery is unavailable. Attach the execution machine in Tern, then find devices again." end
	if context_error(cx,origin,true)~=nil or not pane_member(cx,origin,pane) then return end
	cx.session:event(pane,{ev="action",id="main",act="spawn.setup-devices",value=tern.json.encode({nonce=request.nonce,window=cx:window_key(),devices=if observation then observation.devices else nil,current=if observation then current else nil,error=why})})
end
local function poll_native_accounts(cx: any, pane: number, origin: any)
	if not PageNavigation.visible(cx,pane,BLOCK,origin,navigation_hooks,true) then return end
	local bytes=DispatchWindow.read_node(cx,pane,BLOCK,"spawn-native-accounts","spawn.native.accounts",2048)
	if bytes==nil then native_account_attempts[pane]=nil;return end
	local ok,request=pcall(tern.json.decode,bytes)
	if not ok or type(request)~="table" or type(request.nonce)~="string" or #request.nonce>256 or request.window~=cx:window_key() or native_account_attempts[pane]==request.nonce then return end
	native_account_attempts[pane]=request.nonce
	local choices,seen={},{}
	local function add(command: any,label: string)
		if type(command)~="string" or #command==0 or #command>8192 or command:find("%c") or seen[command] or #choices>=32 then return end
		seen[command]=true;table.insert(choices,{command=command,label=label})
	end
	local command,why=effective_default(cx)
	if command then add(command,"Tern default agent") end
	local listed,agents=pcall(function()return cx.agents:list()end)
	if listed and type(agents)=="table" then
		for _,agent in ipairs(agents) do
			if pane_member(cx,origin,agent.pane) then add(agent.command,"Native agent pane "..tostring(agent.pane)) end
		end
	end
	if context_error(cx,origin,true)~=nil or not PageNavigation.visible(cx,pane,BLOCK,origin,navigation_hooks,true) then return end
	local payload=tern.json.encode({nonce=request.nonce,window=cx:window_key(),choices=choices,error=if #choices==0 then why or "No configured default or native agent route was observed" else nil})
	if #payload>100000 then payload=tern.json.encode({nonce=request.nonce,window=cx:window_key(),choices={},error="Native account discovery exceeds its bound; choose an existing account explicitly"}) end
	local sent,problem=pcall(function()cx.session:event(pane,{ev="action",id="main",act="spawn.native-accounts",value=payload})end)
	if not sent then fail(cx,"Could not report native account discovery: "..tostring(problem)) end
end
local function poll_page_context(cx: any, pane: number, origin: any)
	if not PageNavigation.visible(cx,pane,BLOCK,origin,navigation_hooks,true) then return end
	local bytes=DispatchWindow.read_node(cx,pane,BLOCK,"spawn-page-context","spawn.page.context",2048)
	if bytes==nil then page_context_attempts[pane]=nil;return end
	local decoded,value=pcall(tern.json.decode,bytes)
	local request=if decoded then PageNavigation.request(value) else nil
	if not request then
		if page_context_attempts[pane]~=bytes then page_context_attempts[pane]=bytes;fail(cx,"SPAWN page context request is invalid; no settings were opened") end
		return
	end
	if request.entry.native_window~=cx:window_key() then return end
	if page_context_attempts[pane]==request.nonce then return end
	page_context_attempts[pane]=request.nonce
	local handed,why=PageNavigation.handoff(cx,pane,request,block_args,navigation_hooks)
	if not handed then
		fail(cx,tostring(why)..". Refresh the SPAWN page to retry; nothing was provisioned.")
		if context_error(cx,origin,true)==nil and PageNavigation.visible(cx,pane,BLOCK,origin,navigation_hooks,true) then
			local reported,report_error=pcall(function() cx.session:event(pane,{ev="action",id="main",act="spawn.page-context",value=tern.json.encode({nonce=request.nonce,error=tostring(why):sub(1,1024)})}) end)
			if not reported then fail(cx,"Could not report the refused owner context: "..tostring(report_error)) end
		end
	end
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
	return nil
end
-- A Config carrying in-flight work for this window: queued/unacknowledged requests or a running batch.
local function in_use(pane: number, authority_id: string?): boolean
	if authority_id ~= nil then
		local queue = queues[authority_id]
		if queue ~= nil and (queue.busy or #queue.items > 0) then return true end
		local state = if observer ~= nil then observer.transports[authority_id] else nil
		if state ~= nil and state.pending ~= nil then return true end
	end
	for _, batch in batches do
		if (batch.origin.pane == pane or (authority_id ~= nil and batch.origin.authority_id == authority_id)) and not batch.completed and not batch.stopped then return true end
	end
	return false
end
local function forget_pane(origin: any, pane: number)
	opened_for_batch[pane] = nil
	local key = tostring(origin.host) .. "/" .. tostring(origin.session)
	if authority_panes[key] == pane then authority_panes[key] = nil end
end
local function valid_intent(intent: any): boolean
	if type(intent) ~= "table" or not identity(intent.intent_id, 256) or not INTENT_KINDS[intent.kind] or not integer(intent.config_revision) then return false end
	if intent.kind == "record" then return identity(intent.record_id, 96) end
	if intent.kind=="discard" then return identity(intent.record_id,96) and type(intent.native_window)=="string" and #intent.native_window<=256 and not intent.native_window:find("[%z\1-\31\127]") end
	if intent.kind == "readiness" and (type(intent.native_window) ~= "string" or #intent.native_window > 256 or intent.native_window:find("[%z\1-\31\127]")) then return false end
	return intent.record_id == nil
end
local function intent_journal(): any
	if observer_store == nil then error("The native window intent journal is unavailable") end
	return WindowJournal.cache(observer_store, INTENT_JOURNAL)
end
-- A missing/unreadable node is unknown, never an empty durable HOST queue.
local function intent_queue(cx: any, pane: number): any
	local read_ok, bytes = pcall(DispatchWindow.read_node, cx, pane, BLOCK, INTENT_NODE, INTENT_ROLE, 16384)
	if not read_ok or bytes == nil then return nil end
	local decoded, node = pcall(tern.json.decode, bytes)
	if not decoded or type(node) ~= "table" or node.schema ~= 1 or type(node.intents) ~= "table" or #node.intents > 64 then return nil end
	for key in pairs(node) do if key ~= "schema" and key ~= "queue_id" and key ~= "intents" then return nil end end
	local count, ids = 0, {}
	for index, intent in pairs(node.intents) do
		count += 1
		if not integer(index) or index < 1 or index > #node.intents or not valid_intent(intent) or ids[intent.intent_id] then return nil end
		ids[intent.intent_id] = true
	end
	if count ~= #node.intents then return nil end
	if node.queue_id ~= nil and not identity(node.queue_id, 256) then return nil end
	return node
end
local function intent_source(entry: any, queue: any, origin: any, pane: number): boolean
	return type(entry) == "table" and queue.queue_id ~= nil and entry.queue_id == queue.queue_id
		and entry.host_key == origin.host_key and entry.session == origin.session and entry.pane == pane
		and WindowJournal.same_recipient(entry.recipient, observer_store.recipient)
end
local function intent_seen(journal: any, id: string, queue: any, origin: any, pane: number): boolean
	for _, entry in pairs(journal) do
		-- Unqualified legacy IDs remain exclusion evidence; never guess their issuer.
		if entry == id or (intent_source(entry, queue, origin, pane) and entry.intent_id == id) then return true end
	end
	return false
end
local function reclaimable_intent(entry: any): boolean
	if type(entry) ~= "table" or not identity(entry.intent_id, 256) or type(entry.recipient) ~= "table" then return false end
	for key in pairs(entry) do
		if key ~= "intent_id" and key ~= "queue_id" and key ~= "host_key" and key ~= "session" and key ~= "pane" and key ~= "recipient" then return false end
	end
	for key in pairs(entry.recipient) do
		if key ~= "observer_id" and key ~= "window_key" and key ~= "conn" and key ~= "since" then return false end
	end
	return true
end
local function reclaim_intents(journal: any, queue: any, origin: any, pane: number)
	local pending, changed = {}, false
	for _, intent in ipairs(queue.intents) do pending[intent.intent_id] = true end
	for index = #journal, 1, -1 do
		local entry = journal[index]
		if reclaimable_intent(entry) and intent_source(entry, queue, origin, pane) and not pending[entry.intent_id] then
			table.remove(journal, index)
			changed = true
		end
	end
	if changed then WindowJournal.save_cache(observer_store, INTENT_JOURNAL, journal) end
end
local function unrun_intent(cx: any, pane: number): boolean
	local queue, origin = intent_queue(cx, pane), capture(cx)
	if queue == nil or origin == nil then return true end
	local journal = intent_journal()
	for _, intent in ipairs(queue.intents) do
		if not intent_seen(journal, intent.intent_id, queue, origin, pane) then return true end
	end
	return false
end
-- Closes a Config SPAWN opened to carry a launch once nothing uses it. A focused one stays, and so
-- does one holding a click this window has not run yet.
local function dismiss_opened(cx: any, origin: any): boolean
	local pane = origin.pane
	if not opened_for_batch[pane] or in_use(pane, origin.authority_id) or unrun_intent(cx, pane) then return false end
	local info = cx.session:pane(pane)
	if info == nil or info.focused then return false end
	local closed, err = pcall(function() cx.layout:close(pane) end)
	if not closed then fail(cx, "Spawning finished, but SPAWN Config could not be closed: " .. tostring(err)); return false end
	forget_pane(origin, pane)
	return true
end
-- Older versions parked Config after a batch and lost track of it on reload. Close every parked
-- SPAWN Config of this host whose snapshot shows no pending request for this window. Only SPAWN
-- parks these blocks; authority, attempts and history live in the host store, not the block.
local function close_parked(cx: any, origin: any)
	if observer == nil then return end
	local here = {}
	for _, host in cx.hosts:list() do
		if host.id == origin.host then for _, pane in host.panes do here[pane] = true end end
	end
	for _, pane in cx.session:panes() do
		if not pane.parked or pane.block ~= BLOCK or not here[pane.pane] then continue end
		local value = read_snapshot(cx, pane.pane)
		if value == nil or in_use(pane.pane, value.authority_id) then continue end
		if pcall(function() cx.layout:close(pane.pane) end) then forget_pane(origin, pane.pane) end
	end
end
-- target: run against this exact Config pane (a launch clicked in it) instead of finding one.
local function with_authority(cx: any, callback: any, readonly: boolean?, target: number?)
	local origin, capture_error = capture(cx)
	if origin == nil then fail(cx, capture_error); return end
	starting += 1
	local live = true
	local function settle()
		if live then live = false; starting -= 1 end
	end
	ensure_observer(cx, function(fresh, identity_error)
		if identity_error ~= nil then settle(); fail(fresh, identity_error); return end
		local changed = context_error(fresh, origin, true)
		if changed ~= nil then settle(); fail(fresh, changed); return end
		local opened, pane = pcall(function()
			if target ~= nil then return target end
			local found = find_authority(fresh, origin)
			if found ~= nil then return found end
			close_parked(fresh, origin)
			local created = fresh:new_block(BLOCK, block_args(fresh, origin), "beside", { focus = false })
			if created ~= nil then opened_for_batch[created] = true end
			return created
		end)
		if not opened or pane == nil then settle(); fail(fresh, "Could not open host Config: " .. tostring(pane)); return end
		origin.pane = pane
		authority_panes[tostring(origin.host) .. "/" .. tostring(origin.session)] = pane
		local polls = 0
		local function read_ready(next_cx: any)
			if next_cx == nil then settle(); return end
			local changed_now = context_error(next_cx, origin, true)
			if changed_now ~= nil then settle(); fail(next_cx, changed_now); return end
			local value, err = snapshot(next_cx, origin, readonly)
			if value ~= nil then
				origin.authority_id, origin.session_key = value.authority_id, value.session_key
				origin.config_revision = value.config_revision
				settle()
				callback(next_cx, origin, value)
				return
			end
			polls += 1
			if polls >= 240 then settle(); fail(next_cx, tostring(err) .. ". Review the visible Config block; no command was launched."); return end
			tern.timer(POLL_MS, read_ready)
		end
		read_ready(fresh)
	end)
end
local function open_config(cx: any, page: string?)
	local origin, err = capture(cx)
	if origin == nil then fail(cx, err); return end
	local ok, pane = pcall(function()
		local existing = find_authority(cx, origin)
		if existing ~= nil then
			cx.layout:focus(existing)
			if page then cx.session:event(existing,{ev="action",id="main",act="page",value=page}) end
			return existing
		end
		close_parked(cx, origin)
		local args=block_args(cx,origin)
		if page then local context=tern.json.decode(args[1]);context.page=page;args[1]=tern.json.encode(context) end
		return cx:new_block(BLOCK, args, "beside", { focus = true, dir = "right" })
	end)
	if not ok or pane == nil then fail(cx, "Could not open Config: " .. tostring(pane))
	else
		-- The user asked for this Config; it is theirs now and stays open.
		opened_for_batch[pane] = nil
		authority_panes[tostring(origin.host) .. "/" .. tostring(origin.session)] = pane
	end
end
local function open_managed_setup(cx: any) open_config(cx,"managed") end

local function transport(origin: any): any
	local value = observer.transports[origin.authority_id]
	if value == nil then value = { sequence = 0, acknowledgments = {} }; observer.transports[origin.authority_id] = value end
	return value
end
local function request(cx: any, origin: any, op: string, data: any, callback: any, preflight: any?)
	local queue = queues[origin.authority_id]
	if queue == nil then queue = { items = {}, busy = false }; queues[origin.authority_id] = queue end
	if #queue.items >= MAX_QUEUE then callback(cx, nil, "The authority request queue is full"); return end
	table.insert(queue.items, { origin = origin, expected_config_revision = origin.config_revision, op = op, data = data, callback = callback, preflight = preflight })
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
		if changed ~= nil then finish(cx, nil, changed); return nil end
	end
	if value == nil then finish(cx, nil, err); return nil end
	local state = transport(origin)
	if type(state) ~= "table" or not integer(state.sequence) or type(state.acknowledgments) ~= "table" then finish(cx, nil, "The saved observer transport is invalid"); return nil end
	if state.pending ~= nil then
		local pending, prior_acknowledgments = state.pending, state.acknowledgments
		local refused = value.replies[pending.request_id]
		if not Launch.refused_pending(pending, refused, observer.id) then
			finish(cx, nil, "An earlier " .. tostring(pending.op) .. " request has an unreviewed outcome. Open SPAWN: Running agents → Transport review → acknowledge it, then try again."); return nil
		end
		-- A definitive refusal executed nothing; settle it exactly as the poll does.
		state.acknowledgments = { pending.request_id }
		state.pending = nil
		if not save_observer(cx) then
			state.pending, state.acknowledgments = pending, prior_acknowledgments
			finish(cx, nil, "An earlier " .. tostring(pending.op) .. " request has an unreviewed outcome. Open SPAWN: Running agents → Transport review → acknowledge it, then try again."); return nil
		end
		cx:toast("info", "Cleared an earlier refused SPAWN request", "The host refused " .. tostring(pending.op) .. " (" .. tostring(refused.error) .. "); nothing ran. Continuing with your new request.")
	end
	if item.preflight ~= nil then
		local why = item.preflight(cx, value)
		if why ~= nil then finish(cx, nil, why); return nil end
	end
	state.sequence = math.max(state.sequence, value.request_sequences[observer.id] or 0) + 1
	local id = observer.id .. ":" .. tostring(state.sequence)
	local acknowledged = {}
	for index, request_id in ipairs(state.acknowledgments) do acknowledged[index] = request_id end
	local payload = { version = 2, request_id = id, authority_id = origin.authority_id, observer_id = observer.id, request_sequence = state.sequence, acknowledged_requests = acknowledged, expected_config_revision = item.expected_config_revision, op = item.op, data = item.data }
	state.pending = { request_id = id, op = item.op }
	if not save_observer(cx) then finish(cx, nil, "Request was not sent because its journal could not be saved"); return nil end
	local sent, send_error = pcall(function()
		local encoded = tern.json.encode(payload)
		if #encoded > 120000 then error("Request exceeds the authority byte limit") end
		cx.session:event(origin.pane, { ev = "action", id = "main", act = "spawn.request", value = encoded })
	end)
	if not sent then finish(cx, nil, "Request delivery is uncertain: " .. tostring(send_error) .. "; inspect Config before another launch"); return nil end
	local polls = 0
	local function poll(fresh: any)
		if fresh == nil or finished then return end
		local read_ok, read_failure = pcall(function()
		local latest, read_error = snapshot(fresh, origin, true)
		if latest ~= nil then
			local reply = latest.replies[id]
			if reply ~= nil then
				if reply.request_id ~= id or reply.observer_id ~= observer.id or reply.request_sequence ~= payload.request_sequence then finish(fresh, nil, "Authority reply identity mismatch"); return nil end
				-- A rejected stale action stays rejected. Retain the host's revision
				-- only for the next deliberate action, including saved setup recovery.
				origin.config_revision = reply.config_revision
				state.acknowledgments = { id }
				state.pending = nil
				if not save_observer(fresh) then finish(fresh, nil, "Reply consumption could not be persisted; no launch was authorized"); return nil end
				finish(fresh, reply, if reply.ok then nil else reply.error or "Authority rejected the request")
				return nil
			end
		end
		polls += 1
		if polls >= 240 then finish(fresh, nil, "Authority acknowledgment timed out: " .. tostring(read_error or "no matching durable reply") .. ". No automatic resend; inspect Config for the retained result."); return nil end
		tern.timer(POLL_MS, poll)
		return nil
		end)
		if not read_ok then finish(fresh, nil, "Authority reply handling failed; request outcome remains uncertain and was not replayed: " .. tostring(read_failure)) end
	end
	tern.timer(POLL_MS, poll)
	return nil
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
	if not opened_for_batch[origin.pane] or context_error(cx, origin, true) ~= nil then return end
	local value = snapshot(cx, origin)
	if value == nil then return end
	for _, attempt in value.attempts do
		if batch.record_ids[attempt.record_id] and (attempt.phase == "Starting" or (attempt.phase == "Unknown" and attempt.unresolved)) then return end
	end
	if dismiss_opened(cx, origin) then batch.dismissed = true end
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
		if job.purpose ~= "setup" and track.origin.host == origin.host and track.origin.session == origin.session and track.origin.pane ~= origin.pane then track.origin.pane = origin.pane; changed = true end
		track.job, track.attempt, track.authority_error = job, attempt, nil
		if progressed and track.batch ~= nil then changed_batches[track.batch] = true end
		local pane: number? = nil
		local association_error: string? = "This window's ticket inventory is unavailable"
		local agent = nil
		if inventory_ok then pane, association_error, agent = job_association(cx, track.origin, job, inventory) end
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
		end
	end
	-- An explicit host history cleanup is authoritative; it is not a launch.
	for key, track in tracked do
		if track.origin.authority_id == origin.authority_id and not present[key] then tracked[key] = nil; changed = true end
	end
	refresh_artwork(cx)
	if changed then save_observer(cx) end
	local restart = value.host_restart_notice
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
			cx:toast("info", "Host restarted: " .. tostring(restart.count) .. " SPAWN " .. (if restart.count == 1 then "agent" else "agents") .. " ended (cleared automatically)")
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
			if changed ~= nil then finish(fresh, changed .. "; already accepted host work stays in its original session"); return nil end
			local value, read_error = snapshot(fresh, track.origin, true)
			if value ~= nil then
				sync_snapshot(fresh, track.origin, value)
				local current = tracked[track.attempt.id .. "@" .. track.origin.authority_id]
				if current == nil then finish(fresh, "The admitted execution history is unavailable; no allocation was repeated"); return nil end
				if value.config_revision ~= current.job.config_revision then finish(fresh, "Saved configuration changed; later batch records were not admitted. Already accepted host work stays in its original session."); return nil end
				if SUBMISSION_BOUNDARY[current.job.stage] then finish(fresh, nil); return nil end
			else
				track.authority_error = read_error
			end
			polls += 1
			if polls >= 240 then finish(fresh, "Host submission was not confirmed within the bounded wait. Later batch records were not admitted; inspect Running agents. The ticket will not be allocated again."); return nil end
			tern.timer(POLL_MS, poll)
			return nil
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
local function launch_one(cx: any, origin: any, record: any)
	next_local_id += 1
	local batch = { id = tostring(next_local_id), origin = origin, config_revision = origin.config_revision, attempts = {}, failed = 0, skipped = 0, record_ids = { [record.id] = true } }
	batches[batch.id] = batch
	local changed = context_error(cx, origin, true)
	if changed then batch.stopped = true; fail(cx, changed); batch_summary(cx, batch); return end
	request(cx, origin, "launch_record", { record_id = record.id }, function(admitted_cx, reply, err)
		if err ~= nil then
			if err == "skip" or err == "disabled" then batch.skipped += 1 else batch.failed += 1 end
			fail(admitted_cx, label(record) .. ": " .. tostring(err) .. ". Inspect Current agents for unresolved work.")
			batch.completed = true; batch_summary(admitted_cx, batch); return
		end
		local job, attempt, admission_error = admission_result(reply, origin, record.id, "launch", nil)
		if job == nil then batch.failed += 1; batch.stopped = true; fail(admitted_cx, admission_error); batch_summary(admitted_cx, batch); return end
		allocate_ticket(admitted_cx, origin, job, attempt, reply.result.replayed, batch, function(done_cx: any, problem: string?)
			if problem then batch.stopped = true; fail(done_cx, problem) else batch.completed = true end
			batch_summary(done_cx, batch)
		end)
	end)
end
-- Launch only the exact saved-agent row clicked in its real SPAWN pane.
local function start_saved_agent(cx: any, target: number, record_id: string)
	with_authority(cx, function(fresh, origin, value)
		for _,record in value.records do
			if record.id~=record_id then continue end
			if record.enabled and not record.review_required and (record.backend~="native-agent" or nonempty(record.prompt)) then launch_one(fresh,origin,record);return end
			break
		end
		fresh:toast("info","SPAWN","This saved agent is disabled, needs review or no longer exists; review Agent settings")
	end,nil,target)
end

local function startup_delivered(cx: any, pane: number, prompt: string): boolean
	-- Managed route diagnostics still compare the first complete native user body.
	-- Guided setup never reads assistant messages or infers a result from a transcript.
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
	for _, bound in origins do
		local origin = bound
		local closed = cx.session:pane(origin.pane) == nil
		if closed then
			-- SPAWN closes the Config it opened once a batch settles; observe through another
			-- open Config of the same authority, or wait quietly until one is open again.
			for _, pane in cx.session:panes() do
				if pane.block ~= BLOCK then continue end
				local candidate = table.clone(origin)
				candidate.pane = pane.pane
				local found_ok, found = pcall(snapshot, cx, candidate, true)
				if found_ok and found ~= nil then origin, closed = candidate, false; break end
			end
		end
		local ok, value, read_error = pcall(snapshot, cx, origin, true)
		if ok and value ~= nil then
			sync_snapshot(cx, origin, value)
		else
			local problem = if closed then "SPAWN Config is closed; host observations resume when it is open" elseif ok then read_error else tostring(value)
			local notify = false
			for _, track in tracked do
				if track.origin.authority_id == origin.authority_id then
					if track.authority_error ~= problem then notify = true end
					track.authority_error, track.native_detail = problem, nil
				end
			end
			if notify and not closed then fail(cx, "Host observations unavailable: " .. tostring(problem) .. ". Retained outcomes were not replaced and nothing was launched.") end
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
	if setup ~= nil and (setup.pane == event.pane or setup.origin.pane == event.pane) then setup.closed = true; changed = true end
	if changed then save_observer(cx) end
	refresh_artwork(cx)
end)

type RunningItem =
	{ kind: "attempt", group: string, label: string, icon: string?, detail: string, attempt: Launch.Attempt, job: { id: string }, verified: boolean }
	| { kind: "info", group: string, label: string, icon: string?, detail: string? }
	| { kind: "advanced", group: string, label: string, detail: string? }
	| { kind: "transport", group: string, label: string, detail: string, busy: boolean, pending_id: string, reply: { request_id: string, observer_id: string }? }

open_running = function(cx: any, advanced: boolean?)
	local current, active_error = capture(cx)
	if current == nil then
		ensure_observer(cx, function(fresh, err)
			if err ~= nil then fail(fresh, err); return end
			local items = {}
			for _, track in tracked do
				local terminal = track.attempt.phase == "Failed" or track.attempt.phase == "Exited"
				if terminal and not advanced then continue end
				table.insert(items, { group = if terminal then "Failed/exited history" else "Current agents", label = label(track.job) .. " · " .. (if terminal then track.attempt.phase else "Unknown"), icon = ICONS[string.lower(track.job.provider)] or "sparkle", detail = "Host unavailable; last-known observation only" .. (if advanced then " · "..track.origin.host_key.." · "..track.origin.session_key else "") })
			end
			table.insert(items, { group = "Other Tern sessions", label = "Observation unavailable", detail = active_error })
			if not advanced then table.insert(items,{kind="advanced",label="Advanced",detail="Retained history; nothing is cleared"}) end
			fresh:pick({ items = items, placeholder = "Current agents — host unavailable" }):next(function(item, pick_error, next_cx)
				if next_cx ~= nil and pick_error ~= nil then fail(next_cx, pick_error)
				elseif next_cx ~= nil and item and item.kind=="advanced" then open_running(next_cx,true) end
			end)
		end)
		return
	end
	with_authority(cx, function(fresh, origin, value)
		-- This refresh reads host outcomes and establishes only local UI aliases.
		sync_snapshot(fresh, origin, value)
		local items: { RunningItem } = {}
		local owned, groups = {}, {}
		local state = transport(origin)
		for _, track in tracked do
			if not track.closed and track.association_error == nil and track.pane ~= nil and job_association(fresh, track.origin, track.job) == track.pane then owned[track.pane] = true end
		end
		for _, attempt in value.attempts do
			local history = attempt.phase == "Failed" or attempt.phase == "Exited"
			if history and not advanced then continue end
			local track = tracked[attempt.id .. "@" .. origin.authority_id]
			if track==nil then
				local display
				for _,job in value.jobs do if job.attempt_id==attempt.id then display=job;break end end
				if not display then for _,record in value.records do if record.id==attempt.record_id then display=record;break end end end
				table.insert(items,{kind="info",group="Current agents",label=(if display then label(display) else "Saved agent").." · "..attempt.phase,icon=if display then ICONS[string.lower(display.provider)] or "sparkle" else "sparkle",detail="No local window association; inspect the original conversation."..(if advanced then " · "..attempt.record_id else "")})
				groups["Current agents"]=true
				continue
			end
			local verified = track ~= nil and not track.closed and track.association_error == nil and track.pane ~= nil and track.origin.host == origin.host and track.origin.session == origin.session and pane_member(fresh, origin, track.pane)
			local group = if history then "Failed/exited history" else "Current agents"
			local detail = if advanced then attempt.mode.." · "..attempt.id.." · host stage "..track.job.stage.." · "..value.host_key.." · "..value.session_key else "This Tern session"
			if attempt.diagnostic then detail..=" · "..attempt.diagnostic end
			if track.allocation_error ~= nil then detail ..= " · Window allocation: " .. track.allocation_error end
			if track.association_error ~= nil then detail ..= " · Window association: " .. track.association_error end
			if active(attempt) and verified and track.native_detail ~= nil then detail ..= " · " .. track.native_detail end
			groups[group] = true
			table.insert(items, { kind = "attempt", group = group, label = label(track.job) .. " · " .. attempt.phase, icon = ICONS[string.lower(track.job.provider)] or "sparkle", detail = detail, attempt = attempt, job = track.job, verified = verified })
		end
		-- Informational: the host already ended the attempts its restart lost.
		if value.host_restart_notice ~= nil then
			local count = value.host_restart_notice.count
			local notice: RunningItem = { kind = "info", group = "Host restart", label = "Host restarted: " .. tostring(count) .. " SPAWN " .. (if count == 1 then "agent" else "agents") .. " ended (cleared automatically)" }
			table.insert(items, 1, notice)
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
				table.insert(items, { kind = "info", group = "Other Tern sessions", label = tostring(pane.title or pane.pane) .. " · " .. phase, detail = "Read-only client observation, not a SPAWN provider outcome · " .. scope .. " · pane " .. tostring(pane.pane) })
			end
		end
		for _, group in ipairs(if advanced then { "Current agents", "Failed/exited history", "Other Tern sessions" } else { "Current agents", "Other Tern sessions" }) do
			if not groups[group] then table.insert(items, { kind = "info", group = group, label = "None observed" }) end
		end
		if value.error ~= nil then table.insert(items, { kind = "info", group = "Host configuration", label = value.error, detail = "Review Config; existing host history remains read-only" }) end
		if advanced and state.pending ~= nil then
			local reply = value.replies[state.pending.request_id]
			local busy = queues[origin.authority_id] ~= nil and queues[origin.authority_id].busy
			table.insert(items, { kind = "transport", group = "Transport review", label = (if busy then "Awaiting " else "Review interrupted ") .. state.pending.op, detail = if reply ~= nil then tern.json.encode(reply) else "No retained reply is visible. Inspect Config before clearing the local wait; any admitted job remains unresolved.", busy = busy, pending_id = state.pending.request_id, reply = reply })
		end
		if not advanced then table.insert(items,{kind="advanced",group="Options",label="Advanced",detail=if state.pending then "An unfinished request needs attention; inspect its retained outcome without repeating it." else "History and request recovery"}) end
		fresh:pick({ items = items, placeholder = if advanced then "Advanced — history and recovery" else "Current agents", icon = "sparkle" }):next(function(item: RunningItem?, err: string?, next_cx)
			if next_cx == nil then return end
			if err ~= nil then fail(next_cx, err); return end
			if item and item.kind=="advanced" then open_running(next_cx,true);return end
			if item == nil or item.kind == "info" then dismiss_opened(next_cx, origin); return end
			if item.kind == "transport" then
				if item.busy then dismiss_opened(next_cx, origin); return end
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
			local choices = { { label = "Back", action = "keep" } }
			if item.verified then table.insert(choices, { label = "Inspect retained pane", action = "inspect" }) end
			if item.verified and setup ~= nil and setup.job_id == item.job.id and setup.origin.authority_id == origin.authority_id then table.insert(choices, { label = "Review this setup result", action = "setup" }) end
			next_cx:pick({ items = choices, placeholder = attempt.record_id .. " · " .. attempt.phase }):next(function(choice, choice_error, decision_cx)
				if decision_cx == nil then return end
				if choice_error ~= nil then fail(decision_cx, choice_error); return end
				if choice == nil then return end
				if choice.action == "inspect" or choice.action == "setup" then
					local track = tracked[attempt.id .. "@" .. origin.authority_id]
					local pane, association_error = job_association(decision_cx, origin, item.job)
					if track == nil or track.closed or context_error(decision_cx, origin, true) ~= nil or pane == nil or pane ~= track.pane then fail(decision_cx, association_error or "The captured ticket association changed"); return end
					if choice.action == "inspect" then decision_cx.layout:focus(pane)
					else
						if setup == nil or setup.job_id ~= item.job.id or setup.origin.authority_id ~= origin.authority_id then fail(decision_cx, "This window has no original setup binding; use Advanced manual recovery"); return end
						collect_setup(decision_cx)
					end
				end
			end)
		end)
	end, true)
end

-- Setup's native effect and review retain one original Config and one opaque default.
-- Neither a ticket lookup nor a replacement Config can recover automatic provenance.
local function setup_source(cx: any, run: any, supplied: any?): (any?, any?, string?)
	if setup ~= run or run.closed or run.imported or run.command == nil then return nil, nil, "The original setup source is unavailable; use Advanced manual recovery on its original host/session" end
	if cx:window_key() ~= run.window then return nil, nil, "Setup belongs to another window" end
	local changed = context_error(cx, run.origin, true)
	if changed ~= nil then return nil, nil, changed end
	local command, default_error = effective_default(cx)
	if command == nil or helper_command(command, run.cwd) ~= run.command then return nil, nil, default_error or "The effective default agent changed; review cannot be reused" end
	local value, err = supplied, nil
	if value == nil then value, err = snapshot(cx, run.origin) end
	if value == nil then return nil, nil, err end
	if value.config_revision ~= run.config_revision then return nil, nil, "Configuration changed; start a new review" end
	local state = transport(run.origin)
	if state.pending ~= nil or state.sequence ~= run.sequence or value.request_sequences[observer.id] ~= run.sequence then return nil, nil, "The setup observer sequence changed; start a new review" end
	local job, attempt = nil, nil
	for _, candidate in value.jobs do
		if candidate.id == run.job_id then job = candidate end
	end
	for _, candidate in value.attempts do
		if candidate.id == run.job_id then attempt = candidate end
	end
	if job == nil or attempt == nil or job.backend ~= "setup-default" or job.purpose ~= "setup" or job.setup_run_id ~= run.id
		or job.observer_id ~= observer.id or job.token ~= run.token or job.initial_prompt ~= run.initial_prompt
		or attempt.observer_id ~= run.executor or attempt.scope ~= run.origin.session_key or attempt.record_id ~= "setup-default"
		or job.config_revision ~= run.config_revision or job.pane_reused or job.session_key ~= run.origin.session_key
		or type(job.setup) ~= "table" or job.setup.command ~= run.command or job.setup.cwd ~= run.cwd
		or job.setup.window ~= run.window or job.setup.config_pane ~= run.origin.pane or job.setup.binding ~= run.binding then
		return nil, nil, "The exact admitted setup binding changed; no source was retargeted"
	end
	for _, key in { "host_config_pane", "result_path", "host_key", "authority_id", "request_sequence", "native_session", "config_dir" } do
		if job.setup[key] ~= run.bootstrap[key] then return nil, nil, "The immutable host setup context changed" end
	end
	if run.pane ~= nil then
		if job.setup.agent_pane ~= run.pane or run.native_pane == nil or job.native_pane ~= run.native_pane or job.native_window ~= run.window or not pane_member(cx, run.origin, run.pane) then return nil, nil, "The original setup pane closed or its binding changed" end
		if attempt.pane ~= job.native_pane or not active(attempt) then return nil, nil, "The retained attempt no longer owns an active native setup pane" end
		local ok, agents = pcall(function() return cx.agents:list() end)
		if not ok or type(agents) ~= "table" then return nil, nil, "The native setup agent inventory is unavailable" end
		local count = 0
		for _, agent in agents do
			if agent.pane == run.pane then
				count += 1
				-- The desktop may format a remote POSIX cwd as a Windows path.
				-- The host checks the exact native command/cwd before binding and import.
				if agent.command ~= run.command or agent.state == "exited" or nonempty(agent.delivery_error) ~= nil then return nil, nil, "The setup pane was reused, exited or failed native prompt delivery" end
			end
		end
		if count ~= 1 then return nil, nil, "The setup pane association is not unique" end
		for _, other in value.jobs do
			if other.id ~= job.id and other.native_window == job.native_window and other.native_pane == job.native_pane then return nil, nil, "Another attempt owns the setup pane" end
		end
	end
	return job, attempt, nil
end
local PENDING_RESULT_UNAVAILABLE = "The complete pending result is unavailable; no truncated result can be reviewed"
local function pending_setup(cx: any, run: any, value: any?, reviewed: any?): (any?, string?)
	local job, attempt, err = setup_source(cx, run, value)
	if job == nil then return nil, err end
	if run.pane == nil or job.stage ~= "submitted" or job.setup_consumed ~= false or not integer(job.pending_bytes) or job.pending_bytes == 0 or type(job.pending_digest) ~= "string" then
		-- The host recorded why it refused the helper's submission (for example a record field it does not know).
		local latest = if value ~= nil then value else snapshot(cx, run.origin)
		if run.pane ~= nil and job.stage == "submitted" and type(latest) == "table" and type(latest.setup_refusal) == "string" then return nil, "SPAWN refused the helper's result: " .. latest.setup_refusal end
		return nil, "No complete explicit submission is available for this bound run"
	end
	-- Surface framing needs headroom beyond the raw result's independent byte cap.
	local bytes = DispatchWindow.read_node(cx, run.origin.pane, BLOCK, "spawn-setup-result", "spawn.setup.result", 128000)
	if bytes == nil then return nil, PENDING_RESULT_UNAVAILABLE end
	if #bytes > 120000 then return nil, "The submitted result exceeds the 120000-byte limit" end
	if #bytes ~= job.pending_bytes then return nil, "Pending result byte count changed; select the original submitted result again" end
	if reviewed ~= nil then
		if bytes ~= reviewed.bytes or job.pending_digest ~= reviewed.digest or run.sequence ~= reviewed.sequence or attempt.sequence ~= reviewed.attempt_sequence then return nil, "The reviewed bytes or setup authority changed; review again" end
		return reviewed, nil
	end
	if Codec.sha256(bytes) ~= job.pending_digest then return nil, "The pending bytes do not match the retained submission" end
	local result, decode_error = Config.decode_setup_json(bytes)
	if result == nil then return nil, decode_error end
	local Review = require("./setup_review")
	local review, review_error = Review.prepare(result, run.id)
	if review == nil then return nil, review_error end
	return { bytes = bytes, digest = job.pending_digest, sequence = run.sequence, attempt_sequence = attempt.sequence, review = review }, nil
end
local discard_setup_result
local route_hooks: any
-- One approval: the Guided setup helper already showed the exact roster and its
-- checks. After a bound submission SPAWN saves, prepares and verifies by itself.
-- The exact run/result binding, the digest fences and the once-only effects are the
-- same ones the former review picker relied on; only the extra click is gone.
local function commit_setup(cx: any, run: any, pending: any, action: string, plan: any)
	ManagedRoute = ManagedRoute or require("./managed_route_window")
	local captured
	if action == "prepare" then
		local latest, why = snapshot(cx, run.origin)
		local exact, source_error
		if latest then exact, source_error = pending_setup(cx, run, latest, pending) else source_error = why end
		if not exact then run.reviewing = false; fail(cx, source_error or "The exact approved setup changed; save and preparation were not accepted."); return end
		-- Preparation is automatic, but never at the price of losing the approved roster:
		-- if it cannot be captured, the exact result is still saved and the cause is named.
		local skip_preparation: string? = nil
		if type(latest.setup) ~= "table" then skip_preparation = "The preparation state is unavailable" end
		local added = false
		for _, record in ipairs(pending.review.records) do
			local found = false
			for _, saved in ipairs(latest.records) do if saved.id == record.id then found = true; break end end
			if not found then added = true end
		end
		if skip_preparation == nil then
			local begin_required = latest.setup.state == "not_started" or latest.setup.state == "dismissed"
			local capture_error
			-- Only the plan's records: a native account the helper did not disclose a paid
			-- model check for is saved but never checked here.
			local selected_records = {}
			local chosen: { [string]: boolean } = {}
			for _, id in ipairs(plan.prepare_ids) do chosen[id] = true end
			for _, record in ipairs(pending.review.records) do
				if record.enabled and chosen[record.id] then table.insert(selected_records, record) end
			end
			captured, capture_error = ManagedRoute.capture_reviewed(cx, run.origin.pane, run.bootstrap.host_config_pane, selected_records, latest.config_revision + (if added then 1 else 0), begin_required, route_hooks)
			if not captured then skip_preparation = tostring(capture_error) end
		end
		if skip_preparation ~= nil then
			plan = { action = "save_only", enabled = plan.enabled, native = plan.native, withheld = plan.withheld, prepare_ids = {}, reason = "Preparation could not start: " .. skip_preparation }
			cx:toast("error", "SPAWN", "Preparation did not start (" .. skip_preparation .. "). Saving your approved agents anyway; use Prepare agents for ORCH+ afterwards.")
		end
	end
	local import_data = { setup_run_id = run.id, attempt_id = run.job_id, pending_digest = pending.digest, confirmed = true, preparation = if captured then ManagedRoute.reviewed_payload(captured) else nil }
	request(cx, run.origin, "import_records", import_data, function(import_cx, reply, import_error)
		if import_error ~= nil then
			ManagedRoute.cancel_reviewed(captured)
			run.reviewing = false
			fail(import_cx, "SPAWN setup save was not confirmed: " .. tostring(import_error) .. ". Inspect the saved roster in the right-hand SPAWN pane first. Resolve conflicting saved IDs in Agent settings, or explicitly Discard this setup result in Advanced to approve a fresh run. Do not claim success, resubmit or repeat blindly.")
			return
		end
		if type(reply.result) ~= "table" or not integer(reply.result.imported) then ManagedRoute.cancel_reviewed(captured); run.reviewing = false; fail(import_cx, "Import acknowledgment is invalid; inspect Config before repeating it"); return end
		run.imported = true
		run.reviewing = false
		save_observer(import_cx)
		import_cx:toast(if captured then "info" else "success", "SPAWN", if captured then "Agents saved. Required preparation is starting; progress shows in SPAWN." else "Agents saved — " .. tostring(reply.result.imported) .. " approved agents. " .. tostring(plan.reason or "") .. ". Prepare them for ORCH+ in SPAWN to finish setup.")
		local navigated, navigation_error = pcall(function() import_cx.session:event(run.origin.pane, { ev = "action", id = "main", act = "page", value = "managed" }) end)
		if not navigated then fail(import_cx, "Agents are saved. Open SPAWN Setup to prepare them for ORCH+: " .. tostring(navigation_error)) end
		if captured then
			if reply.config_revision ~= captured.manifest.revision then ManagedRoute.cancel_reviewed(captured); fail(import_cx, "Agents were saved, but their revision differs from the approved preparation. No model check was started."); return end
			local started, why = ManagedRoute.start_reviewed(import_cx, captured, { setup_run_id = run.id, attempt_id = run.job_id, pending_digest = pending.digest, import_request_id = reply.request_id }, route_hooks)
			if not started then fail(import_cx, why) end
			return
		end
	end, function(check_cx, value)
		-- Runs immediately before the durable request, even if the queue waited.
		local current, why = pending_setup(check_cx, run, value, pending)
		if current == nil then ManagedRoute.cancel_reviewed(captured); run.reviewing = false; return why end
		return nil
	end)
end
local function review_setup(cx: any, run: any, pending: any)
	local Review = require("./setup_review")
	run.reviewing = true
	local plan = Review.automatic_plan(pending.review.records, pending.review.paid_checks)
	if plan.action == "prepare" then
		local scope = ""
		if #plan.native > 0 then scope = " The helper's approval disclosed one harmless model message each for: " .. table.concat(plan.native, ", ") .. ". May cost credits; not a sandbox." end
		if #plan.withheld > 0 then scope ..= " Not checked (no paid check was disclosed): " .. table.concat(plan.withheld, ", ") .. ". Use Prepare agents for ORCH+ to review its cost and run it." end
		cx:toast("info", "SPAWN", "Saving " .. tostring(plan.enabled) .. " approved agents, then preparing and verifying them. No further click is needed." .. scope)
	else
		cx:toast("info", "SPAWN", "Saving your approved agents without preparation: " .. tostring(plan.reason) .. "." .. (if #plan.withheld > 0 then " Not checked: " .. table.concat(plan.withheld, ", ") .. "; Prepare agents for ORCH+ shows its cost first." else ""))
	end
	commit_setup(cx, run, pending, plan.action, plan)
end
collect_setup = function(cx: any)
	local run = setup
	if run == nil or run.imported or run.reviewing then return end
	local value, read_error = snapshot(cx, run.origin)
	if value == nil then fail(cx, read_error); return end
	local state = transport(run.origin)
	if state.pending ~= nil or value.request_sequences[observer.id] ~= state.sequence then fail(cx, "An authority request is unsettled; acknowledge its outcome before reviewing"); return end
	-- A new explicit review may follow an acknowledged refresh, but the picker
	-- retains this exact watermark and refuses any subsequent change.
	local previous = run.sequence
	run.sequence = state.sequence
	local job, _, why = setup_source(cx, run, value)
	if job == nil then run.sequence = previous; fail(cx, why); return end
	if previous ~= run.sequence and not save_observer(cx) then return end
	local ok, err = pcall(function()
		cx.session:event(run.origin.pane, { ev = "action", id = "main", act = "spawn.setup-result-select", value = tern.json.encode({ attempt_id = run.job_id }) })
	end)
	if not ok then fail(cx, "Could not select the submitted result: " .. tostring(err)); return end
	run.reviewing = true
	local polls = 0
	local function read_result(fresh: any)
		if fresh == nil then return end
		local pending, problem = pending_setup(fresh, run)
		if pending == nil then
			polls += 1
			-- Selection verifies native host context asynchronously. Observe it,
			-- never resend selection, submission, import or a native effect.
			if problem == PENDING_RESULT_UNAVAILABLE and polls < 40 then tern.timer(POLL_MS, read_result); return end
			run.reviewing = false
			fail(fresh, problem)
			return
		end
		review_setup(fresh, run, pending)
	end
	tern.timer(POLL_MS, read_result)
end
local function launch_setup(cx: any, target: number?)
	if setup~=nil and not setup.imported then fail(cx,"Finish, review or explicitly discard the original Guided setup first; no second helper was started.");return end
	-- Resolve before opening Config; a blank default never becomes an account picker.
	local command, command_error = effective_default(cx)
	if command == nil then fail(cx, command_error); return end
	with_authority(cx, function(fresh, origin, value)
		local current, why = effective_default(fresh)
		if current ~= command then fail(fresh, why or "The effective default agent changed; choose setup again"); return end
		local cwd = nonempty(value.host_cwd)
		if cwd == nil then fail(fresh, "The captured Config host directory is unavailable; no setup was started"); return end
		-- The helper's own start command; the unchanged default stays the freshness reference.
		local helper = helper_command(command, cwd)
		local window = fresh:window_key()
		local run_id = observer.id .. ":setup:" .. tostring(observer.next_run)
		observer.next_run += 1
		opened_for_batch[origin.pane] = nil
		if not save_observer(fresh) then return end
		request(fresh, origin, "start_setup", { setup_run_id = run_id, command = helper, cwd = cwd, window = window, config_pane = origin.pane }, function(admitted_cx, reply, admission_error)
			if admission_error ~= nil then fail(admitted_cx, "Setup admission failed: " .. tostring(admission_error)); return end
			local job, attempt, result_error = admission_result(reply, origin, "setup-default", "setup", run_id)
			if job == nil or type(job.setup) ~= "table" then fail(admitted_cx, result_error or "Setup bootstrap is missing; nothing started"); return end
			local run = { id = run_id, job_id = job.id, token = job.token, executor = attempt.observer_id, bootstrap = table.clone(job.setup), initial_prompt = job.initial_prompt, origin = table.clone(origin),
				command = helper, cwd = cwd, window = window, binding = job.setup.binding, config_revision = value.config_revision, sequence = reply.request_sequence }
			setup = run
			if not save_observer(admitted_cx) then return end
			if reply.result.replayed then fail(admitted_cx, "Retained setup admission is observation-only; native start was not repeated"); return end
			local function phase(phase_cx: any, op: string, expected: string, callback: any)
				request(phase_cx, run.origin, op, { attempt_id = run.job_id, setup_run_id = run.id }, function(next_cx, response, err)
					if err ~= nil then fail(next_cx, "Setup stopped: " .. tostring(err) .. "; nothing was retried"); return end
					run.sequence = response.request_sequence
					if not save_observer(next_cx) then return end
					callback(next_cx, response)
				end, function(check_cx, latest)
					local current_job, _, err = setup_source(check_cx, run, latest)
					if current_job == nil then return err end
					if current_job.stage ~= expected then return "Setup phase changed; native effect was not repeated" end
					return nil
				end)
			end
			phase(admitted_cx, "setup_claim", "admitted", function(claimed_cx)
				phase(claimed_cx, "setup_begin", "claimed", function(effect_cx)
					local current_job, _, err = setup_source(effect_cx, run)
					if current_job == nil or current_job.stage ~= "submission_intent" then fail(effect_cx, err or "Native setup permission changed"); return end
					run.effect_intent = true
					if not save_observer(effect_cx) then return end
					local started, created = pcall(function()
						return effect_cx.agents:start({ command = helper, cwd = cwd, prompt = run.initial_prompt, how = current_job.placement })
					end)
					if not started or not integer(created) then
						request(effect_cx, run.origin, "setup_uncertain", { attempt_id = run.job_id, setup_run_id = run.id }, function(done_cx, _, uncertain_error)
							fail(done_cx, "Native setup start is uncertain and will not be repeated: " .. tostring(created) .. (if uncertain_error then "; " .. uncertain_error else ""))
						end)
						return
					end
					run.pane = created
					local arranged, arrangement_error = pcall(function()
						if not effect_cx.layout:move(created, origin.pane, "left", { focus = true }) then error("Native layout refused the setup split") end
					end)
					if not arranged then fail(effect_cx, "Setup started once, but its left-hand split could not be arranged: "..tostring(arrangement_error)) end
					if not save_observer(effect_cx) then return end
					request(effect_cx, run.origin, "setup_bind", { attempt_id = run.job_id, setup_run_id = run.id, pane = created }, function(bound_cx, bound_reply, bind_error)
						if bind_error ~= nil then fail(bound_cx, "Native setup started but binding failed; it will not be repeated: " .. tostring(bind_error)); return end
						local bound = if type(bound_reply.result) == "table" then bound_reply.result.job else nil
						if Launch.validate_execution_projection(bound) == nil or bound.backend ~= "setup-default" or bound.id ~= run.job_id or bound.token ~= run.token or bound.setup.agent_pane ~= created or not integer(bound.native_pane) then fail(bound_cx, "Native setup binding acknowledgment is invalid; no start was repeated"); return end
						run.native_pane = bound.native_pane
						run.sequence = bound_reply.request_sequence
						if not save_observer(bound_cx) then return end
						bound_cx:toast("info", "SPAWN", "Answer the setup questions. SPAWN will show the exact proposed settings for your approval, then open the required preparation step.")
					end)
				end)
			end)
		end, function(check_cx, latest): string?
			local selected, err = effective_default(check_cx)
			if selected ~= command then return err or "The effective default agent changed before admission" end
			if check_cx:window_key() ~= window or latest.config_revision ~= value.config_revision then return "Setup origin changed before admission" end
			if latest.host_cwd ~= cwd then return "The execution-host working folder changed before setup; nothing started" end
			return nil
		end)
	end, nil, target)
end
local setup_navigating=false
local function start_setup(cx: any,target: number?)
	if target==nil then open_config(cx,"setup");return end
	if setup_navigating then fail(cx,"Execution-machine selection is already being applied; no second helper was requested.");return end
	local origin,problem=capture(cx)
	if not origin or not pane_member(cx,origin,target) then fail(cx,problem or "The original SPAWN setup pane is unavailable.");return end
	local bytes=DispatchWindow.read_node(cx,target,BLOCK,"spawn-setup-topology","spawn.setup.topology",32000)
	local ok,topology=pcall(tern.json.decode,bytes or "")
	if not ok or type(topology)~="table" or topology.window~=cx:window_key() then fail(cx,"Choose the device setup in SPAWN before starting Guided setup.");return end
	local SetupDiscovery = require("./setup_discovery")
	-- Single device (the default) needs no discovery step: it is this execution machine.
	local single_current=topology.mode=="single" and topology.observation==nil
	local selected,why
	if single_current then
		local ok_hosts,own_hosts,own_current=pcall(function()return cx.hosts:list(),cx.hosts:current()end)
		local found,found_error
		if ok_hosts then found,found_error=SetupDiscovery.devices(own_hosts,own_current) end
		if found then selected,why=SetupDiscovery.primary(found,found.current,"single") else why=found_error or "Tern device discovery is unavailable. Attach the execution machine in Tern, then start Guided setup again." end
		if selected and selected.id~=origin.host then selected=nil;why="Single device setup runs on this execution machine. Choose Multi device to use another." end
	else
		selected,why=SetupDiscovery.primary(topology.observation,topology.selected,topology.mode)
	end
	if not selected then fail(cx,why);return end
	local listed,hosts,current=pcall(function()return cx.hosts:list(),cx.hosts:current()end)
	local discovered,discovery_error
	if listed then discovered,discovery_error=SetupDiscovery.devices(hosts,current) end
	local actual,selection_error=SetupDiscovery.primary(discovered,selected.id,topology.mode)
	if not actual or actual.name~=selected.name or actual.address~=selected.address or actual.kind~=selected.kind then fail(cx,selection_error or discovery_error or "The chosen device changed; find execution machines again.");return end
	if selected.id==origin.host then launch_setup(cx,target);return end
	setup_navigating=true
	-- Let the original exact-recipient intent ACK finish before switching host.
	tern.timer(1,function(fresh)
		if fresh==nil then setup_navigating=false;return end
		if context_error(fresh,origin,true)~=nil then setup_navigating=false;fail(fresh,"The setup session changed before device selection was applied. Nothing started.");return end
		local switched,switch_error=pcall(function()fresh.hosts:switch(selected.id)end)
		if not switched then setup_navigating=false;fail(fresh,"Could not show "..selected.name..": "..tostring(switch_error));return end
		local polls=0
		local function selected_ready(nextcx: any)
			if nextcx==nil then setup_navigating=false;return end
			local here=capture(nextcx)
			if here and here.host==selected.id then
				setup_navigating=false
				if here.host_info.name~=selected.name or here.host_info.address~=selected.address or here.host_info.kind~=selected.kind then fail(nextcx,"Execution-machine identity changed. Nothing started.");return end
				launch_setup(nextcx,nil);return
			end
			polls+=1
			if polls>=40 then setup_navigating=false;fail(nextcx,"Tern did not show a session on "..selected.name..". Open its session in Tern, then choose Guided setup there. No helper or transport terminal was started.");return end
			tern.timer(POLL_MS,selected_ready)
		end
		selected_ready(fresh)
	end)
end
tern.on("agent_finished", function(_event, cx) reconcile(cx) end)
tern.on("agent_state", function(_event, cx) reconcile(cx) end)

local function menu(cx: any)
	if observer == nil then
		ensure_observer(cx, function(fresh, why) if why then fail(fresh, why) else menu(fresh) end end)
		return
	end
	for _, message in icon_errors do fail(cx, "Provider icon registration failed: " .. message) end
	open_config(cx, "start")
end
-- "This window has no setup run" for a Review setup result click in Config.
local SETUP_ELSEWHERE = "This window has no original setup binding. Use Advanced manual recovery on the original host/session; pasted run IDs do not prove automatic provenance."
-- A batch from this window, or a launch still resolving its Config, is in flight.
local function launch_busy(): boolean
	if starting > 0 or setup_navigating then return true end
	for _, batch in batches do
		if not batch.completed and not batch.stopped then return true end
	end
	return false
end
route_hooks = {
	capture = capture, member = pane_member, startup = startup_delivered, ensure = ensure_observer,
	recipient = function()
		if observer_store == nil then return nil end
		local recipient = observer_store.recipient
		return { namespace = observer_store.identity.namespace, window_key = recipient.window_key, conn = recipient.conn, since = recipient.since }
	end,
}
tern.route.link(function(link, cx)
	ManagedRoute = ManagedRoute or require("./managed_route_window")
	return ManagedRoute.consent(cx, link, route_hooks) or DispatchWindow.consent_migration(cx, link, route_hooks)
end)
discard_setup_result=function(cx: any,pane: number,attempt_id: string)
	with_authority(cx,function(ready,origin,value)
		local selected=nil
		for _,job in value.jobs or {} do if job.attempt_id==attempt_id then selected=job;break end end
		if selected==nil or selected.setup==nil or selected.setup_consumed~=false or not integer(selected.pending_bytes) or selected.pending_bytes<1 or type(selected.pending_digest)~="string" then fail(ready,"No matching unconsumed setup submission remains; nothing was discarded");return end
		local data={attempt_id=attempt_id,setup_run_id=selected.setup_run_id,pending_digest=selected.pending_digest,confirmed=true}
		ready:pick({items={
			{action="discard",label="Discard this setup result",detail="Run "..selected.setup_run_id.." · "..tostring(selected.pending_bytes).." bytes · SHA-256 "..selected.pending_digest.."\nSaved records, other submissions, helper conversations and history remain unchanged."},
			{action="cancel",label="Keep this setup result"},
		},placeholder="Discard only this exact pending submission?"}):next(function(item,problem,fresh)
			if fresh==nil then return end
			if problem then fail(fresh,problem);return end
			if not item or item.action~="discard" then return end
			request(fresh,origin,"discard_setup_result",data,function(done,reply,err)
				if err then fail(done,"Setup result was not discarded: "..tostring(err));return end
				if not reply.result or reply.result.discarded~=true then fail(done,"Discard acknowledgment is invalid; refresh before choosing another action");return end
				if setup and setup.job_id==attempt_id and setup.origin.authority_id==origin.authority_id then setup=nil;save_observer(done) end
				done:toast("success","SPAWN","Setup result discarded without importing. Saved records and history are unchanged; Guided setup can start a fresh run.")
			end)
		end)
	end,true,pane)
end
local function run_intent(cx: any, intent: any, pane: number)
	if intent.kind == "record" then start_saved_agent(cx, pane, intent.record_id)
	elseif intent.kind == "setup" then start_setup(cx, pane)
	elseif intent.kind=="discard" then discard_setup_result(cx,pane,intent.record_id)
	elseif intent.kind == "readiness" then
		local opened,why=PageNavigation.readiness(cx,pane,navigation_hooks)
		if not opened then fail(cx,tostring(why)..". Required SPAWN setup remains saved.") end
	else
		ensure_observer(cx, function(ready, problem)
			if problem then fail(ready, problem)
			elseif setup == nil then ready:toast("info", "SPAWN", SETUP_ELSEWHERE)
			elseif setup.origin.pane ~= pane then fail(ready, "Review must use the original setup Config; no result was retargeted")
			else collect_setup(ready) end
		end)
	end
end
-- HOST's durable pending recipient excludes other windows; this incarnation's
-- journal excludes re-entry after an interrupted callback. Neither substitutes
-- for the other, and a recipient is never reassigned after a possible effect.
local function poll_intents(cx: any)
	local origin = capture(cx)
	if origin == nil then return end
	if observer == nil then
		ensure_observer(cx, function(fresh, why) if why then fail(fresh, why) end end)
		return
	end
	local live={}
	for _,pane in cx.session:panes() do live[pane.pane]=true end
	for pane in pairs(page_context_attempts) do if not live[pane] then page_context_attempts[pane]=nil end end
	for pane in pairs(native_account_attempts) do if not live[pane] then native_account_attempts[pane]=nil end end
	for _, pane in cx.session:panes() do
		-- Nobody can click a parked or hidden Config; its node is never acted on.
		if pane.block ~= BLOCK or pane.parked or not pane_member(cx, origin, pane.pane) then continue end
		poll_page_context(cx,pane.pane,origin)
		poll_native_accounts(cx,pane.pane,origin)
		poll_setup_devices(cx,pane.pane,origin)
		DispatchWindow.observe_migration(cx,pane.pane,route_hooks)
		local queue = intent_queue(cx, pane.pane)
		if queue == nil then continue end
		local journal = intent_journal()
		reclaim_intents(journal, queue, origin, pane.pane)
		local value: any = nil
		for _, intent in ipairs(queue.intents) do
			if not valid_intent(intent) then continue end
			if (intent.kind == "readiness" or intent.kind=="discard") and intent.native_window ~= cx:window_key() then continue end
			local recipient = observer_store.recipient
			local envelope = table.clone(recipient)
			envelope.intent_id = intent.intent_id
			envelope.queue_id = queue.queue_id
			if intent.recipient == nil then
				cx.session:event(pane.pane, { ev = "action", id = "main", act = "spawn.launch-intent-claim", value = tern.json.encode(envelope) })
				break
			end
			if not WindowJournal.same_recipient(intent.recipient, recipient) then break end
			if not intent_seen(journal, intent.intent_id, queue, origin, pane.pane) then
				-- The user clicked in this Config; it is theirs and stays open, even while this
				-- click waits for a running batch.
				opened_for_batch[pane.pane] = nil
				if value == nil then
					local candidate = table.clone(origin)
					candidate.pane = pane.pane
					value = snapshot(cx, candidate, true)
					if value == nil then break end
				end
				local stale = value.config_revision ~= intent.config_revision
				-- Click order: a later launch never overtakes one that has to wait.
				if not stale and launch_busy() then break end
				table.insert(journal, if queue.queue_id == nil then intent.intent_id else {
					intent_id = intent.intent_id, queue_id = queue.queue_id, host_key = origin.host_key,
					session = origin.session, pane = pane.pane, recipient = table.clone(recipient),
				})
				-- Persist before effect; HOST already excluded every other incarnation.
				WindowJournal.save_cache(observer_store, INTENT_JOURNAL, journal)
				if stale then
					cx:toast("info", "SPAWN", "Config changed; press again")
				else
					local ran, run_error = pcall(function()
						run_intent(cx, intent, pane.pane)
						return nil
					end)
					if not ran then fail(cx, "The Config launch could not start: " .. tostring(run_error)) end
				end
			end
			pcall(function() cx.session:event(pane.pane, { ev = "action", id = "main", act = "spawn.launch-intent-ack", value = tern.json.encode(envelope) }) end)
		end
		local observed = intent_queue(cx, pane.pane)
		if observed ~= nil then
			reclaim_intents(journal, observed, origin, pane.pane)
		end
		ManagedRoute = ManagedRoute or require("./managed_route_window")
		ManagedRoute.reconcile(cx,pane.pane,false,route_hooks)
		local focused=cx.session:focused()
		-- Only interrupt the live setup conversation or its initiating SPAWN pane.
		-- A review click in another Config cannot awaken a background auto-review.
		if setup and focused~=nil and not setup.imported and not setup.reviewing and setup.origin.pane==pane.pane and (focused==setup.origin.pane or focused==setup.pane) then
			local latest=read_snapshot(cx,pane.pane)
			local setup_transport=transport(setup.origin)
			if latest and setup_transport.pending==nil and latest.request_sequences[observer.id]==setup_transport.sequence then
				for _,job in ipairs(latest.jobs or {}) do
					if job.id==setup.job_id and job.stage=="submitted" and job.setup_consumed==false and job.pending_digest~=setup.offered_digest then
						setup.offered_digest=job.pending_digest
						collect_setup(cx)
						break
					end
				end
			end
		end
	end
end
for _, command in ipairs({
	{ id = "spawn_config", title = "SPAWN: Config", run = open_config },
	{ id = "spawn_managed_setup", title = "SPAWN: Prepare agents for ORCH+", run = open_managed_setup },
	{ id = "spawn_setup", title = "SPAWN: Guided setup", run = function(cx) start_setup(cx) end },
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
-- The status segment above is the launcher; there is no Files-pane button.
tern.timer(250, function(cx)
	if cx ~= nil then
		status_prompt.ensure(cx, "spawn")
		for _, message in icon_errors do fail(cx, "Provider icon registration failed: " .. message) end
		ensure_observer(cx, function(fresh, err)
			if err ~= nil then fail(fresh, err); return end
			for _, track in tracked do
				track.batch, track.native_detail = nil, nil
				track.authority_error = "Host observations have not refreshed since this window reloaded"
			end
			if setup ~= nil then setup.reviewing = false end
			reconcile(fresh)
			-- One-time cleanup of Config blocks older versions parked and forgot.
			local origin = capture(fresh)
			if origin ~= nil then
				local cleaned, clean_error = pcall(function()
					close_parked(fresh, origin)
					return nil
				end)
				if not cleaned then fail(fresh, "Could not close leftover SPAWN Config blocks: " .. tostring(clean_error)) end
			end
		end)
	end
end)
local function tick(cx: any)
	tern.timer(1000, tick)
	if cx ~= nil then
		local ok, err = pcall(reconcile, cx)
		if not ok then fail(cx, "Read-only host observation failed; no execution was repeated: " .. tostring(err)) end
		local polled, poll_error = pcall(function()
			poll_intents(cx)
			return nil
		end)
		if not polled then fail(cx, "Config launch check failed; nothing was launched: " .. tostring(poll_error)) end
	end
end
tern.timer(1000, tick)

-- Module initialization also runs after a VM reload; one executor timer per VM.
DispatchWindow.start()

require("./updater/window").register({ name = "SPAWN", dir = "SPAWN", title_prefix = "SPAWN: " })
