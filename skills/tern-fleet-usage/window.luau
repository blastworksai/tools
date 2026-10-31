--!strict
-- Collects usage natively from the active Tern agents.

local BLOCK = "tern-fleet-usage.accounts"
local REFRESH_MS = 300000
local scheduled = false
local pending: { [number]: boolean } = {}

local function strip_ansi(text: string): string
	return (string.gsub(text, "\27%[[0-9;?]*[%a]", ""))
end

local function duration_ms(text: string): number
	local total = 0
	for value, unit in string.gmatch(text, "(%d+)%s*([dhms])") do
		local amount = tonumber(value) or 0
		if unit == "d" then
			total += amount * 86400000
		elseif unit == "h" then
			total += amount * 3600000
		elseif unit == "m" then
			total += amount * 60000
		else
			total += amount * 1000
		end
	end
	return total
end

local function provider_for(agent: any, title: string): (string, string)
	local source = string.lower(
		tostring(agent.command or "") .. " " .. tostring(agent.model or "") .. " " .. title
	)
	if string.find(source, "claude", 1, true) then
		return "claude", "Claude"
	elseif string.find(source, "codex", 1, true) or string.find(source, "openai", 1, true) then
		return "openai", "Codex"
	elseif string.find(source, "kimi", 1, true) then
		return "kimi", "Kimi"
	elseif string.find(source, "muse", 1, true) then
		return "muse", "Muse"
	elseif string.find(source, "gemini", 1, true) or string.find(source, "google", 1, true) then
		return "antigravity", "Google"
	end
	return "agent", title ~= "" and title or tostring(agent.model or "Agent")
end

local function parse_usage(agent: any, text: string, now_ms: number, title: string): any?
	local clean = strip_ansi(text)
	local used_text, reset_text = string.match(
		clean,
		"[Ww]eekly%s+[Ll]imit%s+([%d%.]+)%%%s+[Uu]sed%s+[Rr]esets%s+[Ii]n%s+([^\r\n]+)"
	)
	if used_text == nil or reset_text == nil then
		return nil
	end
	local used = tonumber(used_text)
	if used == nil or used < 0 or used > 100 then
		return nil
	end
	local reset_delta = duration_ms(reset_text)
	local provider, provider_label = provider_for(agent, title)
	local account_id = provider .. ":" .. tostring(agent.pane)
	return {
		id = account_id,
		provider = provider,
		provider_label = provider_label,
		account_label = title ~= "" and title or tostring(agent.model or ("pane " .. tostring(agent.pane))),
		plan = if agent.model ~= nil then tostring(agent.model) else nil,
		usage_source = "tern-agent",
		last_reading_at_ms = now_ms,
		windows = {
			{
				key = "seven_day",
				pool = "default",
				used = used,
				remaining = 100 - used,
				resets_at_ms = now_ms + reset_delta,
				observed_at_ms = now_ms,
				unavailable_reason = nil,
			},
		},
	}
end

local function save_agent_usage(cx: WindowCx, agent: any)
	local pane = cx.session:pane(agent.pane)
	local title = if pane ~= nil then pane.title else ""
	local parts: { string } = {}
	local read = cx.session:read(agent.pane, { as = "text", lines = 200, max_chars = 64000 })
	if type(read) == "table" then
		local value = read.text or read.lines
		if type(value) == "string" then
			table.insert(parts, value)
		elseif type(value) == "table" then
			for _, line in value do
				table.insert(parts, tostring(line))
			end
		end
	end
	local transcript_ok, transcript = pcall(cx.agents.transcript, cx.agents, agent.pane, { last = 20 })
	if transcript_ok and type(transcript) == "table" then
		for _, message in transcript do
			if type(message) == "table" and type(message.text) == "string" then
				table.insert(parts, message.text)
			end
		end
	end
	local text = table.concat(parts, "\n")
	local now_ms = math.floor(os.time() * 1000)
	local account = parse_usage(agent, text, now_ms, title)
	if account == nil then
		return
	end
	local snapshot = tern.kv.get("native_snapshot")
	if type(snapshot) ~= "table" then
		snapshot = { version = 1, as_of_ms = now_ms, accounts = tern.json.array() }
	end
	snapshot.as_of_ms = now_ms
	local accounts = snapshot.accounts
	if type(accounts) ~= "table" then
		accounts = tern.json.array()
		snapshot.accounts = accounts
	end
	local replaced = false
	for index, existing in accounts do
		if type(existing) == "table" and existing.id == account.id then
			accounts[index] = account
			replaced = true
			break
		end
	end
	if not replaced then
		table.insert(accounts, account)
	end
	tern.kv.set("native_snapshot", snapshot)
end

local function collect(cx: WindowCx)
	for _, agent in cx.agents:list() do
		if agent.state ~= "working" and agent.state ~= "exited" and not pending[agent.pane] then
			pending[agent.pane] = true
			local ok = pcall(cx.agents.ask, cx.agents, agent.pane, "/usage")
			if not ok then
				pending[agent.pane] = nil
			end
		end
	end
end

tern.on("agent_finished", function(event: { pane: number }, cx: WindowCx)
	if not pending[event.pane] then
		return
	end
	pending[event.pane] = nil
	for _, agent in cx.agents:list() do
		if agent.pane == event.pane then
			save_agent_usage(cx, agent)
			return
		end
	end
end)

tern.on("agent_state", function(event: { pane: number, new: string }, cx: WindowCx)
	if event.new == "idle" and pending[event.pane] then
		for _, agent in cx.agents:list() do
			if agent.pane == event.pane then
				save_agent_usage(cx, agent)
				pending[event.pane] = nil
				return
			end
		end
	end
end)

local function schedule(cx: WindowCx)
	if scheduled then
		return
	end
	scheduled = true
	tern.timer(REFRESH_MS, function(next_cx: WindowCx?)
		scheduled = false
		if next_cx ~= nil then
			collect(next_cx)
			schedule(next_cx)
		else
			schedule(cx)
		end
	end)
end

tern.command({
	id = "open",
	title = "Agent Usage Block: open account usage",
	icon = "gauge",
	group = "Agent Usage Block",
	run = function(cx: WindowCx)
		collect(cx)
		schedule(cx)
		for _, pane in cx.session:panes() do
			if pane.block == BLOCK then
				cx.layout:focus(pane.pane)
				return
			end
		end
		local tab, err = cx.layout:tab({ name = "Agent Usage Block", launch = { block = BLOCK } })
		if tab == nil then
			cx:toast("error", "Agent Usage Block did not open", err)
		elseif err ~= nil then
			cx:toast("error", "Agent Usage Block opened with an error", err)
		end
	end,
})
