--!strict
-- Resolve only through the owning host's native split and process inventory.
-- CodexBWAI; MIT. Native CLI transport is shared with the estate's SPAWN design.
local Native=require("./native_cli")
local binding=require("./selected_binding")
local selection={}

export type ProcessResult = {
    status: number,
    stdout: string,
    stderr: string,
    timed_out: boolean,
}
-- Native process options retain a required deadline for TODO helper calls.
export type RunOptions = {
    cwd: string?,
    env: { [string]: string }?,
    stdin: string?,
    timeout_ms: number,
}
export type InterpreterApi = {
    run: (argv: { string }, options: RunOptions, callback: (result: ProcessResult) -> ()) -> (),
}
export type HelperCallback = (result: ProcessResult?, problem: string?) -> ()
export type Interpreter = {
    run: (arguments: { string }, options: RunOptions, callback: HelperCallback) -> (),
}

local INTERPRETERS: { { string } } = { { "py", "-3" }, { "python" }, { "python3" } }
local VERSION_PROBE = "import sys;print('TODO_PYTHON_3={}.{}'.format(*sys.version_info[:2]));sys.exit(sys.version_info.major != 3)"

local function argvWith(prefix: { string }, suffix: { string }): { string }
    local argv = table.clone(prefix)
    for _, value in suffix do table.insert(argv, value) end
    return argv
end

local function python3Version(result: ProcessResult): string?
    if result.status ~= 0 or result.timed_out then return nil end
    local output = result.stdout:gsub("\r\n", "\n"):gsub("\n$", "")
    return output:match("^(TODO_PYTHON_3=3%.%d+)$")
end

-- Only an unsuccessful probe selects another interpreter. Once a real Python 3
-- answers, the helper runs once and its own result is returned without fallback.
function selection.interpreter(api: InterpreterApi): Interpreter
    local selectedPrefix: { string }? = nil

    local function probe(index: number, done: (prefix: { string}?) -> ())
        local candidate = INTERPRETERS[index]
        if candidate == nil then done(nil); return end
        local finished = false
        local started = pcall(function()
            api.run(argvWith(candidate, { "-I", "-c", VERSION_PROBE }), { timeout_ms = 3000 }, function(result)
                if finished then return end
                finished = true
                if python3Version(result) ~= nil then done(candidate) else probe(index + 1, done) end
            end)
        end)
        if not started and not finished then finished = true; probe(index + 1, done) end
    end

    local function execute(prefix: { string }, arguments: { string }, options: RunOptions, callback: HelperCallback)
        local finished = false
        local started, problem = pcall(function()
            api.run(argvWith(prefix, arguments), options, function(result)
                if finished then return end
                finished = true
                callback(result, nil)
            end)
        end)
        if not started and not finished then
            finished = true
            selectedPrefix = nil
            callback(nil, "Could not start the Python 3 helper: " .. tostring(problem))
        end
    end

    return {
        run = function(arguments, options, callback)
            local function withPrefix(prefix: { string }?)
                if prefix == nil then
                    callback(nil, "Python 3 is required. Tried py -3, python and python3; Microsoft Store aliases are not Python installations.")
                else
                    execute(prefix, arguments, options, callback)
                end
            end
            if selectedPrefix ~= nil then
                withPrefix(selectedPrefix)
            else
                probe(1, function(prefix)
                    selectedPrefix = prefix
                    withPrefix(prefix)
                end)
            end
        end,
    }
end

export type DiscoverySource = {
    path: string,
    plan_id: string,
    publication: { [string]: any },
    ssh: string?,
    label: string?,
}
export type DiscoveryOutcome =
    { action: "none" }
    | { action: "active", source: DiscoverySource }
    | { action: "retry", error: string }
    | { action: "terminal", error: string }

