--!strict
local panel = require("./blocks/panel")

tern.block.define("panel", panel)

require("./updater/host").register()
