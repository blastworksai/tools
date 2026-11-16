-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.
-- The host is the sole writer of the retired updater.v1 KV key. A window first
-- adopts its exact legacy value into one owned file through explicit Resolve.
local Journal = require("./journal")
local State = require("./state")
local Cli = require("./cli")
local Host = {}
local function equal(a, b, depth)
	if type(a) ~= type(b) or depth > 12 then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in pairs(a) do if not equal(value, b[key], depth + 1) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end
local function claim(name, attempt)
	if type(name) ~= "string" or #name > 240 or not name:match("^owner%-[0-9a-f]*%-%d+%-%d+%.json$") then
		return nil, "Invalid legacy-resolution file"
	end
	local ok, bytes = pcall(tern.fs.read, tern.plugin.data .. "/updater/" .. name, Journal.MAX_BYTES)
	if not ok then return nil, "Legacy-resolution claim is unreadable" end
	local decoded, record = pcall(tern.json.decode, bytes)
	if not decoded or not State.valid(record) or record.attempt ~= attempt or record.phase ~= "resolving"
		or Journal.filename(record.owner) ~= name or type(record.payload.legacy) ~= "table"
		or record.payload.legacy.owner_stopped_attested ~= true or record.payload.legacy.operation_stopped_attested ~= true
		or #record.payload.targets == 0 then return nil, "Explicit, file-backed legacy resolution is required" end
	return { name = name, bytes = bytes, record = record }
end
function Host.register()
	if tern.context ~= "host" then return end
	tern.block.define("updater-recovery", {
		init = function(cx, args)
			local state = { message = "Checking the adopted legacy updater claim", done = false }
			local function finish(message)
				state.message, state.done = message, true
				pcall(cx.render, cx)
			end
			local name, attempt = args[1], args[2]
			tern.timer(0, function()
				local row, err = claim(name, attempt)
				if row == nil then finish(err); return end
				Cli.executable(function(exe, executable_error)
					if exe == nil then finish(executable_error); return end
					Cli.inspect(exe, row.record.owner.route, function(rows, inventory_error)
						if rows == nil then finish(inventory_error); return end
						if Journal.owner_status(row.record.owner, row.record.owner.route, rows) ~= "live" then
							finish("The resolving window incarnation is no longer live; legacy KV was preserved"); return
						end
						local current, current_error = claim(name, attempt)
						if current == nil or current.bytes ~= row.bytes then finish(current_error or "The adopted legacy claim changed"); return end
						local ok, legacy = pcall(tern.kv.get, Journal.LEGACY_KEY)
						if not ok then finish("Legacy KV is unreadable; nothing was cleared"); return end
						if legacy == nil then finish("Legacy KV is already absent; the adopted file remains authoritative"); return end
						if not equal(legacy, current.record.payload.legacy.value, 0) then finish("Legacy KV changed after adoption; both records were preserved"); return end
						local written = pcall(tern.kv.set, Journal.LEGACY_KEY, nil)
						if not written then finish("The host could not clear legacy KV; the adopted file was preserved"); return end
						local verified, value = pcall(tern.kv.get, Journal.LEGACY_KEY)
						if not verified or value ~= nil then finish("Legacy KV removal is not verified; the adopted file remains pending"); return end
						finish("Legacy state is adopted by the resolving window. Continue Resolve update outcome there; no install was launched")
					end)
				end)
			end)
			return state
		end,
		title = function() return "Updater legacy recovery" end,
		view = function(state)
			return { main = tern.ui.col({ tern.ui.text("Updater legacy recovery"), tern.ui.text(state.message),
				tern.ui.text("This native host block only clears the exact legacy key after its pending file is verified. It never installs or clears that file") }) }
		end,
		save = function() return nil end,
	})
end
return Host
