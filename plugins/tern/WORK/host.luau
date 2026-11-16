--!strict
local panel = require("./blocks/panel")

tern.block.define("panel", panel)

require("./updater/host").register()
require("./status/status_prompt").host_serve()