function selection.discoveryOutcome(status: number, decoded: boolean, envelope: any): DiscoveryOutcome
    if status == 0 and decoded and type(envelope) == "table" and envelope.ok == true then
        if envelope.state == "none" then return { action = "none" } end
        local source = envelope.source
        if envelope.state == "active" and type(source) == "table" and type(source.path) == "string" and source.path ~= ""
            and (source.ssh == nil or (type(source.ssh) == "string" and source.ssh ~= ""))
            and (source.label == nil or (type(source.label) == "string" and #source.label <= 400))
            and type(source.plan_id) == "string" and type(source.publication) == "table"
        then
            return { action = "active", source = source }
        end
    end
    local message = if decoded and type(envelope) == "table" and type(envelope.error) == "string"
        then envelope.error else "Could not resolve this session's plan publication."
    if decoded and type(envelope) == "table" and envelope.terminal == true then
        return { action = "terminal", error = message }
    end
    return { action = "retry", error = message }
end

export type NativeResult = { status: number, stdout: string }
export type NativeApi = {
    inspect: (window: string, options: RunOptions, callback: (result: NativeResult?, problem: string?) -> ()) -> (),
    process: (window: string, session: number, pane: number, options: RunOptions, callback: (result: NativeResult?, problem: string?) -> ()) -> (),
}
export type SelectionApi = {
    native: NativeApi,
    now: () -> number,
    timer: (ms: number, callback: () -> ()) -> any,
    decode: (text: string) -> any,
}
export type Resolver = {
    resolve: (panel: number, window: string, alive: () -> boolean, callback: (pid: number?, problem: string?) -> ()) -> (),
}

function selection.new(api: SelectionApi): Resolver
    local resolver = {} :: Resolver
    function resolver.resolve(panel: number, window: string, alive: () -> boolean, callback: (pid: number?, problem: string?) -> ())
        local deadline = api.now() + 8000
        local finished = false
        local function active(): boolean return not finished and alive() end
        local function finish(pid: number?, problem: string?)
            if finished or not alive() then return end
            finished = true
            callback(pid, problem)
        end
        api.timer(8000, function() if active() then finish(nil, "Native session inspection timed out.") end end)
        local function inspect(key: string, done: (inventory: any?, problem: string?) -> ())
            if not active() then return end
            local remaining = math.floor(deadline - api.now())
            if remaining <= 0 then finish(nil, "Native session inspection timed out."); return end
            local started = pcall(function()
                api.native.inspect(key, { timeout_ms = math.min(remaining, 2500) }, function(result, problem)
                    if not active() then return end
                    if problem or not result or result.status ~= 0 then done(nil, problem or "Could not inspect the selected execution host."); return end
                    local ok, value = pcall(api.decode, result.stdout or "")
                    done(if ok then value else nil, if ok then nil else "Invalid native host inventory.")
                end)
            end)
            if not started then finish(nil, "Could not start native host inspection.") end
        end
        local function locate(done: (found: binding.Binding?, problem: string?) -> ())
            inspect(window, function(first, problem)
                if not first then done(nil, problem); return end
                local keys: { string } = { window }
                local seen: { [string]: boolean } = { [window] = true }
                for _, client in first.clients or {} do
                    local key = client.window
                    if type(key) == "string" and #key <= 256 and not key:find("%c") and not seen[key] then
                        seen[key] = true; table.insert(keys, key)
                    end
                end
                if #keys > 8 then done(nil, "Too many native windows to identify this attach safely."); return end
                local matches: { binding.Binding } = {}
                local function accept(inventory: any, key: string): string?
                    local found, why = binding.resolve(inventory, panel)
                    if found then found.window = key; table.insert(matches, found)
                    elseif why ~= "pending" then return why end
                    return nil
                end
                local bad = accept(first, window)
                if bad then done(nil, bad); return end
                local function nextKey(index: number)
                    if index > #keys then
                        if #matches == 1 then done(matches[1])
                        elseif #matches == 0 then done(nil, "pending")
                        else done(nil, "The TODO panel belongs to multiple native windows.") end
                        return
                    end
                    inspect(keys[index], function(inventory, why)
                        if not inventory then done(nil, why); return end
                        local rejected = accept(inventory, keys[index])
                        if rejected then done(nil, rejected) else nextKey(index + 1) end
                    end)
                end
                nextKey(2)
            end)
        end
        local function start()
            locate(function(first, problem)
                if not first then
                    if problem == "pending" and api.now() < deadline then api.timer(100, start)
                    else finish(nil, problem) end
                    return
                end
                locate(function(second, why)
                    if not binding.same(first, second) or first.window ~= (second and second.window) then finish(nil, why or "The selected native split changed."); return end
                    local processWindow = first.window
                    if processWindow == nil then finish(nil, "The selected native split changed."); return end
                    local started = pcall(function()
                        api.native.process(processWindow, first.session, first.target, { timeout_ms = math.max(1, math.min(2500, deadline - api.now())) }, function(result, processProblem)
                            if not active() then return end
                            local ok, value = pcall(api.decode, if result then result.stdout or "" else "")
                            if processProblem or not result or result.status ~= 0 or not ok or type(value) ~= "table" or value.pane ~= first.target or type(value.child) ~= "table" or type(value.child.pid) ~= "number" or value.child.pid <= 0 or value.child.pid % 1 ~= 0 then
                                finish(nil, processProblem or "Could not identify the selected native process."); return
                            end
                            locate(function(last, changed)
                                if not binding.same(first, last) or first.window ~= (last and last.window) then finish(nil, changed or "The selected native split changed.")
                                else finish(value.child.pid) end
                            end)
                        end)
                    end)
                    if not started then finish(nil, "Could not start the native process inspection.") end
                end)
            end)
        end
        start()
    end
    return resolver
end
-- What the host does with one discovery answer. "none" (no plan published yet) closes the view with a
-- notice, unless `patient`: then the view stays and asks again on the next wait tick, so a plan published
-- later is found without the owner selecting the session again. Every other outcome is unchanged.
selection.WAIT_MS = 5000
selection.WAITING = "No plan is published for this session yet. This view keeps looking and opens the plan when it appears."
-- A wait the window does not renew ends by itself: the window renews every tick (2 s), the host drops patience after
-- PATIENCE_MS (15 s, about 7 missed renewals), so a closed or crashed window never leaves a host polling forever.
selection.PATIENCE_MS = 15000
function selection.patience(state: any, now: number): boolean
    if state.patient == true and (type(state.patientAt) ~= "number" or now - state.patientAt > selection.PATIENCE_MS) then
        state.patient = false
    end
    return state.patient == true
end
function selection.discoveryStep(status: number, decoded: boolean, envelope: any, patient: boolean): any
    local outcome = selection.discoveryOutcome(status, decoded, envelope)
    if outcome.action == "none" and patient then return { action = "wait", message = selection.WAITING } end
    return outcome
end
-- What a view persists across a plugin reload (`cx:save`). A view that is still waiting for its session's plan keeps
-- the native session it serves (discover_pid) and its label, so after a reload it resumes waiting instead of
-- coming back with nothing to read while the window still believes it serves the session.
function selection.saveState(state: any): any
    if state.source and state.plan_id then return { schema = 2, source = state.source, plan_id = state.plan_id } end
    -- The PID alone is not an identity: it may name another process after a restart. Save the process birth the
    -- helper reported with it; without one nothing is saved, because nothing could be re-validated.
    if type(state.discover_pid) == "number" and type(state.discover_birth) == "string" then
        return { schema = 2, discover_pid = state.discover_pid, birth = state.discover_birth, label = state.discovery_label }
    end
    return { schema = 2 }
end
-- The restored part of a view's state; empty when the save holds nothing usable. `sourceValid` is the host's check.
function selection.restoreState(saved: any, sourceValid: (any) -> boolean): any
    if type(saved) ~= "table" or saved.schema ~= 2 then return {} end
    if sourceValid(saved.source) and type(saved.plan_id) == "string" then
        return { source = saved.source, plan_id = saved.plan_id, bindingSaved = true }
    end
    if type(saved.discover_pid) == "number" and saved.discover_pid > 0 and saved.discover_pid % 1 == 0
        and type(saved.birth) == "string" and #saved.birth >= 1 and #saved.birth <= 160
        and (saved.label == nil or (type(saved.label) == "string" and #saved.label <= 400)) then
        return { discover_pid = saved.discover_pid, discover_birth = saved.birth, discovery_label = saved.label }
    end
    return {}
end
-- The window's wait-for-a-plan request to a plan view: true / false, or nil for any other event.
function selection.waitRequest(event: any): boolean?
    if type(event) ~= "table" or event.ev ~= "action" or event.id ~= "main" or event.act ~= "sync-wait" then return nil end
    if event.value == "on" then return true end
    if event.value == "off" then return false end
    return nil
end
-- Has this view anything to read? (A view with neither a source nor a session to discover just shows its notice.)
function selection.hasWork(state: any): boolean
    return state.source ~= nil or state.discover_pid ~= nil
end
function selection.resolve(panel: number, window: string, alive: () -> boolean, callback: (pid: number?, problem: string?) -> ())
    return selection.new({
        native = Native,
        now = function(): number return tern.now() end,
        timer = function(ms: number, fn: () -> ()) return tern.timer(ms, function() fn() end) end,
        decode = function(text: string): any return tern.json.decode(text) end,
    }).resolve(panel, window, alive, callback)
end
return selection
