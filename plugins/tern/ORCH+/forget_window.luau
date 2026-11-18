--!strict
-- "Forget this orchestration…": capability, read-only preview, bound confirmation, durable intent, then completion.
-- The window never closes a pane or stops an agent. It only asks SPAWN (the quiescence authority) and shows its answer.
local codec = require("./wire/codec")
local text = require("./forget_text")
local M = {}
local CHECK_MS = 30000
local RESEND_MS = 5000
function M.new(api: any): any
	local jobs: any = {}
	local self: any = {}
	local function state(cx: WindowCx, source: number, value: any)
		cx.session:event(source, { ev = "action", id = "main.dispatch-state", act = "forget-state", value = tern.json.encode(value) })
	end
	local function owner_of(origin: any): any
		return { owner_id = origin.owner_id, owner_generation = origin.owner_generation, host_pane_id = origin.host_pane_id, alias_nonce = origin.alias_nonce,
			window_key = origin.window_key, native_session_id = origin.native_session_id, window_host_id = origin.window_host_id }
	end
	local function build(job: any, data: any, origin: any, op: string, extra: any?): (string, any)
		local session = data.session_control
		local request: any = { schema = 1, origin = "orchplus", op = op, request_id = api.id(), attempt_id = job.attempt,
			authority_namespace = data.authority_namespace, spawn_namespace = data.spawn_namespace, logical_session_id = origin.logical_session_id,
			admission_seq = session.admission_seq, owner = owner_of(origin), controller_pane = tostring(job.source) }
		for key, value in extra or {} do request[key] = value end
		return tern.json.encode(request), request
	end
	local function fail(cx: WindowCx, job: any, message: string)
		jobs[job.source] = nil
		api.notice(cx, job.source, job.alias, message)
		state(cx, job.source, { stage = "idle" })
	end
	-- One request at a time; the answer is read from the bridge's response lane and bound to the request id.
	local function exchange(cx: WindowCx, job: any, data: any, origin: any, op: string, extra: any?): any?
		local bridge = api.bridge(cx, job.source, origin)
		if not bridge then return nil end
		local node, response_bytes = api.peer(cx, bridge, "", "spawn.dispatch.response")
		if not node then return nil end
		if job.sent == nil or job.sent.op ~= op then
			local bytes, request = build(job, data, origin, op, extra)
			job.sent = { op = op, bytes = bytes, request = request, at = tern.now() }
			api.relay(cx, bridge, { act = op, value = bytes })
			return nil
		end
		local body = if response_bytes then codec.decode_forget_response(response_bytes, job.sent.request) else nil
		if body then return body end
		if tern.now() - job.sent.at >= RESEND_MS and not job.sent.resent then
			job.sent.resent = true
			api.relay(cx, bridge, { act = op, value = job.sent.bytes })
		end
		return nil
	end
	local function refusal_message(body: any): string
		local code = if body.error then body.error.code else ""
		if code == "owner_mismatch" then return text.OWNED_ELSEWHERE end
		if code == "changed" or code == "stale_challenge" or code == "blocked" then return text.CHANGED end
		return text.UNSUPPORTED
	end
	local IDENTITY = { "owner_id", "owner_generation", "host_pane_id", "alias_nonce", "window_key", "native_session_id", "window_host_id" }
	-- Recovery after a reload: the window epoch changed, the owner did not. The cursor comparison in api.current includes the
	-- old epoch, so recovery compares the exact retained identity WITHOUT the epoch (design parts 4 and 7), then supersedes.
	function self.may_act(cx: WindowCx, source: number, origin: any, data: any, recover: boolean): boolean
		if api.current(cx, source, origin) then return true end
		if not recover then return false end
		local session = data.session_control
		local retained = if session and session.close and session.close.control_origin then session.close.control_origin.binding else nil
		if not retained or not api.context(cx, source, origin) then return false end
		for _, name in IDENTITY do if retained[name] ~= origin[name] then return false end end
		return true
	end
	local function binding_holds(job: any, data: any, origin: any): boolean
		local session = data.session_control
		return session ~= nil and session.admission_seq == job.admission and origin.owner_id == job.owner_id
			and origin.owner_generation == job.owner_generation and data.authority_revision == job.authority_revision
	end
	local function confirmed(cx: WindowCx, job: any, data: any, origin: any)
		if not binding_holds(job, data, origin) or not self.may_act(cx, job.source, origin, data, job.recover) then return fail(cx, job, text.CHANGED) end
		local bytes = build(job, data, origin, "discard_session", { challenge = job.challenge, dispatch_revision = job.preview.dispatch_revision, spawn_boot = job.spawn_boot })
		job.phase = "persisting"
		job.origin = api.intent(origin, data)
		local fields: any = { attempt_id = job.attempt, request_bytes = bytes, preview = { spawn_boot = job.spawn_boot, dispatch_revision = job.preview.dispatch_revision },
			control_origin = { kind = "closing", binding = job.origin, controller_pane = tostring(job.source), close_id = job.attempt } }
		if job.recover then api.authority(cx, job.source, job.origin, "supersede_forget", fields)
		else api.authority(cx, job.source, job.origin, "begin_forget", fields) end
	end
	-- A clean preview (or an already-absent session) asks for the one confirmation; recovery needs none: the owner already
	-- chose forgetting and cannot cancel it.
	local function present_confirm(cx: WindowCx, job: any, data: any, origin: any)
		job.phase = "confirm"
		job.owner_snapshot = { owner_id = origin.owner_id, owner_generation = origin.owner_generation }
		job.authority_revision = data.authority_revision
		if job.recover then return confirmed(cx, job, data, origin) end
		local source = job.source
		api.capture(source, origin, cx:pick({ placeholder = text.confirm(data.session_control.name), items = { { label = text.KEEP }, { label = text.FORGET, confirm = true } } }),
			function(choice: any, err: string?, fresh: WindowCx?)
				if jobs[source] ~= job then return end
				if not fresh or not choice or err or not choice.confirm then jobs[source] = nil; state(cx, source, { stage = "idle" }); return end
				local current = api.snapshot(fresh, source)
				local now = if current then api.origin(fresh, source) else nil
				if not current or not now then return fail(fresh, job, text.CHANGED) end
				confirmed(fresh, job, current, now)
			end)
	end
	-- Start (or check again / continue): a fresh attempt always begins with the capability exchange.
	function self.start(cx: WindowCx, source: number, origin: any, data: any, recover: boolean?): boolean
		local session = data.session_control
		if not session or not self.may_act(cx, source, origin, data, recover == true) then return false end
		jobs[source] = { source = source, alias = data.source_nonce, attempt = api.id(), phase = "capability", deadline = tern.now() + CHECK_MS,
			admission = session.admission_seq, owner_id = origin.owner_id, owner_generation = origin.owner_generation,
			authority_revision = data.authority_revision, recover = recover == true }
		api.notice(cx, source, data.source_nonce, text.CHECKING)
		state(cx, source, { stage = "checking" })
		return true
	end
	function self.clear(cx: WindowCx, source: number)
		jobs[source] = nil
		state(cx, source, { stage = "idle" })
	end
	-- Called for every source with a snapshot. Returns true when it owns the session's closing pipeline.
	function self.tick_source(cx: WindowCx, source: number, data: any, origin: any): boolean
		local session = data.session_control
		local pending = if session and session.close then session.close.forget else nil
		local job = jobs[source]
		if job then
			if job.alias ~= data.source_nonce then jobs[source] = nil; return pending ~= nil end
			if tern.now() >= job.deadline and job.phase ~= "confirm" and job.phase ~= "persisting" then fail(cx, job, text.UNSUPPORTED); return pending ~= nil end
			if job.phase == "capability" then
				if session == nil or session.admission_seq == nil then jobs[source] = nil; return pending ~= nil end
				local body = exchange(cx, job, data, origin, "discard_capability")
				if body then
					if body.status ~= "capable" then fail(cx, job, refusal_message(body)); return pending ~= nil end
					job.challenge = body.payload.challenge; job.spawn_boot = body.spawn_boot; job.phase = "preview"; job.sent = nil
					job.deadline = tern.now() + CHECK_MS
					-- SPAWN no longer holds the session (an earlier discard completed and its reply was lost): there is nothing to
					-- preview. Recovery goes straight to the idempotent discard under the fresh challenge.
					if body.payload.absent == true then
						job.preview = { dispatch_revision = 0 }
						present_confirm(cx, job, data, origin)
						return pending ~= nil
					end
				end
			elseif job.phase == "preview" then
				local body = exchange(cx, job, data, origin, "discard_preview", { challenge = job.challenge })
				if body then
					if body.status == "refused" or body.spawn_boot ~= job.spawn_boot then fail(cx, job, refusal_message(body)); return pending ~= nil end
					if body.status == "blocked" then
						job.phase = "blocked"
						state(cx, source, { stage = "blocked", blockers = body.payload.blockers, pending = pending ~= nil })
					else
						job.preview = body.payload
						present_confirm(cx, job, data, origin)
					end
				end
			elseif job.phase == "persisting" then
				if pending and pending.attempt_id == job.attempt then jobs[source] = nil; state(cx, source, { stage = "pending" }) end
				if tern.now() >= job.deadline + CHECK_MS then fail(cx, job, text.CHANGED) end
			end
			return pending ~= nil
		end
		if pending == nil then return false end
		-- A persisted forget owns the pipeline: send its exact bytes, then complete only on SPAWN's closed result.
		local bridge = api.bridge(cx, source, origin)
		if not bridge then return true end
		local node, response_bytes = api.peer(cx, bridge, "", "spawn.dispatch.response")
		if not node then return true end
		local request = codec.decode_forget_request(pending.request_bytes)
		if not request then return true end
		local sent = self.sent[source]
		if sent == nil or sent.attempt ~= pending.attempt_id then
			sent = { attempt = pending.attempt_id, at = tern.now() }
			self.sent[source] = sent
			api.relay(cx, bridge, { act = "discard_session", value = pending.request_bytes })
			return true
		end
		local body = if response_bytes then codec.decode_forget_response(response_bytes, request) else nil
		if body == nil then
			if tern.now() - sent.at >= RESEND_MS and not sent.resent then sent.resent = true; api.relay(cx, bridge, { act = "discard_session", value = pending.request_bytes }) end
			return true
		end
		if body.status == "closed" then
			-- A dropped completion event is retried; the reducer accepts only the exact pending attempt, so it is idempotent.
			if sent.completing and tern.now() - sent.completing >= CHECK_MS then sent.completing = nil end
			if not sent.completing then
				sent.completing = tern.now()
				api.authority(cx, source, api.intent(origin, data), "complete_forget", { attempt_id = pending.attempt_id, response_bytes = response_bytes })
			end
		elseif not sent.reported then
			sent.reported = true
			state(cx, source, { stage = "pending", message = text.PENDING })
		end
		return true
	end
	self.sent = {} :: any
	return self
end
return M
