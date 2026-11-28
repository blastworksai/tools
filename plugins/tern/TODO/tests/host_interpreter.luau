-- Windows interpreter discovery uses real Python 3 version probes, never PATH presence.
local selection = require("../lib/host_selection")

local function result(status, stdout)
    return { status = status, stdout = stdout or "", stderr = "", timed_out = false }
end

local function isProbe(argv)
    for index, value in argv do
        if value == "-c" and type(argv[index + 1]) == "string" and argv[index + 1]:find("sys.version_info", 1, true) then return true end
    end
    return false
end

local function fixture(probes, helper, operatingSystem, minimumMinor)
    local f = { probes = {}, helpers = {}, delivered = {} }
    f.interpreter = selection.interpreter({
        run = function(argv, _options, callback)
            if isProbe(argv) then
                table.insert(f.probes, argv)
                local response = probes[argv[1]]
                if response == "hidden" then error("executable not found") end
                callback(response or result(1, "Python was not found; run without arguments to install from the Microsoft Store"))
            else
                table.insert(f.helpers, argv)
                if helper == "spawn failure" then error("helper spawn failed") end
                callback(helper or result(0, '{"ok":true}'))
            end
        end,
    }, operatingSystem, minimumMinor)
    function f.run(arguments)
        f.interpreter.run(arguments or { "-I", "todo.py", "source", "--plan", "/plan.md" }, { timeout_ms = 6000 }, function(value, problem)
            table.insert(f.delivered, { value = value, problem = problem })
        end)
    end
    return f
end

