-- Pure helpers for the Glitch Idea plugin. Never reads the `tern` global: every input is passed in.
-- MIT. Grammar of a pane's request title, the loopback routes, the pairing-link check and the rate rule.

local M = {}

local RATE_MS = 5000
local MAX_URL = 200

local function hex32(text)
    return type(text) == "string" and #text == 32 and not string.find(text, "[^0-9a-f]")
end

local function port_number(port)
    if type(port) ~= "string" or #port < 1 or #port > 5 or string.sub(port, 1, 1) == "0" then return nil end
    local number = tonumber(port)
    if not number or number < 1 or number > 65535 then return nil end
    return number
end

-- The same grammar as the opener's PAIR_URL_PATTERN:
--   http://127.0.0.1:<port 1-65535, no leading zero>/(?binding=binding_<32 hex>)?#pair=<32 hex>
function M.valid_url(url)
    if type(url) ~= "string" or #url > MAX_URL then return false end
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

-- Title grammar: glitch-idea:1:<port 1024..65535, no leading zero>:<rid, 32 lowercase hex>
function M.parse_title(text)
    if type(text) ~= "string" or #text > 100 then return nil end
    local port, rid = string.match(text, "^glitch%-idea:1:([0-9]+):([0-9a-f]+)$")
    if not port or not hex32(rid) then return nil end
    local number = port_number(port)
    if not number or number < 1024 then return nil end
    return number, rid
end

function M.url_port(url)
    if type(url) ~= "string" then return nil end
    local port = string.match(url, "^http://127%.0%.0%.1:([0-9]+)/")
    return port_number(port)
end

function M.same_port(url, port)
    local found = M.url_port(url)
    return found ~= nil and type(port) == "number" and found == port
end

function M.rate_ok(last_ms, now_ms)
    if last_ms == nil then return true end
    return now_ms - last_ms >= RATE_MS
end

function M.claim_url(port, rid)
    return "http://127.0.0.1:" .. tostring(port) .. "/api/v1/tern-claim?rid=" .. rid
end

function M.result_url(port, rid, how)
    if how ~= "above" and how ~= "beside" and how ~= "open_failed" then return nil end
    return "http://127.0.0.1:" .. tostring(port) .. "/api/v1/tern-result?rid=" .. rid .. "&how=" .. how
end

-- decode is injected (tern.json.decode drops members whose value is null).
function M.parse_claim(body, decode)
    if type(body) ~= "string" or type(decode) ~= "function" then return nil end
    local okay, value = pcall(decode, body)
    if not okay or type(value) ~= "table" then return nil end
    if value.ok ~= true or type(value.url) ~= "string" then return nil end
    return value.url
end

return M
