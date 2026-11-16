--!strict
-- Shared "turn on the status bar?" prompt, asked at most once per plugin install.
--
-- Window half:  require("./status/status_prompt").ensure(cx, "<plugin id>")  once, on the window's first start path
--               (never inside a chrome formatter: tern.chrome.refresh() raises there).
-- Host half:    require("./status/status_prompt").host_serve()  once at host start (one line in host.luau).
--
-- Why a host half: tern.kv has only get/set (read-modify-write on kv.json, no compare-and-set or set-if-absent)
-- and tern.fs has no exclusive create, so no window-side primitive can make "claim the flag" atomic across windows.
-- The plugin's host half is one single thread per daemon, so the claim is serialised there:
--   1. a window that finds no flag writes a fresh request (token + time) when none is pending;
--   2. the host reads the request and, in one synchronous step, writes the flag naming that token;
--   3. only the window whose token the flag names may ask. Every other window sees a flag for someone else and stops.
-- The flag lives in this plugin's own kv (`<data>/kv.json`), so each plugin keeps its own flag.
-- Fail closed: no host answer within WAIT_MS means no prompt (and no flag), so the next window start retries.
local status_prompt = {}

local FLAG = "status_prompt.v1"
local REQUEST = "status_prompt.v1.request"
local POLL_MS = 250
local WAIT_MS = 15000
local FRESH_S = 30 -- a request older than this belongs to a window that is gone
local REASSERT_MS = 10000 -- the host re-writes a flag that another VM's concurrent kv.json write clobbered

local started = false

-- kv.json is rewritten whole by every VM, so a concurrent write from a VM holding an older copy can drop the flag
-- after the host's short re-assert window, and a later host restart would then ask a second time. A marker file
-- in the data directory is a separate, never-rewritten record that the question was granted; it is only ever read
-- as "already asked". It names the token it granted, so the one waiting winner window can still recover its grant
-- when a stale kv write drops the flag before that window polls; every other window only sees "already asked".
local function marker_path(): string
	return tern.plugin.data .. "/status_prompt.v1.done"
end

local function marker_set(): boolean
	local ok, exists = pcall(tern.fs.exists, marker_path())
	return ok and exists == true
end

local function marker_write(token: string)
	pcall(tern.fs.mkdir, tern.plugin.data)
	pcall(tern.fs.write, marker_path(), token .. "\n")
end

local function marker_token(): string?
	local ok, text = pcall(tern.fs.read, marker_path())
	if not ok or type(text) ~= "string" then return nil end
	return (text:gsub("%s+$", ""))
end

local function asked(): boolean
	return tern.kv.get(FLAG) ~= nil or marker_set()
end

local function fresh_request(value: any): string?
	if type(value) ~= "table" or type(value.token) ~= "string" or type(value.at) ~= "number" then return nil end
	if math.abs(os.time() - value.at) > FRESH_S then return nil end
	return value.token
end

-- Host only. One synchronous step: grants the pending request, if any. Returns the granted token.
function status_prompt.host_claim(): string?
	if asked() then return nil end
	local pending = tern.kv.get(REQUEST)
	local token = fresh_request(pending)
	if token == nil then
		if pending ~= nil then tern.kv.set(REQUEST, nil) end
		return nil
	end
	tern.kv.set(FLAG, { state = "granted", token = token, at = os.time() })
	marker_write(token)
	return token
end

-- Host only: polls for the first request until it is granted, then guards the flag briefly and stops.
-- Starts no timer on a plugin whose flag is already set.
function status_prompt.host_serve()
	if asked() then return end
	local granted: string? = nil
	local until_ms = 0
	local function step()
		if granted == nil then
			granted = status_prompt.host_claim()
			if granted ~= nil then until_ms = tern.now() + REASSERT_MS end
		else
			local flag = tern.kv.get(FLAG)
			if type(flag) ~= "table" or flag.token ~= granted then
				tern.kv.set(FLAG, { state = "granted", token = granted, at = os.time() })
			end
			if tern.now() >= until_ms then return end
		end
		tern.timer(POLL_MS, step)
	end
	tern.timer(0, step)
end

local function ask(cx: any)
	if cx.settings:get("status_bar") == true then return end
	local items = {
		{ label = "Yes, turn on the status bar", detail = "Recommended. The plugin buttons live in the status bar.", answer = true },
		{ label = "No, keep it off", detail = "You can turn it on later in Settings.", answer = false },
	}
	cx:pick({ items = items, placeholder = "Would you like to turn on the status bar?", action = "choose" }):next(function(item: any, _err: any, fresh: any)
		-- Dismiss (nil) and an error leave everything as it was; the flag is already set, so it is never asked again.
		if type(item) ~= "table" or item.answer ~= true then return end
		local live = fresh or cx
		live.settings:set("status_bar", true)
		tern.chrome.refresh()
	end)
end

function status_prompt.ensure(cx: any, plugin_id: string)
	if started then return end
	started = true
	if asked() then return end
	local token = plugin_id .. ":" .. cx:window_key() .. ":" .. tostring(os.time()) .. ":" .. tostring(math.random(1, 2147483647))
	local deadline = tern.now() + WAIT_MS
	local function step(fresh: any?)
		local live = fresh or cx
		local flag = tern.kv.get(FLAG)
		if flag ~= nil then
			if type(flag) == "table" and flag.token == token then ask(live) end
			return
		end
		if marker_set() then
			-- The grant is on disk even though a stale kv write dropped the flag: the named window still asks, once.
			if marker_token() == token then ask(live) end
			return
		end
		if tern.now() >= deadline then
			-- Give up cleanly: a request left behind would be granted to a window that is no longer waiting.
			local pending = tern.kv.get(REQUEST)
			if type(pending) == "table" and pending.token == token then tern.kv.set(REQUEST, nil) end
			return
		end
		if fresh_request(tern.kv.get(REQUEST)) == nil then tern.kv.set(REQUEST, { token = token, at = os.time() }) end
		tern.timer(POLL_MS, step)
	end
	step(cx)
end

return status_prompt
