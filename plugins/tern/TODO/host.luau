--!strict
-- Interactive-plan view. CodexBWAI, COMMANDER-993, MIT.
-- Identity is the explicitly selected source + immutable plan_id, never another pane number.
local view = require("./lib/plan_view")
local polling = require("./lib/polling")
local selection = require("./lib/host_selection")
local status_prompt = require("./status/status_prompt")
local KIND = tern.plugin.id .. ".list"

type Source = {
    path: string,
    plan_id: string?,
    publication: { [string]: any }?,
    ssh: string?,
    label: string?,
}
type Selection = { mode: string, label: string, request: string }
type Plan = { schema: number?, plan_id: string, title: string, current: string?, checkpoints: { any } }
type State = {
    panel: number,
    source: Source?,
    plan_id: string?,
    bindingSaved: boolean?,
    selection: Selection?,
    selectionStarted: boolean?,
    discover_pid: number?,
    discovery_label: string?,
    finished: boolean?,
    reading: boolean?,
    plan: Plan?,
    error: string?,
    updated: string?,
    terminal: boolean?,
    failures: number?,
    published: string?,
}
local instances: { [number]: State } = {}
local python = selection.interpreter({
    run = function(argv: { string }, options: selection.RunOptions, callback: (result: ProcessResult) -> ())
        tern.process.run(argv, options, function(result: ProcessResult) callback(result) end)
    end,
})

