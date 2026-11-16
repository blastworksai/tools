--!strict
-- English-first native connection detection. CodexBWAI; MIT.
local controller = require("./lib/attach").new({
    plugin = { id = tern.plugin.id },
    now = function(): number return tern.now() end,
    timer = function(ms: number, callback: (WindowCx?) -> ()) return tern.timer(ms, callback) end,
    json = { encode = function(value: any): string return tern.json.encode(value) end },
})
tern.command({ id = "show", title = "TODO: attach to this panel", icon = "list-checks", run = function(cx: WindowCx) controller.start(cx, false) end })

-- Files-pane entry shares the palette action's panel-aware attach controller.
tern.files.button({ id = "todo", title = "TODO", icon = "list-checks", run = function(_files: FilesInfo, cx: WindowCx) controller.chooseSession(cx) end })

require("./updater/window").register({ name = "TODO", dir = "TODO", title_prefix = "TODO: " })
