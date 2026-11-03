--!strict
-- The owner-local display route authenticates and verifies chunk digests before
-- returning text. Commit only a complete immutable revision, never page-by-page.
local companion = require("./companion")
local snapshot = require("./snapshot")
local aggregate = {}

function aggregate.new(): any
	local self: any = { snapshots = {}, revision = nil, busy = false }
	function self:project(now_ms: number): any
		return snapshot.project(self.snapshots, now_ms)
	end
	function self:refresh(done: (boolean, any?, any?) -> ())
		if self.busy then return end
		self.busy = true
		local revision: string? = nil
		local parts: any = {}
		local cursors: any = {}
		local accepted: any = {}
		local function fail(err: any?, cx: any?)
			self.busy = false
			done(false, err or { code = "snapshot_rejected", message = "Incomplete or invalid USAGE display; last readings retained." }, cx)
		end
		local page: (string?) -> ()
		page = function(cursor: string?)
			companion.request("display", if cursor == nil then {} else { cursor = cursor }, function(value, err, cx)
				if value == nil then fail(err, cx); return end
				if type(value.revision) ~= "string" or value.revision == "" or type(value.parts) ~= "table"
					or type(value.complete) ~= "boolean" or (revision ~= nil and value.revision ~= revision) then fail(nil, cx); return end
				revision = value.revision
				for _, part in value.parts do
					if type(part) ~= "table" or type(part.publisher) ~= "string" or part.publisher == ""
						or type(part.index) ~= "number" or part.index < 0 or part.index % 1 ~= 0
						or type(part.count) ~= "number" or part.count < 1 or part.count % 1 ~= 0
						or part.index >= part.count or type(part.size) ~= "number" or part.size < 1 or part.size % 1 ~= 0
						or type(part.data) ~= "string" or #part.data == 0 or #part.data > 49152 or utf8.len(part.data) == nil
						or accepted[part.publisher] ~= nil then fail(nil, cx); return end
					local entry = parts[part.publisher]
					if entry == nil then
						entry = { count = part.count, size = part.size, bytes = 0, next = 0, text = {} }
						parts[part.publisher] = entry
					end
					if entry.count ~= part.count or entry.size ~= part.size or entry.next ~= part.index then fail(nil, cx); return end
					entry.bytes += #part.data
					entry.next += 1
					if entry.bytes > entry.size then fail(nil, cx); return end
					table.insert(entry.text, part.data)
					if entry.next == entry.count then
						if entry.bytes ~= entry.size then fail(nil, cx); return end
						local decoded = snapshot.decode(table.concat(entry.text))
						if decoded == nil or decoded.publisher ~= part.publisher then fail(nil, cx); return end
						accepted[part.publisher] = decoded
						parts[part.publisher] = nil
					end
				end
				if value.complete then
					if value.next_cursor ~= nil or next(parts) ~= nil then fail(nil, cx); return end
					self.snapshots, self.revision, self.diagnostics = accepted, revision, value.diagnostics
					self.busy = false
					done(true, nil, cx)
				else
					if type(value.next_cursor) ~= "string" or value.next_cursor == "" or cursors[value.next_cursor] then fail(nil, cx); return end
					cursors[value.next_cursor] = true
					page(value.next_cursor)
				end
			end)
		end
		page(nil)
	end
	return self
end
return aggregate
