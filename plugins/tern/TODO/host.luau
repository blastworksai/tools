--!strict
-- Interactive-plan view. CodexBWAI, COMMANDER-993, MIT.
-- Identity is the explicitly selected source + immutable plan_id, never another pane number.
local view = require("./lib/plan_view")
local polling = require("./lib/polling")
local selection = require("./lib/host_selection")
local plan_publish = require("./lib/plan_publish")
local status_prompt = require("./status/status_prompt")
local board_claim = require("./lib/board_claim")
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
    waitSaved: boolean?,
    selection: Selection?,
    selectionStarted: boolean?,
    discover_pid: number?,
    discover_birth: string?,
    patient: boolean?,
    leases: { [string]: number }?,
    hadWait: boolean?,
    dormant: boolean?,
    discovery_label: string?,
    finished: boolean?,
    reading: boolean?,
    plan: Plan?,
    error: string?,
    updated: string?,
    terminal: boolean?,
    failures: number?,
    publisher: plan_publish.Publisher,
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
-- The window half reads the last plan this panel validated from this view's own hidden node (board sync), through
-- the pane surface, so it works whichever machine the session runs on (lib/plan_publish, lib/plan_read).
-- A failed read, a closed panel or a fresh start removes it, so a window never syncs a stale success.
local function publish(state: State, plan: Plan?) state.publisher.publish(plan) end
local function live(state: State): boolean
    return selection.live(state, instances, tern.pane.list(), KIND, publish)
end
local function later(state: State, ms: number, fn: () -> ()) selection.schedule(state, function(delay: number, f: () -> ()) tern.timer(delay, f) end, ms, fn) end
local function redraw(state: State, cx: BlockCx)
    if live(state) then pcall(function() cx:render() end) end
end
local function helperArguments(state: State, helper: string): { string }
    if state.discover_pid then
        local arguments = { "-I", helper, "discover", "--parent-pid", tostring(state.discover_pid), "--with-identity" }
        -- The process this view first saw: a PID reused by another process ends the wait instead of being followed.
        if state.discover_birth then table.insert(arguments, "--parent-birth"); table.insert(arguments, state.discover_birth) end
        return arguments
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
    if not live(state) or not selection.hasWork(state) or state.reading then return end
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
            later(state, polling.delay(state.source ~= nil and state.source.ssh ~= nil, state.failures), function() refresh(state, cx) end)
            return
        end
        local decoded, envelope = pcall(tern.json.decode, result.stdout or "")
        if state.discover_pid then
            if decoded and type(envelope) == "table" and type(envelope.parent_birth) == "string" and state.discover_birth == nil then
                state.discover_birth = envelope.parent_birth
            end
            -- Sync on and this view serves the attached session: wait for the plan instead of closing. The window says
            -- so by event (it holds the settings and the binding; this machine's plugin store is not the window's).
            local outcome = selection.discoveryStep(result.status, decoded, envelope, selection.patience(state, tern.now()), state.hadWait)
            local delay = selection.settle(state, outcome)
            if outcome.action == "wait" then
                publish(state, nil)
                -- Persist the waiting view (selection.saveState) so a plugin reload resumes it.
                if not state.waitSaved then state.waitSaved = pcall(function() cx:save() end) end
                redraw(state, cx)
                later(state, delay :: number, function() refresh(state, cx) end)
                return
            end
            if outcome.action == "dormant" then
                -- No window asked recently: keep the binding and the open view, say so, and poll slowly (the same
                -- discovery step) so a later plan is found, a closed pane is dropped and an ended process ends the view.
                publish(state, nil)
                redraw(state, cx)
                later(state, delay :: number, function() refresh(state, cx) end)
                return
            end
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
                state.error = nil; state.terminal = false; state.failures = 0; state.dormant = false
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
            later(state, polling.delay(false, state.failures), function() refresh(state, cx) end)
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
            later(state, polling.delay(state.source ~= nil and state.source.ssh ~= nil, state.failures), function() refresh(state, cx) end)
        end
    end)
end

tern.block.define("list", {
    init = function(cx: BlockCx, args: { string }, saved: any): State
        local state: State = { panel = cx.pane, publisher = plan_publish.new(tern.json.encode, tern.now) }
        -- A plan an earlier instance of this panel published must not outlive a reload.
        state.publisher.clear()
        -- A saved binding can only read the same selected source and stable plan id.
        -- Legacy bare-pane saves/args are deliberately not migrated or followed.
        local restored = selection.restoreState(saved, sourceValid, tern.now())
        if restored.source then
            state.source = restored.source; state.plan_id = restored.plan_id; state.bindingSaved = true
        elseif restored.discover_pid then
            -- Only a view that waits for a plan is saved with a session, so it was patient; the window says otherwise by event.
            state.discover_pid = restored.discover_pid; state.discover_birth = restored.discover_birth
            state.discovery_label = restored.discovery_label; state.waitSaved = true; state.leases = restored.leases; state.hadWait = true
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
        later(state, 1, function() refresh(state, cx) end)
        return state
    end,
    view = function(state: State, _cx: BlockCx): BlockView
        local selected = state.source
        local source = if selected then (if selected.label then selected.label .. ": " elseif selected.ssh then "SSH " .. selected.ssh .. ": " else "Local: ") .. selected.path else ""
        return view.draw(tern.ui, state.plan, source, state.error, state.updated, state.publisher.payload(selection.patience(state, tern.now())))
    end,
    title = function(state: State): string return if state.plan then state.plan.title else "TODO" end,
    save = function(state: State): any
        return selection.saveState(state)
    end,
    event = function(state: State, event: UiEvent, cx: BlockCx)
        -- The window tells this view whether to keep waiting for a plan; it is shown back in the plan-sync node.
        local lease = selection.waitLease(event)
        if lease ~= nil then
            if live(state) then
                local changed = selection.applyLease(state, lease, tern.now())
                if lease.on and state.dormant then
                    state.dormant = false; state.error = selection.WAITING; changed = true
                    later(state, 1, function() refresh(state, cx) end)
                end
                if changed then redraw(state, cx) end
            end
            return
        end
        if selection.wakeEvent(event) then
            if live(state) and selection.wake(state) then later(state, 1, function() refresh(state, cx) end) end
            return
        end
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
-- One host per daemon serialises board writes: only one window at a time may add cards to a board.
board_claim.host_serve({ kv = tern.kv, now = os.time, timer = function(ms: number, fn: (any?) -> ()) return tern.timer(ms, fn) end, token = function(): string return "host" end })
