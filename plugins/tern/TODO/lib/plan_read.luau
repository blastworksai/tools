--!strict
-- The window half's read of a TODO plan view's plan: the hidden `plan-sync` node of that pane (lib/plan_publish),
-- read through the pane surface. One path for a session on this machine and on another (the node travels with the
-- pane; plugin KV does not). Adapted from ORCH+'s keyed-node surface read. Blastworks.ai; MIT.
local plan_view = require("./plan_view")
local plan_publish = require("./plan_publish")
local read = {}

local READ_CHARS = 64000
local ROOT = "main." .. plan_publish.KEY

local function roleNode(node: any, role: string, depth: number): any?
    if type(node) ~= "table" or depth > 12 or (node.more ~= nil and node.more ~= 0) then return nil end
    if node.k == "text" and type(node.p) == "table" and node.p.role == role then return node end
    for _, child in (if type(node.c) == "table" then node.c else {}) do
        local found = roleNode(child, role, depth + 1)
        if found then return found end
    end
    return nil
end
-- A node's text when it is exactly one span of at most `limit` bytes.
local function spanText(node: any, limit: number): string?
    local spans = node.p.spans
    if type(spans) ~= "table" or #spans ~= 1 then return nil end
    local text = if type(spans[1]) == "string" then spans[1] else spans[1].t
    return if type(text) == "string" and #text <= limit then text else nil
end

-- The raw node text of `panel` (a pane of block `block`), or nil when it cannot be read.
function read.nodeText(cx: any, panel: number, block: string): string?
    local info = cx.session:pane(panel)
    if info == nil or info.block ~= block then return nil end
    local ok, tree = pcall(function() return cx.session:surface(panel, { root = ROOT, nodes = 4, depth = 2, max_chars = READ_CHARS }) end)
    if not ok or type(tree) ~= "table" or type(tree.surface) ~= "table" or tree.surface.role ~= "plugin." .. block
        or (tree.more ~= nil and tree.more ~= 0) then return nil end
    local node = roleNode(tree.main, plan_publish.ROLE, 0)
    if node == nil or node.id ~= ROOT then return nil end
    return spanText(node, plan_publish.LIMIT)
end

export type Result = { kind: string, entry: any?, wait: boolean? }
-- kind: "entry" (a valid plan and its revision) | "waiting" (the view has no plan) | "too_large" | "unreadable".
function read.parse(text: string?, decode: (string) -> any): Result
    if text == nil then return { kind = "unreadable" } end
    local ok, value = pcall(decode, text)
    if not ok or type(value) ~= "table" or value.v ~= 1 or type(value.rev) ~= "number" or type(value.wait) ~= "boolean" then
        return { kind = "unreadable" }
    end
    if value.too_large == true then return { kind = "too_large", wait = value.wait } end
    if value.plan == nil then return { kind = "waiting", wait = value.wait } end
    if plan_view.validate(value.plan) ~= nil then return { kind = "unreadable" } end
    return { kind = "entry", entry = { plan = value.plan, rev = value.rev }, wait = value.wait }
end

function read.plan(cx: any, panel: number, block: string, decode: (string) -> any): Result
    return read.parse(read.nodeText(cx, panel, block), decode)
end

return read
