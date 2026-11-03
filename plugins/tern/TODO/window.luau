-- English-first native connection detection. CodexBWAI; MIT.
local controller = require("./lib/attach").new({
    plugin={id=tern.plugin.id}, runtime={os=tern.runtime.os},
    getenv=function(name) return tern.getenv(name) end,
    json={encode=function(value) return tern.json.encode(value) end, decode=function(value) return tern.json.decode(value) end},
    process={run=function(argv,opts,callback) return tern.process.run(argv,opts,callback) end},
})
-- Kept as a narrow fixture seam for owned native source/view tests.
local function openSource(cx, target, source) controller.openSource(cx,target,source) end
tern.command({id="show",title="TODO: attach to this panel",icon="list",run=function(cx) controller.start(cx,false) end})
tern.command({id="manual",title="TODO: attach with another source",icon="list",run=function(cx) controller.start(cx,true) end})

-- Files-pane entry shares the palette action's panel-aware attach controller.
tern.files.button({id="todo",title="TODO",icon="list",run=function(_files,cx) controller.start(cx,false) end})
