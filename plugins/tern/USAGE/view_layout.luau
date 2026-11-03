--!strict
-- Window-local ownership: never close, replace, move or type into an owner pane.
local layout = {}
local MODES = { narrow = { dir = "right", ratio = 0.22 }, wide = { dir = "right", ratio = 0.45 }, bottom = { dir = "down", ratio = 0.22 } }
function layout.mode(): string
	local value = tern.kv.get("usage_layout")
	return if type(value) == "string" and MODES[value] ~= nil then value else "narrow"
end
function layout.encode(value: string): string
	return (value:gsub("([^%w%-_%.~])", function(char) return string.format("%%%02X", string.byte(char)) end))
end
function layout.decode(value: string): string?
	if value:gsub("%%[%x][%x]", ""):find("%%") then return nil end
	return (value:gsub("%%([%x][%x])", function(hex) return string.char(tonumber(hex, 16) :: number) end))
end
function layout.new()
	local self: any = { owners = {}, details = {} }
	local function pane(cx: any, id: number?): any?
		for _, item in cx.session:panes() do if item.pane == id then return item end end
		return nil
	end
	local function owned(cx: any, id: number?, kind: string): boolean
		local item = pane(cx, id)
		return item ~= nil and item.block == kind
	end
	function self:owner(cx: any, origin: number): number?
		local source = pane(cx, origin)
		if source == nil then return nil end
		if source.block == nil or source.block:sub(1, 6) ~= "usage." then return origin end
		local remembered = self.owners[origin]
		local target = pane(cx, remembered)
		if target ~= nil and target.tab == source.tab then return target.pane end
		for _, item in cx.session:panes() do
			if item.tab == source.tab and item.pane ~= origin and not item.floating and not item.parked
				and (item.block == nil or item.block:sub(1, 6) ~= "usage.") then return item.pane end
		end
		return origin
	end
	function self:show(cx: any, requested: string?, origin: number?): number?
		local mode = requested or layout.mode()
		if MODES[mode] == nil then return nil end
		local anchor = origin or cx.session:focused()
		if anchor == nil then return nil end
		local anchor_info = pane(cx, anchor)
		local old = nil
		for _, item in cx.session:panes() do
			if item.block == "usage.accounts" and anchor_info ~= nil and item.tab == anchor_info.tab then old = item.pane; break end
		end
		if old ~= nil and requested == nil then cx.layout:focus(old); return old end
		local target = self:owner(cx, old or anchor)
		if target == nil then return nil end
		local options = MODES[mode]
		local fresh = cx:new_block("usage.accounts", { mode }, "beside", { target = target, dir = options.dir, ratio = options.ratio, focus = false })
		if fresh == nil then return nil end
		self.owners[fresh] = target
		if old ~= nil and owned(cx, old, "usage.accounts") then cx.layout:close(old); self.owners[old] = nil end
		if requested ~= nil then tern.kv.set("usage_layout", mode) end
		cx.layout:focus(fresh)
		return fresh
	end
	function self:account(cx: any, origin: number, account: string)
		if not owned(cx, origin, "usage.accounts") and not owned(cx, origin, "usage.account") then return end
		local owner = self:owner(cx, origin)
		if owner == nil then return end
		local source = pane(cx, origin)
		local key = tostring(source.tab) .. ":" .. account
		local existing = self.details[key]
		if owned(cx, existing, "usage.account") then cx.layout:focus(existing); return end
		local detail = cx:new_block("usage.account", { account }, "beside", { target = owner, dir = "right", ratio = 0.4, focus = false })
		if detail == nil then return end
		self.details[key], self.owners[detail] = detail, owner
		-- Target-addressed float: no deferred focus or external ctl process.
		local ok, reason = cx.layout:float(detail, owner, "br", { focus = true, size = { 60, 22 } })
		if not ok then
			-- A real detail split remains accessible; never pretend an overlay is a PIP.
			cx.session:event(detail, { ev = "action", act = "pip_error", value = reason or "PIP unavailable; account detail remains in a split." })
		end
	end
	function self:config(cx: any, origin: number?)
		local target = origin or cx.session:focused()
		local current = pane(cx, target)
		if current == nil then return end
		for _, item in cx.session:panes() do
			if item.block == "usage.config" and item.tab == current.tab then
				cx.layout:focus(item.pane); return
			end
		end
		local owner = self:owner(cx, target) or target
		cx:new_block("usage.config", {}, "beside", { target = owner, dir = "right", ratio = 0.28, focus = true })
	end
	return self
end
return layout
