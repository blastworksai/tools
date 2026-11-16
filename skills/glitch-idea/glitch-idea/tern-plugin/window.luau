-- Glitch Idea: opens the local idea page above the pane that asked for it.
-- MIT. Rule: loopback pairing links only, only for a title written inside a pane of this Tern,
-- never sends input, never runs a program.

local request = require("./lib/request")

local last_asked = {} -- pane -> ms of its last accepted request; dropped when the pane closes

local function now_ms()
    local okay, value = pcall(function() return tern.now() end)
    if okay and type(value) == "number" then return value end
    return nil
end

-- True only when Tern says the asking pane is the focused one; an unknown focus is never the asker.
local function focused(cx, asker)
    local okay, page = pcall(function() return cx.session:focused() end)
    return okay and type(page) == "number" and page == asker
end

local function report(port, rid, how)
    local url = request.result_url(port, rid, how)
    if url == nil then return end
    pcall(function() tern.fetch(url, { timeout_ms = 3000 }, function() end) end)
end

-- Open the page beside the focused pane, then move it to the asking pane: above it (lift), or, for a deferred claim from
-- the helper's only candidate (sole, title version 3), beside it with focus left where it is (it may sit in another tab).
-- A deferred claim from one of several candidates (version 2, the asker unknown) stays beside the focused pane.
-- Uses only the fresh cx it is given.
local function place(cx, url, asker, lift, sole)
    local opened = pcall(function() cx:open(url, "beside", { focus = true }) end)
    if not opened then return "open_failed" end
    local okay, page = pcall(function() return cx.session:focused() end)
    if not okay or type(page) ~= "number" or page == asker then return "beside" end
    if lift then
        local moved, done = pcall(function() return cx.layout:move(page, asker, "up") end)
        if moved and done == true then return "above" end
        return "beside"
    end
    if sole then
        pcall(function() return cx.layout:move(page, asker, "right", { focus = false }) end)
    end
    return "beside"
end

local function on_claim(res, cx, port, rid, asker, deferred, sole)
    if type(res) ~= "table" or res.status ~= 200 then return end
    local url = request.parse_claim(res.body, tern.json.decode)
    if url == nil or not request.valid_url(url) or not request.same_port(url, port) then return end
    local how = place(cx, url, asker, not deferred, deferred and sole)
    report(port, rid, how)
end

local function on_title(ev, cx)
    if type(ev) ~= "table" then return end
    local port, rid, version = request.parse_title(ev.title)
    if port == nil then return end
    local asker = ev.pane
    if type(asker) ~= "number" then return end
    local okay, known = pcall(function() return cx.session:pane(asker) end)
    if not okay or known == nil then return end
    -- Versions 2 and 3 from a pane that is not focused: a deferred claim, which the service grants only when no focused
    -- pane claimed directly. Version 3 (the only candidate) then joins the asking pane's tab; version 2 (one of several)
    -- stays beside the focused pane. It neither checks nor stamps the rate rule (the service caps it).
    local deferred = version >= 2 and not focused(cx, asker)
    local sole = version == 3
    if not deferred then
        local now = now_ms()
        if now == nil or not request.rate_ok(last_asked[asker], now) then return end
        last_asked[asker] = now
    end
    pcall(function()
        tern.fetch(request.claim_url(port, rid, deferred), { timeout_ms = 3000 }, function(res, fresh)
            pcall(on_claim, res, fresh, port, rid, asker, deferred, sole)
        end)
    end)
end

tern.on("title", on_title)
tern.on("pane_closed", function(ev)
    if type(ev) == "table" and ev.pane ~= nil then last_asked[ev.pane] = nil end
end)