local function sourceValid(source: any): boolean
    return type(source) == "table" and type(source.path) == "string" and source.path ~= ""
        and (source.ssh == nil or (type(source.ssh) == "string" and source.ssh ~= ""))
        and (source.label == nil or (type(source.label) == "string" and #source.label <= 400))
end
-- The window half reads the last plan this panel validated from plugin KV (board sync).
-- A failed read or a closed panel removes it, so a window never syncs a stale success.
local function planKey(state: State): string return "plan/" .. string.format("%.0f", state.panel) end
local function publish(state: State, plan: Plan?)
    local encoded = if plan then tern.json.encode(plan) else nil
    if encoded == state.published then return end
    state.published = encoded
    pcall(function()
        tern.kv.set(planKey(state), if plan then { plan = plan, rev = tern.now() } else nil)
    end)
end
local function live(state: State): boolean
    if state.finished or instances[state.panel] ~= state then publish(state, nil); return false end
    for _, pane in tern.pane.list() do
        if pane.pane == state.panel then return pane.program == KIND end
    end
    instances[state.panel] = nil
    publish(state, nil)
    return false
end
local function redraw(state: State, cx: BlockCx)
    if live(state) then pcall(function() cx:render() end) end
end
local function helperArguments(state: State, helper: string): { string }
    if state.discover_pid then
        return { "-I", helper, "discover", "--parent-pid", tostring(state.discover_pid) }
    end
    local source = state.source
    if source == nil then return {} end
    if source.publication then
        local binding = { path = source.path, plan_id = state.plan_id, publication = source.publication }
        return { "-I", helper, "published", "--binding", tern.json.encode(binding) }
    end
    local arguments = { "-I", helper, "source", "--plan", source.path }
    if source.ssh then table.insert(arguments, "--ssh"); table.insert(arguments, source.ssh) end
    return arguments
end
local function refresh(state: State, cx: BlockCx)
    if not live(state) or (not state.source and not state.discover_pid) or state.reading then return end
    state.reading = true
    local helper = tern.plugin.dir .. "/bin/todo.py"
    python.run(helperArguments(state, helper), { timeout_ms = 6000 }, function(result, problem)
        if not live(state) then return end
        state.reading = false
        if result == nil then
            state.plan = nil; publish(state, nil)
            state.error = problem or "Could not start the read-only source reader. Tern 0.9.8+ and Python 3 are required."
            state.failures = (state.failures or 0) + 1
            redraw(state, cx)
            tern.timer(polling.delay(state.source ~= nil and state.source.ssh ~= nil, state.failures), function() refresh(state, cx) end)
            return
        end
        local decoded, envelope = pcall(tern.json.decode, result.stdout or "")
        if state.discover_pid then
            local outcome = selection.discoveryOutcome(result.status, decoded, envelope)
            if outcome.action == "none" then
                state.finished = true; instances[state.panel] = nil
                pcall(function() cx:toast("info", "No active plan is published for this session.") end)
                cx:exit(0); return
            end
            if outcome.action == "active" then
                local discovered: Source = outcome.source
                discovered.label = state.discovery_label
                state.source = discovered
                state.plan_id = discovered.plan_id; state.discover_pid = nil
                state.error = nil; state.terminal = false; state.failures = 0
                refresh(state, cx); return
            end
            local message = outcome.error or "Could not resolve this session's plan publication."
            state.plan = nil; publish(state, nil); state.error = message
            if outcome.action == "terminal" then
                state.finished = true; instances[state.panel] = nil
                pcall(function() cx:toast("error", message) end)
                cx:exit(1); return
            end
            state.terminal = false
            state.failures = (state.failures or 0) + 1
            redraw(state, cx)
            tern.timer(polling.delay(false, state.failures), function() refresh(state, cx) end)
            return
        end
        state.terminal = decoded and type(envelope) == "table" and envelope.terminal == true
        local plan = if decoded and type(envelope) == "table" then envelope.plan else nil
        local invalid = if type(plan) == "table" then view.validate(plan) else nil
        if result.status ~= 0 or not decoded or envelope.ok ~= true or type(plan) ~= "table" then
            state.plan = nil; publish(state, nil)
            state.error = if decoded and type(envelope) == "table" and type(envelope.error) == "string" then envelope.error else "Could not read the selected source. Check its location, access and Python 3."
        elseif invalid ~= nil then
            state.plan = nil; publish(state, nil); state.error = "Source returned an invalid checkpoint report: " .. invalid
        elseif state.plan_id ~= nil and state.plan_id ~= plan.plan_id then
            state.plan = nil; publish(state, nil); state.error = "This file now belongs to a different plan. Close this panel and explicitly attach the intended plan."
        else
            local needsSave = not state.bindingSaved
            state.plan_id = plan.plan_id
            state.plan = plan
            publish(state, plan)
            state.error = nil
            state.updated = os.date("!%Y-%m-%d %H:%M:%S UTC")
            if needsSave then
                local saved = pcall(function() cx:save() end)
                state.bindingSaved = saved
            end
        end
        state.failures = if state.error then (state.failures or 0) + 1 else 0
        redraw(state, cx)
        if not state.terminal then
            tern.timer(polling.delay(state.source ~= nil and state.source.ssh ~= nil, state.failures), function() refresh(state, cx) end)
        end
    end)
end

tern.block.define("list", {
    init = function(cx: BlockCx, args: { string }, saved: any): State
        local state: State = { panel = cx.pane }
        -- A saved binding can only read the same selected source and stable plan id.
        -- Legacy bare-pane saves/args are deliberately not migrated or followed.
        if type(saved) == "table" and saved.schema == 2 and sourceValid(saved.source) and type(saved.plan_id) == "string" then
            state.source = saved.source; state.plan_id = saved.plan_id; state.bindingSaved = true
        elseif saved == nil and type(args[1]) == "string" then
            local ok, source = pcall(tern.json.decode, args[1])
            if ok and type(source) == "table" and source.mode == "selected" and type(source.request) == "string" and #source.request <= 128 and type(source.label) == "string" and #source.label <= 400 then
                state.selection = source
            elseif ok and sourceValid(source) then
                state.source = source
                if type(args[2]) == "string" and #args[2] <= 80 and args[2]:match("^plan%-%x+$") then state.plan_id = args[2] end
            end
        end
        if not state.source and not state.discover_pid and not state.selection then state.error = "No plan is attached. Close this panel and use TODO: attach to this panel." end
        instances[cx.pane] = state
        if state.selection then
            tern.timer(3000, function()
                if live(state) and not state.selectionStarted then
                    state.finished = true; instances[state.panel] = nil
                    cx:toast("error", "The selected split could not be confirmed. Attach again."); cx:exit(1)
                end
            end)
        end
        tern.timer(1, function() refresh(state, cx) end)
        return state
    end,
    view = function(state: State, _cx: BlockCx): BlockView
        local selected = state.source
        local source = if selected then (if selected.label then selected.label .. ": " elseif selected.ssh then "SSH " .. selected.ssh .. ": " else "Local: ") .. selected.path else ""
        return view.draw(tern.ui, state.plan, source, state.error, state.updated)
    end,
    title = function(state: State): string return if state.plan then state.plan.title else "TODO" end,
    save = function(state: State): any
        if state.source and state.plan_id then return { schema = 2, source = state.source, plan_id = state.plan_id } end
        return { schema = 2 }
    end,
    event = function(state: State, event: UiEvent, cx: BlockCx)
        local selected = state.selection
        if not selected or state.selectionStarted or not live(state) or event.ev ~= "action" or event.id ~= "main" or event.act ~= "confirm-selection" or event.value ~= selected.request then return end
        state.selectionStarted = true
        local ok = pcall(function()
            -- SKILLS-174: the attach args carry no client window key (it is not host identity). "" names this daemon's own first
            -- window; the resolver then walks every window key this daemon itself lists.
            selection.resolve(state.panel, "", function() return live(state) end, function(pid: number?, why: string?)
                if not live(state) then return end
                if pid == nil then
                    state.finished = true; instances[state.panel] = nil
                    cx:toast("error", why or "Could not identify the selected native session."); cx:exit(1); return
                end
                state.discover_pid = pid; state.discovery_label = selected.label; state.selection = nil
                refresh(state, cx)
            end)
        end)
        if not ok then
            state.finished = true; instances[state.panel] = nil
            cx:toast("error", "Could not inspect the selected native session."); cx:exit(1)
        end
    end,
    -- No checkpoint editing, canonical writes, prompt sending or work adoption.
})

require("./updater/host").register()
status_prompt.host_serve()
