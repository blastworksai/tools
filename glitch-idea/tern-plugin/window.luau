-- Glitch Idea: opens a local idea-page pairing link as a browser split beside the focused pane.
-- MIT. The only thing this plugin can open is http://127.0.0.1:<port>/ with a pairing fragment.
-- It never switches host, moves focus between panes, sends input, runs programs or calls agent APIs.

local POLL_MS = 500
local MAX_AGE_S = 30      -- a request older than this is dropped
local SWEEP_MS = 60000    -- request and result files older than this are removed
local MAX_BYTES = 1024

local function hex32(text)
    return type(text) == "string" and #text == 32 and not string.find(text, "[^0-9a-f]")
end

-- The same grammar as the opener's PAIR_URL_PATTERN:
--   http://127.0.0.1:<port 1-65535, no leading zero>/(?binding=binding_<32 hex>)?#pair=<32 hex>
local function valid_url(url)
    if type(url) ~= "string" or #url > 200 then return false end
    local port, rest = string.match(url, "^http://127%.0%.0%.1:([0-9]+)(/.*)$")
    if not port or #port > 5 or string.sub(port, 1, 1) == "0" then return false end
    local number = tonumber(port)
    if not number or number < 1 or number > 65535 then return false end
    local fragment = rest
    if string.sub(rest, 1, 18) == "/?binding=binding_" then
        if not hex32(string.sub(rest, 19, 50)) then return false end
        fragment = "/" .. string.sub(rest, 51)
    end
    if string.sub(fragment, 1, 7) ~= "/#pair=" then return false end
    return hex32(string.sub(fragment, 8))
end

local function valid_name(name)
    return type(name) == "string" and #name == 36 and string.sub(name, 33) == ".req" and hex32(string.sub(name, 1, 32))
end

local function unix_now()
    local ok, value = pcall(function() return os.time() end)
    if ok and type(value) == "number" then return value end
    return nil
end

local function folder()
    local base = tern.getenv("LOCALAPPDATA")
    if type(base) ~= "string" or base == "" then return nil end
    if not (string.match(base, "^[A-Za-z]:[\\/]") or string.match(base, "^\\\\")) then return nil end
    return base .. "\\glitch-idea\\open"
end

local function parse(text)
    local ok, value = pcall(function() return tern.json.decode(text) end)
    if not ok or type(value) ~= "table" then return nil end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    if count ~= 3 or value.v ~= 1 or type(value.url) ~= "string" or type(value.created) ~= "number" then return nil end
    return value
end

local function respond(dir, id, body)
    pcall(function() tern.fs.write(dir .. "\\" .. id .. ".res", tern.json.encode(body)) end)
end

local function failure(dir, id, kind)
    respond(dir, id, { v = 1, ok = false, error = kind })
end

local function handle(cx, dir, id, request)
    local now = unix_now()
    if now == nil then return failure(dir, id, "no_clock") end
    if math.abs(now - request.created) > MAX_AGE_S then return failure(dir, id, "stale") end
    if not valid_url(request.url) then return failure(dir, id, "bad_url") end
    local okHost, host = pcall(function() return cx.hosts:current() end)
    if not okHost or type(host) ~= "table" or host.state ~= "connected" then return failure(dir, id, "no_host") end
    local okFocus, focused = pcall(function() return cx.session:focused() end)
    if not okFocus or type(focused) ~= "number" then return failure(dir, id, "no_focus") end
    local url = request.url
    local agent = focused
    -- Put the page pane above the agent pane when it can be told apart; otherwise it stays beside.
    local function placed(fresh, page)
        local c = fresh or cx
        if type(page) ~= "number" then
            local okNow, now = pcall(function() return c.session:focused() end)
            page = okNow and now or nil
        end
        if type(page) == "number" and page ~= agent then
            local okMove, moved = pcall(function() return c.layout:move(page, agent, "up") end)
            if okMove and moved == true then return true end
        end
        return false
    end
    local okOpen = pcall(function() cx:open(url, "beside", { focus = true }) end)
    if okOpen then
        local above = placed(nil, nil)
        return respond(dir, id, { v = 1, ok = true, how = above and "above-open" or "beside-open" })
    end
    local started, awaited = pcall(function()
        return cx.browser:call({ op = "open", owner = agent, url = url, how = "beside" })
    end)
    if not started then return failure(dir, id, "open_failed") end
    awaited:next(function(result, err, fresh)
        if err == nil and type(result) == "table" and result.error == nil and result.ok ~= nil then
            local block = type(result.ok) == "table" and result.ok.block or nil
            local above = placed(fresh, block)
            respond(dir, id, { v = 1, ok = true, how = above and "above-browser" or "beside-browser" })
        else
            failure(dir, id, "open_failed")
        end
    end)
end

-- Expiry is by age only, never "everything present at start": another window may have just been handed a fresh request.
-- A request is expired by its validated `created` when it is claimed (see handle). Anything never claimed or unreadable
-- (results, half-written files, odd names) is removed once it has been observed here for SWEEP_MS.
-- tern.fs offers no stat, so a symlinked or junctioned folder cannot be detected from here: the sender (the opener
-- script) checks the folder's reparse point, owner and ACL before it writes, and this side only reads capped, claimed,
-- exactly named files.
local seen = {}

local function sweep(dir, names)
    local clock = tern.now()
    local present = {}
    for _, name in ipairs(names) do
        if string.match(name, "^[0-9a-f]+%.req$") or string.match(name, "^[0-9a-f]+%.res$") or string.match(name, "^[0-9a-f]+%.tmp$") then
            present[name] = true
            if seen[name] == nil then seen[name] = clock end
            if clock - seen[name] > SWEEP_MS then
                pcall(function() tern.fs.remove(dir .. "\\" .. name) end)
                seen[name] = nil
            end
        end
    end
    for name in pairs(seen) do
        if not present[name] then seen[name] = nil end
    end
end

local function tick(cx, dir)
    local okList, names = pcall(function() return tern.fs.list(dir) end)
    if not okList or type(names) ~= "table" then return end
    for _, name in ipairs(names) do
        if valid_name(name) then
            local id, path = string.sub(name, 1, 32), dir .. "\\" .. name
            local okRead, text = pcall(function() return tern.fs.read(path, MAX_BYTES) end)
            if okRead and type(text) == "string" then
                -- Claim it: a failed remove means another window already took it.
                if pcall(function() tern.fs.remove(path) end) then
                    local request = parse(text)
                    if request then
                        handle(cx, dir, id, request)
                    else
                        failure(dir, id, "bad_request")
                    end
                end
            end
        end
    end
    local okAgain, after = pcall(function() return tern.fs.list(dir) end)
    if okAgain and type(after) == "table" then sweep(dir, after) end
end

-- window_start runs once per plugin per window, so an update installed into a running window never sees it;
-- the first focus change starts the same loop then. The guard keeps it to one loop.
local running = false
local function start(cx)
    if running then return end
    local dir = folder()
    if dir == nil then return end
    running = true
    pcall(function() tern.fs.mkdir(dir) end)
    local function loop(fresh)
        pcall(tick, fresh or cx, dir)
        tern.timer(POLL_MS, loop)
    end
    pcall(tick, cx, dir)
    tern.timer(POLL_MS, loop)
end

tern.on("window_start", function(cx) start(cx) end)
tern.on("focus", function(_, cx) start(cx) end)
