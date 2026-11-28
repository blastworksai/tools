--!strict
-- Choose an explicit source in the native TODO pane on the execution host.
local picker = {}

export type Entry = { path: string, name: string, title: string, plan_id: string }
export type Catalog = { revision: number, root: string?, plans: { Entry }?, error: string?, truncated: boolean? }

function picker.catalog(revision: number, status: number, envelope: any): Catalog
    if status == 0 and type(envelope) == "table" and envelope.ok == true
        and type(envelope.root) == "string" and type(envelope.plans) == "table" then
        local plans: { Entry } = {}
        for _, plan in envelope.plans do
            if type(plan) == "table" and type(plan.path) == "string" and type(plan.name) == "string"
                and type(plan.title) == "string" and type(plan.plan_id) == "string" and plan.plan_id:match("^plan%-%x+$") then
                table.insert(plans, plan)
            end
        end
        return { revision = revision, root = envelope.root, plans = plans, truncated = envelope.truncated == true }
    end
    local errorText = if type(envelope) == "table" and type(envelope.error) == "string" then envelope.error
        else "Could not list plans on this host."
    return { revision = revision, error = errorText }
end

function picker.selected(catalog: Catalog, value: string): Entry?
    local revision, index = value:match("^(%d+):(%d+)$")
    if tonumber(revision) ~= catalog.revision or not catalog.plans then return nil end
    local position = tonumber(index)
    return if position then catalog.plans[position] else nil
end

function picker.draw(ui: any, catalog: Catalog, sync: Node): BlockView
    local nodes = { ui.text({ ui.span("Choose a plan", "title") }) }
    local plans = catalog.plans
    if catalog.error then
        table.insert(nodes, ui.text(catalog.error))
    elseif plans == nil then
        table.insert(nodes, ui.node("progress", { label = "Finding plans…" }))
    elseif #plans == 0 then
        table.insert(nodes, ui.text("No readable Glitch plans on this host."))
    else
        for index, plan in plans do
            table.insert(nodes, ui.el("button", {
                text = plan.title, actions = { click = string.format("choose-plan=%d:%d", catalog.revision, index) },
                attrs = { ["aria-label"] = "Open " .. plan.name },
            }))
            table.insert(nodes, ui.text({ ui.span(plan.name, "muted") }))
        end
        if catalog.truncated then table.insert(nodes, ui.text("Some plans are outside this list.")) end
    end
    table.insert(nodes, sync)
    return {
        main = ui.col(nodes),
        dock = ui.el("button", { text = "Refresh", actions = { click = "refresh-plans" } }),
    }
end

return picker
