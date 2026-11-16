--!strict
-- Native desktop half. Every event crosses the real window/host surface route.
local pane, sent, stopped
local function find(node)
	if type(node) ~= "table" or node.more and node.more ~= 0 then return nil end
	if node.k == "text" and node.p and node.p.role == "report-component" then return node end
	for _, child in node.c or {} do local found = find(child); if found then return found end end
	return nil
end
local function tick(cx)
	if stopped then return end
	local ok, problem = pcall(function()
		if not pane then
			pane = assert(cx:new_block("report-native-tests.reports", {}, "tab"), "report component host block unavailable")
			tern.log.info("report native GUI ready", cx:window_key(), pane)
			return -- The host block mounts after this window callback returns.
		end
		local tree = cx.session:surface(pane, { nodes = 12, depth = 4, max_chars = 16000 })
		assert(type(tree) == "table" and (tree.more == nil or tree.more == 0), "report surface unavailable or clipped")
		local node = find(tree.main)
		if not node then return end
		local spans = node.p.spans
		assert(type(spans) == "table" and #spans == 1, "ambiguous report surface text")
		local value = tern.json.decode(if type(spans[1]) == "string" then spans[1] else spans[1].t)
		if value.phase == "complete" or value.phase == "failed" then stopped = true; return end
		local key = tostring(value.serial) .. ":" .. value.phase
		if sent == key then return end
		if value.phase == "request" or value.phase == "page" then
			sent = key
			cx.session:event(pane, { ev = "action", act = if value.phase == "request" then "read" else "receive",
				value = tern.json.encode({ serial = value.serial, page = value.page }) })
		end
	end)
	if not ok then
		stopped = true
		tern.log.error("report native GUI failed", problem)
		tern.fs.write(tern.plugin.data .. "/report-result.json", tern.json.encode({ done = true, ok = false, error = tostring(problem), context = "window" }))
		return
	end
	tern.timer(30, tick)
end
tern.on("budget", function(event)
	if event.state == "paused" then tern.log.error("report native GUI budget exceeded", event.hook) end
end)
tern.timer(50, tick)
