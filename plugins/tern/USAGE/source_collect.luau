--!strict
-- Source-only normalization/publication bridge. Python owns acquisition/cadence;
-- this heartbeat only transfers completed results through the existing reducer.
local companion = require("./companion")
local runner = require("./metadata_runner")
local enrichment = require("./enrichment")
local snapshots = require("./snapshot")
local collector = {}
local POLL_MS = 15000
-- register_client leases last 90 s; renew well inside that.
local RENEW_MS = 60000
local generation = 0
local running, ready, busy, pending_flush = false, false, false, false
local timer: any = nil
local on_update: any = nil
local next_renew = 0
-- nil while the last transfer succeeded (or none has finished yet).
local failure: string? = nil
local tick: any

local function live(token: number): boolean
	return running and generation == token
end
local function request(token: number, operation: string, payload: any, done: any)
	local called = false
	companion.request(operation, payload, function(value, err)
		if called or not live(token) then return end
		called = true
		done(value, err)
	end)
end

-- Source-qualified reading id: publisher namespaces cannot collide.
local function source_id(publisher: string, provider: string, item: string): string
	return "source:" .. tostring(#publisher) .. ":" .. publisher .. ":" .. provider .. ":" .. item
end

-- Retain only this definition's measurement. Failed attempts never move its
-- original observation/reset clocks. A changed identity drops old quota. An old
-- identity is never carried onto a reading whose response proved none: the
-- retained values stay bound to the SPAWN definition, not to that login.
local function retain(reading: any, old: any, reason: string?): any
	if type(old) ~= "table" or old.id ~= reading.id or old.provider ~= reading.provider
		or (reading.canonical_id ~= nil and old.canonical_id ~= reading.canonical_id) then return reading end
	if reading.canonical_id == nil and reading.plan == nil then reading.plan = old.plan end
	local positions = {}
	for index, window in reading.windows do
		positions[tostring(#window.key) .. ":" .. window.key .. window.pool] = index
	end
	for _, window in old.windows or {} do
		if window.used == nil then continue end
		local pair = tostring(#window.key) .. ":" .. window.key .. window.pool
		local position = positions[pair]
		local incoming = if position ~= nil then reading.windows[position] else nil
		if incoming == nil or incoming.used == nil then
			local saved = table.clone(window)
			saved.last_known_reason = if incoming ~= nil then incoming.unavailable_reason else reason or "not_reported"
			if position ~= nil then reading.windows[position] = saved else table.insert(reading.windows, saved) end
		end
	end
	return reading
end

-- Exposed as a pure source seam for behavioral tests, not a UI operation.
-- One malformed item only affects its own row; the snapshot decoder bounds the total.
function collector.project(result: any): any?
	if type(result) ~= "table" or type(result.source) ~= "table" or type(result.roster) ~= "table"
		or type(result.items) ~= "table" then return nil end
	local source = result.source
	if type(source.device_id) ~= "string" or type(source.generation) ~= "string" then return nil end
	local namespace = source.device_id .. ":" .. source.generation
	local publisher = source.device_id .. ":host"
	local roster = result.roster
	local definitions = {}
	for _, scope in roster.scopes or {} do
		for _, account in scope.accounts or {} do
			definitions[scope.id .. "\0" .. account.id] = account
		end
	end
	local readings = tern.json.array()
	for _, item in result.items do
		if type(item) ~= "table" or type(item.scope_id) ~= "string" or type(item.id) ~= "string"
			or type(item.revision) ~= "string" then continue end
		local account = definitions[item.scope_id .. "\0" .. item.id]
		-- A result whose definition is missing from this roster (or names another
		-- provider) cannot be attributed; skip it instead of failing every account.
		if account == nil or account.provider ~= item.provider then continue end
		local kind = if item.provider == "openai" then "codex" elseif item.provider == "antigravity" then "agy" else item.provider
		local reading: any = { provider = item.provider, provider_label = account.provider_label,
			source_label = if snapshots.text(item.label, 1024) then item.label else account.account_label,
			agent_id = kind, windows = tern.json.array(),
			id = source_id(namespace, item.provider, item.scope_id .. ":" .. item.id .. ":" .. item.revision),
			usage_source = "headless" }
		local response = runner.project(item.response)
		if response == nil or (response.usage ~= nil and response.usage.provider ~= item.provider) then
			response = { version = 1, error = "unparsed" }
		end
		local reason = response.error
		reading = enrichment.apply(reading, response)
		if #reading.windows == 0 then
			reason = reason or (if response.usage ~= nil then response.usage.unavailable_reason else nil)
			reason = if snapshots.REASONS[reason] then reason else "source_usage_unavailable"
			reading.windows = { { key = "observation", pool = "default", observed_at_ms = 0, unavailable_reason = reason } }
		elseif response.usage ~= nil then
			reason = response.usage.unavailable_reason or reason
		end
		local previous = if type(result.previous) == "table" then result.previous[reading.id] else nil
		reading = retain(reading, previous, reason)
		reading.last_reading_at_ms = nil
		for _, window in reading.windows do
			if window.used ~= nil then reading.last_reading_at_ms = math.max(reading.last_reading_at_ms or 0, window.observed_at_ms) end
		end
		account.reading_ids = { reading.id }
		account.canonical_ids = if reading.canonical_id ~= nil then { reading.canonical_id } else tern.json.array()
		-- A binding stands only while this reading is current and proves one of its logins.
		if account.profile_binding ~= nil then
			local matched = false
			for _, canonical in account.profile_binding.canonical_ids do
				if canonical == reading.canonical_id then matched = true end
				for _, alias in reading.account_aliases or {} do if alias == canonical then matched = true end end
			end
			local current = reason == nil and reading.canonical_id ~= nil
			for _, window in reading.windows do
				if window.unavailable_reason ~= nil or window.last_known_reason ~= nil then current = false end
			end
			if not matched or not current then account.profile_binding = nil end
		end
		table.insert(readings, reading)
	end
	-- Unmeasured accounts prove nothing; an OMP association follows its account's binding.
	for _, scope in roster.scopes or {} do
		local bound = {}
		for _, account in scope.accounts or {} do
			if account.profile_binding ~= nil and #account.reading_ids > 0 then bound[account.id] = true
			else account.profile_binding = nil end
		end
		for _, consumer in scope.consumers or {} do
			if consumer.account_ids ~= nil and not bound[consumer.account_ids[1]] then consumer.account_ids = nil end
		end
	end
	return snapshots.decode({ version = 3, publisher = publisher, as_of_ms = os.time() * 1000, readings = readings, roster = roster })
end

-- Every transfer path ends here. The display is told about a new publication or
-- a changed failure state; a flush requested meanwhile runs once now.
local function settle(token: number, code: string?, published: boolean?)
	busy = false
	local changed = failure ~= code
	failure = code
	if (published or changed) and on_update ~= nil then on_update() end
	if pending_flush and live(token) then
		pending_flush = false
		tick(token)
	end
end

local function transfer(token: number)
	-- This read already sees every refresh completed before it starts.
	pending_flush = false
	request(token, "usage_results", {}, function(result, err)
		if err ~= nil or type(result) ~= "table" then settle(token, "source_usage_unavailable"); return end
		if result.disabled == true or result.token == result.published_token then settle(token, nil); return end
		local ok, snapshot = pcall(collector.project, result)
		if not ok or snapshot == nil then settle(token, "source_snapshot_rejected"); return end
		request(token, "usage_publish", { token = result.token, snapshot = snapshot }, function(accepted, rejected)
			if rejected ~= nil or type(accepted) ~= "table" or accepted.accepted ~= true then
				settle(token, "source_publication_failed"); return
			end
			settle(token, nil, true)
		end)
	end)
end

tick = function(token: number)
	if not live(token) then return end
	if timer == nil then
		timer = tern.timer(POLL_MS, function()
			if not live(token) then return end
			timer = nil
			tick(token)
		end)
	end
	if busy then return end
	busy = true
	if not ready then
		companion.ensure(function(value, err)
			if not live(token) then return end
			if err ~= nil or value == nil then settle(token, "companion_unavailable"); return end
			busy = false
			ready = true
			tick(token)
		end, { install_dependencies = false })
	elseif tern.now() >= next_renew then
		request(token, "register_client", { client_id = "host", kind = "host", ttl_seconds = 90 }, function(value, err)
			if value == nil or err ~= nil then ready = false; settle(token, "host_lease_unavailable"); return end
			next_renew = tern.now() + RENEW_MS
			transfer(token)
		end)
	else
		transfer(token)
	end
end

-- A flush during an in-flight transfer is kept and runs when that transfer ends,
-- so a completed refresh is never read with a stale result token.
function collector.flush()
	if not running then return end
	if busy then pending_flush = true else tick(generation) end
end
function collector.start(callback: any?)
	if running then on_update = callback or on_update; return end
	generation += 1
	running, ready, busy, pending_flush, next_renew, failure = true, false, false, false, 0, nil
	on_update = callback
	companion.set_client("host", "host")
	tick(generation)
end
function collector.stop()
	if not running then return end
	generation += 1
	running, ready, busy, pending_flush, failure = false, false, false, false, nil
	if timer ~= nil then timer:cancel(); timer = nil end
	on_update = nil
end
-- nil when the last publication succeeded (or nothing has failed yet); otherwise
-- { code } naming why new values are not reaching the display.
function collector.state(): { code: string }?
	return if failure ~= nil then { code = failure } else nil
end
return collector
