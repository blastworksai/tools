-- Glitch Idea: opens the local idea page above the pane that asked for it.
-- MIT. Rule: loopback pairing links only, only for a title written inside a pane of this Tern,
-- never sends input, never runs a program.

local request = require("./lib/request")

local last_asked = {} -- pane -> ms of its last accepted request; dropped when the pane closes

local function now_ms()
    local okay, value = pcall(function() return os.time() * 1000 end)
    if okay and type(value) == "number" then return value end
    return nil
end

local function report(port, rid, how)
    local url = request.result_url(port, rid, how)
    if url == nil then return end
    pcall(function() tern.fetch(url, { timeout_ms = 3000 }, function() end) end)
end

-- Open the page beside, then lift it above the asking pane. Uses only the fresh cx it is given.
local function place(cx, url, asker)
    local opened = pcall(function() cx:open(url, "beside", { focus = true }) end)
    if not opened then return "open_failed" end
    local okay, page = pcall(function() return cx.session:focused() end)
    if okay and type(page) == "number" and page ~= asker then
        local moved, done = pcall(function() return cx.layout:move(page, asker, "up") end)
        if moved and done == true then return "above" end
    end
    return "beside"
end

local function on_claim(res, cx, port, rid, asker)
    if type(res) ~= "table" or res.status ~= 200 then return end
    local url = request.parse_claim(res.body, tern.json.decode)
    if url == nil or not request.valid_url(url) or not request.same_port(url, port) then return end
    local how = place(cx, url, asker)
    report(port, rid, how)
end

local function on_title(ev, cx)
    if type(ev) ~= "table" then return end
    local port, rid = request.parse_title(ev.title)
    if port == nil then return end
    local asker = ev.pane
    if type(asker) ~= "number" then return end
    local okay, known = pcall(function() return cx.session:pane(asker) end)
    if not okay or known == nil then return end
    local now = now_ms()
    if now == nil or not request.rate_ok(last_asked[asker], now) then return end
    last_asked[asker] = now
    pcall(function()
        tern.fetch(request.claim_url(port, rid), { timeout_ms = 3000 }, function(res, fresh)
            pcall(on_claim, res, fresh, port, rid, asker)
        end)
    end)
end

tern.on("title", on_title)
tern.on("pane_closed", function(ev)
    if type(ev) == "table" and ev.pane ~= nil then last_asked[ev.pane] = nil end
end)
