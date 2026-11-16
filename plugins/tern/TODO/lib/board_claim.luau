--!strict
-- Write-side claim on a managed board, serialised through this plugin's host half. MIT.
--
-- Why: the board API reads at most 500 cards and a lane cannot be paged. Two windows that both read an
-- empty board and each append a 500-entity plan leave 1,000 cards whose first 500 are one correct card per
-- entity: every later read looks correct, so no pass can see the duplicates. The only sound fix is to stop
-- two windows adding for the same board at once. tern.kv has no compare-and-set, so (as in
-- status/status_prompt.luau) the host half is the single serialiser:
--   1. a window that wants a board writes ONE request slot (token, board, time) when the slot is empty;
--   2. the host, one thread per daemon, in one synchronous step grants the request: it writes
--      `board_claim.grant/<board>` = { token, until } when that board has no unexpired grant, and clears the slot;
--   3. only the window whose token the grant names may read and write that board; it deletes the grant when done.
-- A request lost to another window's overwrite is simply written again once the slot is empty.
-- Fail closed: no grant within WAIT_MS means no sync this tick (the caller retries later).
-- A grant expires after LEASE_S so a window that died holding it cannot block the board forever; the holder
-- checks `holds` before every read and write, so a grant lost to a clobbered kv.json stops the pass.
local claim = {}

claim.REQUEST = "board_claim.request"
claim.GRANT = "board_claim.grant/"
claim.POLL_MS = 250
claim.WAIT_MS = 20000
claim.FRESH_S = 30
claim.LEASE_S = 120

export type Env = {
	kv: { get: (string) -> any, set: (string, any) -> () },
	now: () -> number, -- seconds
	timer: (number, (any?) -> ()) -> any,
	token: () -> string,
}

local function expired(grant: any, now: number): boolean
	return type(grant) ~= "table" or type(grant.token) ~= "string" or type(grant.at) ~= "number" or now - grant.at > claim.LEASE_S
end

-- Host only. One synchronous step: grants the pending request when its board is free. Returns the granted token.
function claim.host_step(env: Env): string?
	local request = env.kv.get(claim.REQUEST)
	if request == nil then return nil end
	local now = env.now()
	if type(request) ~= "table" or type(request.token) ~= "string" or type(request.board) ~= "string" or type(request.at) ~= "number"
		or math.abs(now - request.at) > claim.FRESH_S then
		env.kv.set(claim.REQUEST, nil)
		return nil
	end
	local key = claim.GRANT .. request.board
	if not expired(env.kv.get(key), now) then return nil end -- held: the request waits in the slot
	env.kv.set(key, { token = request.token, at = now })
	env.kv.set(claim.REQUEST, nil)
	return request.token
end

-- Host only: polls for requests for as long as the host runs.
function claim.host_serve(env: Env)
	local function step(_: any?)
		pcall(claim.host_step, env)
		env.timer(claim.POLL_MS, step)
	end
	env.timer(0, step)
end

-- Window. True while `token` still holds the board's grant.
function claim.holds(env: Env, board: string, token: string): boolean
	local ok, grant = pcall(env.kv.get, claim.GRANT .. board)
	if not ok or expired(grant, env.now()) then return false end
	return (grant :: any).token == token
end

-- Window. cx is the window context of the call that starts it. Waits for the grant, then calls
-- granted(cx, token, release) with the fresh window context of the timer that saw it.
-- failed(reason) is called instead when no grant arrives in time (or the window context is gone).
function claim.acquire(env: Env, cx: any, board: string, granted: (any, string, () -> ()) -> (), failed: (string) -> ())
	local token = env.token()
	local startedAt = env.now()
	local function release()
		pcall(function()
			local grant = env.kv.get(claim.GRANT .. board)
			if type(grant) == "table" and grant.token == token then env.kv.set(claim.GRANT .. board, nil) end
		end)
	end
	local function give_up(reason: string)
		release()
		pcall(function()
			local request = env.kv.get(claim.REQUEST)
			if type(request) == "table" and request.token == token then env.kv.set(claim.REQUEST, nil) end
		end)
		failed(reason)
	end
	local function poll(cx: any?)
		if cx == nil then give_up("The window closed before the board was free."); return end
		local ok, err = pcall(function()
			if claim.holds(env, board, token) then
				granted(cx, token, release)
				return "granted"
			end
			if (env.now() - startedAt) * 1000 > claim.WAIT_MS then give_up("The board is busy in another window."); return "gone" end
			local request = env.kv.get(claim.REQUEST)
			if request == nil or (type(request) == "table" and request.token ~= token and math.abs(env.now() - (request.at or 0)) > claim.FRESH_S) then
				env.kv.set(claim.REQUEST, { token = token, board = board, at = env.now() })
			end
			return nil
		end)
		if not ok then give_up("Could not claim the board: " .. tostring(err)); return end
		if err == "granted" or err == "gone" then return end
		env.timer(claim.POLL_MS, poll)
	end
	poll(cx)
end

return claim
