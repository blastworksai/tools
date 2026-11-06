-- English-first native connection detection. CodexBWAI; MIT.
local controller = require("./lib/attach").new({
    plugin={id=tern.plugin.id}, runtime={os=tern.runtime.os},
    now=function() return tern.now() end, timer=function(ms,callback) return tern.timer(ms,callback) end,
    getenv=function(name) return tern.getenv(name) end,
    json={encode=function(value) return tern.json.encode(value) end, decode=function(value) return tern.json.decode(value) end},
    process={run=function(argv,opts,callback) return tern.process.run(argv,opts,callback) end},
})
tern.command({id="show",title="TODO: attach to this panel",icon="list-checks",run=function(cx) controller.start(cx,false) end})

-- Files-pane entry shares the palette action's panel-aware attach controller.
tern.files.button({id="todo",title="TODO",icon="list-checks",run=function(_files,cx) controller.chooseSession(cx) end})

require("./updater/window").register({ name = "TODO", dir = "TODO", title_prefix = "TODO: " })