return {
    { "macOS setup skips an old system Python and selects verified Homebrew Python", function()
        local f = fixture({
            python3 = result(0, "TODO_PYTHON_3=3.9\n"),
            ["/opt/homebrew/bin/python3"] = result(0, "TODO_PYTHON_3=3.13\n"),
        }, nil, "macos", 11)
        f.run()
        assert(#f.helpers == 1 and f.helpers[1][1] == "/opt/homebrew/bin/python3")
    end },
    { "hidden py falls through to a verified python and caches the real version probe", function()
        local f = fixture({ py = "hidden", python = result(0, "TODO_PYTHON_3=3.12\r\n") })
        f.run()
        assert(#f.probes == 2 and f.probes[1][1] == "py" and f.probes[1][2] == "-3")
        assert(f.probes[2][1] == "python" and #f.helpers == 1 and f.helpers[1][1] == "python")
        assert(#f.delivered == 1 and f.delivered[1].value.status == 0)
        f.run()
        assert(#f.probes == 2 and #f.helpers == 2, "a later read must reuse the verified interpreter without PATH discovery")
    end },
    { "Store alias stubs are rejected even when PATH execution returns zero", function()
        local f = fixture({
            py = result(1, "Python was not found; run without arguments to install from the Microsoft Store"),
            python = result(0, "Python was not found; run without arguments to install from the Microsoft Store"),
            python3 = result(0, "TODO_PYTHON_3=3.11\n"),
        })
        f.run()
        assert(#f.probes == 3 and f.probes[1][1] == "py" and f.probes[2][1] == "python" and f.probes[3][1] == "python3")
        assert(#f.helpers == 1 and f.helpers[1][1] == "python3")
    end },
    { "a real py launcher is preferred with its -3 prefix intact", function()
        local f = fixture({ py = result(0, "TODO_PYTHON_3=3.13\n") })
        f.run()
        assert(#f.probes == 1 and #f.helpers == 1)
        assert(f.helpers[1][1] == "py" and f.helpers[1][2] == "-3" and f.helpers[1][3] == "-I")
    end },
    { "missing, wrong-version and malformed interpreters never run the helper", function()
        local f = fixture({
            py = "hidden",
            python = result(0, "TODO_PYTHON_3=2.7\n"),
            python3 = result(0, "not a version probe\n"),
        })
        f.run()
        assert(#f.probes == 3 and #f.helpers == 0 and #f.delivered == 1)
        assert(f.delivered[1].value == nil and f.delivered[1].problem:find("Microsoft Store", 1, true))
    end },
    { "a valid helper error envelope is returned once without interpreter fallback", function()
        local f = fixture({ python = result(0, "TODO_PYTHON_3=3.12\n") }, result(1, '{"ok":false,"error":"plan unavailable"}'))
        f.run()
        assert(#f.helpers == 1 and #f.delivered == 1)
        assert(f.probes[#f.probes][1] == "python", "a helper error must not probe another interpreter")
        assert(f.delivered[1].value.status == 1 and f.delivered[1].value.stdout:find("plan unavailable", 1, true))
        assert(f.delivered[1].problem == nil)
    end },
    { "a mutating publication command is never replayed after its helper result", function()
        local f = fixture({ py = result(0, "TODO_PYTHON_3=3.12\n") }, result(1, '{"ok":false,"error":"process changed"}'))
        f.run({ "-I", "todo.py", "publish", "--agent-pid", "42", "--plan", "/plan.md" })
        assert(#f.helpers == 1 and #f.delivered == 1)
        assert(f.probes[#f.probes][1] == "py", "a publication result must stop interpreter fallback")
        assert(f.helpers[1][4] == "todo.py" and f.helpers[1][5] == "publish")
        assert(f.delivered[1].value.status == 1)
    end },
    { "helper spawn failure does not retry the command on another interpreter", function()
        local f = fixture({ python = result(0, "TODO_PYTHON_3=3.10\n") }, "spawn failure")
        f.run({ "-I", "todo.py", "clear", "--agent-pid", "42" })
        assert(#f.helpers == 1 and #f.delivered == 1)
        assert(f.probes[#f.probes][1] == "python", "a helper spawn failure must not replay clear")
        assert(f.delivered[1].value == nil and f.delivered[1].problem:find("helper spawn failed", 1, true))
    end },
    { "initial PublicationUnavailable stays visible, recovers, and only terminal discovery errors exit", function()
        local function discoveryState()
            local state = { alive = true, visible = true, discover_pid = 73, polls = 0 }
            function state.apply(status, envelope)
                local outcome = selection.discoveryOutcome(status, true, envelope)
                if outcome.action == "retry" then
                    state.error = outcome.error
                    state.polls += 1
                elseif outcome.action == "active" then
                    state.source = outcome.source
                    state.discover_pid = nil
                    state.error = nil
                elseif outcome.action == "terminal" or outcome.action == "none" then
                    state.alive = false
                    state.visible = false
                end
                return outcome.action
            end
            return state
        end

        local recovering = discoveryState()
        local action = recovering.apply(1, {
            ok = false,
            error = "cannot inspect native process 73: PermissionError",
            terminal = false,
        })
        assert(action == "retry" and recovering.alive and recovering.visible)
        assert(recovering.discover_pid == 73 and recovering.polls == 1 and recovering.source == nil)
        assert(recovering.error:find("PermissionError", 1, true))

        action = recovering.apply(0, {
            ok = true,
            state = "active",
            source = { path = "/recovered.md", plan_id = "plan-abcdef123456", publication = { pid = 73 } },
        })
        assert(action == "active" and recovering.alive and recovering.visible)
        assert(recovering.discover_pid == nil and recovering.error == nil)
        assert(recovering.source.path == "/recovered.md" and recovering.polls == 1)

        -- Real stdout from `todo.py discover --parent-pid 999999999` after the
        -- helper's ProcessEnded fix, with an isolated absent publication root.
        local endedHelper = fixture(
            { python = result(0, "TODO_PYTHON_3=3.12\n") },
            result(1, '{"ok": false, "error": "process has ended", "terminal": true}')
        )
        endedHelper.run({ "-I", "todo.py", "discover", "--parent-pid", "999999999" })
        assert(#endedHelper.helpers == 1 and #endedHelper.delivered == 1)
        local decoded, envelope = pcall(tern.json.decode, endedHelper.delivered[1].value.stdout)
        assert(decoded and envelope.ok == false and envelope.error == "process has ended" and envelope.terminal == true)
        local ended = discoveryState()
        action = ended.apply(endedHelper.delivered[1].value.status, envelope)
        assert(action == "terminal" and not ended.alive and not ended.visible)
        assert(selection.discoveryOutcome(0, true, { ok = true, state = "none" }).action == "none")
    end },
}
