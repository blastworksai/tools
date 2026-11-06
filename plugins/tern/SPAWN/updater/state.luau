-- Vendored from shared/tern-updater by sync.py; edit there, then run sync.py.
--!strict
-- Updater kv record transitions: check interval, notice dedupe, pending-install journal
-- and install-error mapping. Pure: never reads the `tern` global, never mutates its input.
local Version = require("./version")

local State = {}

State.KEY = "updater.v1"
State.INTERVAL = 21600
State.PENDING_TIMEOUT = 600
State.ORCH = "Running ORCH+ controllers pause until you run ORCH+ Reload recovery guide"

export type Record = {
	checked_at: number?,
	remote: string?,
	notified: string?,
	pending_from: string?,
	pending_to: string?,
	pending_at: number?,
	pending_orch: boolean?,
}

export type Notice = { level: string, text: string, sub: string? }

local FIELDS: { [string]: string } = {
	checked_at = "number",
	remote = "string",
	notified = "string",
	pending_from = "string",
	pending_to = "string",
	pending_at = "number",
	pending_orch = "boolean",
}

-- A fresh record holding only the known scalar fields of `record` (kv data is untrusted).
local function copy(record: any): Record
	local out: any = {}
	if type(record) == "table" then
		for key, kind in FIELDS do
			local value = record[key]
			if type(value) == kind then
				out[key] = value
			end
		end
	end
	return out
end

local function clear_pending(record: Record)
	record.pending_from = nil
	record.pending_to = nil
	record.pending_at = nil
	record.pending_orch = nil
end

local function has_pending(record: Record): boolean
	return record.pending_from ~= nil
		or record.pending_to ~= nil
		or record.pending_at ~= nil
		or record.pending_orch ~= nil
end

-- Pending and started less than PENDING_TIMEOUT ago. A start time in the future (clock moved
-- back) counts as stale, so a skewed clock can never block updates indefinitely.
local function pending_fresh(record: Record, now: number): boolean
	local at = record.pending_at
	return has_pending(record) and at ~= nil and now >= at and now - at < State.PENDING_TIMEOUT
end

local function compare(installed: string?, remote: string?): string
	if type(installed) ~= "string" or type(remote) ~= "string" then
		return "unknown"
	end
	local order = Version.compare(installed, remote)
	if order == -1 then
		return "update"
	elseif order == 0 then
		return "current"
	elseif order == 1 then
		return "ahead"
	end
	return "unknown"
end

local function first_line(text: string): string?
	for line in string.gmatch(text, "[^\r\n]+") do
		local trimmed = string.match(line, "^%s*(.-)%s*$")
		if trimmed ~= nil and trimmed ~= "" then
			return trimmed
		end
	end
	return nil
end

local function clip(line: string?, limit: number): string?
	if line == nil or #line <= limit then
		return line
	end
	-- Cut on a UTF-8 boundary when the line is valid UTF-8; otherwise by bytes.
	local cut = if utf8.len(line) ~= nil then utf8.offset(line, limit + 1) else nil
	return string.sub(line, 1, if cut ~= nil then cut - 1 else limit)
end

function State.busy(record: Record?, now: number): boolean
	return pending_fresh(copy(record), now)
end

function State.due(record: Record?, now: number): boolean
	local current = copy(record)
	if pending_fresh(current, now) then
		return false
	end
	local checked = current.checked_at
	if checked == nil or now < checked then
		return true
	end
	return now - checked >= State.INTERVAL
end

function State.outcome(record: Record?, installed: string): string
	local remote = copy(record).remote
	if remote == nil then
		return "none"
	end
	return compare(installed, remote)
end

function State.after_check(
	record: Record?,
	now: number,
	installed: string,
	remote: string?,
	err: string?,
	name: string
): (Record, string, Notice?)
	local out = copy(record)
	out.checked_at = now
	if err ~= nil then
		return out, "error", nil
	end
	out.remote = if type(remote) == "string" then remote else nil
	local outcome = compare(installed, out.remote)
	if outcome == "update" and out.notified ~= out.remote then
		out.notified = out.remote
		return out,
			outcome,
			{ level = "info", text = `{name} {out.remote} is available (you have {installed})` }
	end
	return out, outcome, nil
end

function State.begin(record: Record?, now: number, from: string, to: string, orch: boolean): Record
	local out = copy(record)
	out.pending_from = from
	out.pending_to = to
	out.pending_at = now
	out.pending_orch = orch == true
	return out
end

function State.reconcile(record: Record?, now: number, installed: string?, name: string): (Record, Notice?)
	local out = copy(record)
	if not has_pending(out) then
		return out, nil
	end
	if type(installed) == "string" and installed ~= out.pending_from then
		local orch = out.pending_orch == true
		clear_pending(out)
		return out,
			{ level = "success", text = `{name} updated to {installed}`, sub = if orch then State.ORCH else nil }
	end
	if pending_fresh(out, now) then
		return out, nil
	end
	local to = out.pending_to or "?"
	clear_pending(out)
	local still = if type(installed) == "string" then installed else "unknown"
	return out, { level = "error", text = `{name} update to {to} didn't complete; still {still}` }
end

function State.install_failed(
	record: Record?,
	status: number,
	stderr: string,
	timed_out: boolean
): (Record, Notice)
	local out = copy(record)
	clear_pending(out)
	local text = if type(stderr) == "string" then stderr else ""
	local function has(needle: string): boolean
		return string.find(text, needle, 1, true) ~= nil
	end
	-- A timeout wins: whatever stderr holds was cut off mid-run.
	if timed_out == true then
		return out, { level = "error", text = "Update timed out; nothing was changed" }
	elseif has("installing from git needs git") then
		return out, { level = "error", text = "Updating needs git on this machine" }
	elseif has("is linked") then
		return out, { level = "error", text = "This is a development copy; update it from its source folder" }
	elseif has("git clone") and has("failed") then
		return out, { level = "error", text = "Couldn't download from GitHub", sub = first_line(text) }
	elseif has("is not a plugin") then
		return out,
			{ level = "error", text = "The published copy is broken; nothing was changed", sub = first_line(text) }
	end
	return out, { level = "error", text = "Update failed", sub = clip(first_line(text), 200) }
end

return State
