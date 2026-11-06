local Confirm = require("../confirm")

local function base(orch: boolean, remotes)
	return Confirm.items({ name = "TODO", from = "1.0.0", to = "1.1.0", orch = orch, remotes = remotes })
end

return {
	{ "no remotes: local then cancel", function()
		local items = base(false, {})
		assert(#items == 2)
		assert(items[1].label == "Update TODO 1.0.0 → 1.1.0")
		assert(items[1].choice == "local")
		assert(items[1].detail == Confirm.RELOAD)
		assert(items[2].label == "Cancel" and items[2].choice == "cancel")
		assert(items[2].detail == nil)
	end },
	{ "two remotes: one row each, cancel last", function()
		local items = base(false, { { id = 3, name = "box-a" }, { id = 7, name = "box-b" } })
		assert(#items == 4)
		assert(items[2].label == "Update TODO here and on box-a")
		assert(items[2].choice == "remote" and items[2].host == 3)
		assert(items[3].label == "Update TODO here and on box-b")
		assert(items[3].choice == "remote" and items[3].host == 7)
		assert(items[3].detail == Confirm.RELOAD)
		assert(items[4].choice == "cancel")
	end },
	{ "orch true appends ORCH to every update detail", function()
		local items = base(true, { { id = 1, name = "h" } })
		local want = Confirm.RELOAD .. ". " .. Confirm.ORCH
		assert(items[1].detail == want)
		assert(items[2].detail == want)
		assert(items[3].choice == "cancel" and items[3].detail == nil)
	end },
	{ "remote_command single-quotes src", function()
		assert(Confirm.remote_command("/home/u/My Plugins/TODO") == "tern plugin install --force '/home/u/My Plugins/TODO'")
	end },
	{ "remote_command rejects single quote", function()
		local ok = pcall(Confirm.remote_command, "/tmp/it's")
		assert(not ok)
	end },
}
