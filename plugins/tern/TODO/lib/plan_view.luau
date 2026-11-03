-- English-first native checklist, derived from Felipe Carneiro's MIT session-list renderer.
-- Interactive plans only. CodexBWAI, COMMANDER-993.
local view = {}
function view.draw(ui, plan, source, errorText, updated)
    if errorText then
        return {main = ui.node("checklist", {mode = "full", phases = {{id = "error", items = {{id = "error", text = "Plan unavailable", status = "blocked", note = errorText}}}}})}
    end
    if not plan then
        return {main = ui.text({ui.span("Reading the selected interactive plan…", "muted")})}
    end
    local items, done = {}, 0
    for _, cp in plan.checkpoints do
        table.insert(items, {id = cp.id, text = if plan.current == cp.id then "Current · " .. cp.text else cp.text,
            status = cp.state, note = cp.reason})
        if cp.state == "done" then done += 1 end
    end
    return {main = ui.col({
        ui.text({ui.span(plan.title .. " · " .. tostring(done) .. "/" .. tostring(#items), "muted")}),
        -- Use the same unframed native checklist family as OMP's ACP todos.
        ui.node("checklist", {mode = "full", phases = {{id = "checkpoints", items = items}}}),
        ui.text({ui.span(source, "muted")}),
        ui.text({ui.span("Read-only plan view · Last read " .. tostring(updated), "muted")}),
    })}
end
return view
