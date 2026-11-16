-- Deterministic tests of the real carrier with native JSON/base64 and an
-- injected filesystem. No real plugin data, clock, process or native effect.
return function(Channel, native, section)
	local sections = { paths = true, delivery = true, framing = true, recovery = true, bounds = true, drain = true, retirement = true, ack_observation = true }
	assert(section == nil or sections[section], "unknown channel section")
	local checks = 0
	local function check(value, label) assert(value, label); checks += 1 end
	local function code(err, wanted, label)
		check(type(err) == "table" and err.code == wanted, label .. ": " .. tostring(err and err.code))
		for key in err do check(key == "code" or key == "operation" or key == "peer" or key == "slot", "errors contain no body/path/token") end
	end
	local function fixture(prefix)
		local f = { files = {}, dirs = {}, writes = 0, removes = 0, mkdirs = 0, reads = 0, probes = 0, read_bytes = 0,
			prefix = prefix or "/fixture/plugin-data", partial = nil, fail_write = false, fail_read = nil, fail_exists = nil }
		f.fs = {
			exists = function(path)
				f.probes += 1
				if f.fail_exists == path then error("fixture private path and token") end
				return f.files[path] ~= nil or f.dirs[path] == true
			end,
			mkdir = function(path) f.mkdirs += 1; f.dirs[path] = true end,
			list = function() error("carrier must never enumerate directories") end,
			read = function(path, maximum)
				check(maximum == 98304, "every carrier read has native regular-file/size bound")
				f.reads += 1
				if f.fail_read == path then error("fixture private path and token") end
				local value = f.files[path]
				if type(value) ~= "string" or #value > maximum then error("missing, nonregular or oversize") end
				f.read_bytes += #value
				return value
			end,
			write = function(path, raw)
				check(f.files[path] == nil and f.dirs[path] == nil, "never overwrite an immutable file or directory")
				check(#raw <= 98304, "every write respects encoded frame bound")
				check(path:match("/plugin%-channel%-v1/[ma]%-[a-z0-9%-]+%.json$") ~= nil, "fixed prefixed safe file name")
				f.writes += 1
				f.files[path] = if f.partial == path then raw:sub(1, math.floor(#raw / 2)) else raw
				if f.fail_write then error("uncertain write") end
			end,
			remove = function(path)
				check(type(f.files[path]) == "string" and f.dirs[path] ~= true, "cleanup removes a regular file only")
				f.removes += 1; f.files[path] = nil
			end,
		}
		function f.options(plugin, incarnation, data)
			return { plugin_id = plugin, incarnation = incarnation or (plugin .. "-boot"),
				plugin_data = data or (f.prefix .. "/" .. plugin), fs = f.fs, json = native.json, base64 = native.base64 }
		end
		function f.open(plugin, incarnation, data) return assert(Channel.open(f.options(plugin, incarnation, data))) end
		function f.path(plugin, slot) return f.prefix .. "/" .. plugin .. string.format("/plugin-channel-v1/m-%03d.json", slot) end
		function f.ackpath(consumer, producer, slot)
			return f.prefix .. "/" .. consumer .. string.format("/plugin-channel-v1/a-%s-%03d.json", producer, slot)
		end
		f.orch = f.open("orchplus"); f.spawn = f.open("spawn"); f.usage = f.open("usage")
		return f
	end
	local function request(id, body, peer, route, binding)
		return { id = id or "request-1", body = body or "exact domain bytes", peer = peer or "spawn",
			route = route or "spawn.request", binding = binding or "panel:7:boot-1:lane-1" }
	end
	local function poll(endpoint, turns)
		local result, first_error, seen = {}, nil, {}
		for _ = 1, turns or 6 do
			local messages, err = endpoint.receive(4)
			first_error = first_error or err
			for _, message in messages do
				if not seen[message] then seen[message] = true; table.insert(result, message) end
			end
		end
		return result, first_error
	end
	local function settle(endpoint)
		local count, first_error = 0, nil
		for _ = 1, 6 do local n, err = endpoint.settle(4); count += n; first_error = first_error or err end
		return count, first_error
	end

	if section == nil or section == "paths" then
		local f = fixture()
		local before = f.mkdirs
		for _, path in { "relative/orchplus", "/fixture/spawn", "/fixture/../orchplus", "/fixture/./orchplus",
			"/fixture//orchplus", "/fixture/\0/orchplus", "/fixture/\n/orchplus", "/orchplus", "" } do
			local value, err = Channel.open(f.options("orchplus", "boot", path))
			check(value == nil, "reject unsafe or wrong native plugin data root"); code(err, "invalid_options", "unsafe root")
		end
		for _, id in { "SPAWN", "../spawn", "aux", "other-plugin" } do
			local value, err = Channel.open(f.options(id)); check(value == nil, "closed plugin peers"); code(err, "invalid_options", "peer")
		end
		for _, incarnation in { "", "space token", "../boot/", string.rep("x", 81) } do
			local value, err = Channel.open(f.options("spawn", incarnation)); check(value == nil, "strict incarnation"); code(err, "invalid_options", "incarnation")
		end
		check(f.mkdirs == before, "invalid open writes no directories")
		check(f.open("orchplus") ~= nil and f.mkdirs == before, "reopen has no idle mkdir")
		local win = fixture("C:/Users/example/data")
		check(win.open("orchplus", "boot", "C:\\Users\\example\\data\\orchplus\\") ~= nil, "native Windows data path normalized")
		local unc = fixture("//server/share/data")
		check(unc.open("orchplus") ~= nil, "native UNC data parent supported")
		for _, change in {
			{ peer = "../spawn" }, { peer = "usage" }, { peer = "orchplus" }, { route = "spawn.authorize" },
			{ route = "spawn.response" }, { binding = "../panel" }, { binding = "two words" }, { binding = string.rep("x", 161) },
			{ id = "a/b" }, { id = "" }, { id = string.rep("x", 81) }, { body = string.rep("x", 65537) },
			{ callback = "arbitrary" }, { path = "/elsewhere" }, { body = false }, { priority = "urgent" }, { priority = false },
			{ peer = "usage", route = "usage.capacity.request", priority = "settlement" },
			{ peer = "usage", route = "usage.display.request", priority = "settlement" },
		} do
			local value = request(); for key, child in change do value[key] = child end
			local receipt, err = f.orch.send(value)
			check(receipt == nil, "invalid metadata rejected before write"); code(err, "invalid_request", "metadata")
		end
		check(f.writes == 0, "invalid sends write zero bytes")
		local value, err = f.spawn.send(request("forbidden", "body", "usage", "usage.capacity.request"))
		check(value == nil, "no spawn to usage carrier"); code(err, "invalid_request", "direction")
		f.files[f.prefix .. "/orchplus/plugin-channel-v1/../../escaped.json"] = "unrelated"
		f.files[f.prefix .. "/orchplus/plugin-channel-v1/CON.json"] = "unrelated"
		check(f.orch.send(request()) ~= nil, "unlisted foreign filenames never become reads or paths")
		local usage_reply = request("usage-settlement", "read-only response", "orchplus", "usage.capacity.response")
		usage_reply.priority = "settlement"
		check(assert(f.usage.send(usage_reply)).slot == 23, "USAGE may drain its own independent response reserve")
	end

	if section == nil or section == "delivery" then
		local f = fixture()
		local bytes = {}; for i = 0, 255 do table.insert(bytes, string.char(i)) end
		local exact = table.concat(bytes) .. '\r\n{"duplicate":1,"duplicate":2}\0'
		local sent = assert(f.orch.send(request(nil, exact)))
		check(sent.slot == 1 and sent.incarnation == "orchplus-boot", "receipt identifies real producer incarnation/slot")
		local raw, writes = f.files[f.path("orchplus", 1)], f.writes
		local repeated = assert(f.orch.send(request(nil, exact)))
		check(repeated.slot == sent.slot and f.writes == writes, "exact repeat is byte-idempotent with no writes")
		for _, changed in {
			request(nil, exact .. "x"), request(nil, exact, nil, nil, "another-binding"),
			request(nil, exact, "usage", "usage.capacity.request"),
		} do local receipt, err = f.orch.send(changed); check(receipt == nil, "same incarnation/id cannot rebind"); code(err, "conflict", "idempotency conflict") end
		check(f.files[f.path("orchplus", 1)] == raw and f.writes == writes, "conflict leaves original immutable bytes")
		local messages = f.spawn.receive(4)
		check(#messages == 1 and messages[1].body == exact and messages[1].binding == sent.binding, "binary and domain bytes unchanged")
		check(messages[1].peer == "orchplus" and messages[1].recipient == "spawn", "explicit fixed producer and consumer")
		check(messages[1].authorized == nil and messages[1].fresh == nil, "carrier never invents authorization")
		check(settle(f.orch) == 0 and f.files[f.path("orchplus", 1)] == raw, "delivery without durable ACK cannot settle")
		local clone = table.clone(messages[1])
		local ok, err = f.spawn.ack(clone); check(not ok, "fabricated receipt refused"); code(err, "invalid_receipt", "capability")
		messages[1].body = "changed"
		ok, err = f.spawn.ack(messages[1]); check(not ok, "mutated receipt refused"); code(err, "invalid_receipt", "receipt bytes")
		messages[1].body = exact
		check(f.spawn.ack(messages[1]), "explicit durable handling creates ACK")
		local ack = f.files[f.ackpath("spawn", "orchplus", 1)]
		check(ack:find(raw, 1, true) ~= nil, "ACK embeds complete exact frame, not only id")
		writes = f.writes
		check(f.spawn.ack(messages[1]) and f.writes == writes, "immediate duplicate ACK does not write")
		check(#poll(f.spawn) == 0, "ACKed message suppressed while sender awaits settlement")
		check(settle(f.orch) == 1 and f.files[f.path("orchplus", 1)] == nil, "producer settles exactly ACKed own file")
		check(f.files[f.ackpath("spawn", "orchplus", 1)] == ack, "producer never deletes consumer-owned ACK")
		local next_receipt = assert(f.orch.send(request("request-2")))
		check(next_receipt.slot == 2, "ACK handshake prevents premature slot reuse")
		poll(f.spawn)
		check(f.files[f.ackpath("spawn", "orchplus", 1)] == nil, "consumer retires ACK only after absence observed")
		local reusable = assert(f.orch.send(request("request-3")))
		check(reusable.slot == 1, "settled fixed slot safely reusable")
		local reply = assert(f.spawn.send(request("reply", "exact reply", "orchplus", "spawn.response")))
		check(reply.slot == 1, "independent producer slot namespace")
		local replies = poll(f.orch, 12)
		check(#replies == 1 and replies[1].body == "exact reply" and replies[1].peer == "spawn", "reverse route uses SPAWN path")
		local usage = assert(f.orch.send(request("usage", "read-only request", "usage", "usage.display.request")))
		check(usage.slot ~= reusable.slot and usage.slot ~= next_receipt.slot, "all destinations share one bounded producer pool")
		local usage_messages = poll(f.usage)
		check(#usage_messages == 1 and usage_messages[1].id == "usage", "other recipients never consume SPAWN messages")
	end

	if section == nil or section == "framing" then
		local mutations = {
			function(raw) return raw:sub(1, #raw - 1) end,
			function(raw) return raw .. " " end,
			function(raw) return raw .. "{}" end,
			function(raw) return raw:gsub('"v":1', '"v":1,"v":1', 1) end,
			function(raw) return raw:gsub('"v":1', '"unknown":null,"v":1', 1) end,
			function(raw) return raw:gsub('"kind":"message"', '"kind":"ack"', 1) end,
			function(raw) return raw:gsub('"body_bytes":5', '"body_bytes":6', 1) end,
			function(raw) return raw:gsub('"body_bytes":5', '"body_bytes":5.0', 1) end,
			function(raw) return raw:gsub('"slot":1', '"slot":2', 1) end,
			function(raw) return raw:gsub('"from":"orchplus"', '"from":"spawn"', 1) end,
			function(raw) return raw:gsub('"to":"spawn"', '"to":"usage"', 1) end,
			function(raw) return raw:gsub('"id":"request%-1"', '"id":"../escape"', 1) end,
			function(raw) return raw:gsub('"binding":"[^"]+"', '"binding":null', 1) end,
			function(raw) return raw:gsub('"body":"[^"]+"', '"body":"Ynl0ZXM"', 1) end,
			function(raw) return raw:gsub('"body":"[^"]+"', '"body":"Ynl0 ZX M="', 1) end,
			function(raw) return raw:gsub('"body":"[^"]+"', '"body":"_____==="', 1) end,
			function(_) return "[]" end,
			function(_) return string.rep("x", 98305) end,
		}
		for _, mutate in mutations do
			local f = fixture(); assert(f.orch.send(request(nil, "bytes")))
			local path = f.path("orchplus", 1); f.files[path] = mutate(f.files[path])
			local changed, writes = f.files[path], f.writes
			local messages, err = f.spawn.receive(4)
			check(#messages == 0 and err ~= nil, "malformed/torn/noncanonical frame cannot deliver")
			check(f.spawn.status().state == "held", "malformed frame is explicitly held")
			local repeated = f.orch.send(request(nil, "bytes"))
			check(repeated == nil and f.files[path] == changed and f.writes == writes, "retry never repairs an uncertain immutable file")
			check(f.files[f.ackpath("spawn", "orchplus", 1)] == nil, "malformed input never ACKed")
		end
		for _, kind in { "symlink", "fifo", "directory" } do
			local f = fixture(); f.files[f.path("orchplus", 1)] = { kind = kind }
			local messages, err = f.spawn.receive(4)
			check(#messages == 0, "nonregular cannot deliver"); code(err, "unreadable_frame", "native bounded read rejects " .. kind)
			check(f.removes == 0 and f.writes == 0, "nonregular never removed or overwritten")
		end
		local f = fixture(); f.partial = f.path("orchplus", 1)
		local sent, err = f.orch.send(request())
		check(sent == nil, "torn write not reported delivered"); code(err, "write_unconfirmed", "partial write")
		local partial, writes = f.files[f.partial], f.writes; f.partial = nil
		sent, err = f.orch.send(request())
		check(sent == nil and f.files[f.path("orchplus", 1)] == partial and f.writes == writes, "partial write survives retry unchanged")
		code(err, "incomplete_frame", "partial diagnostic")
		local unrelated = assert(f.orch.send(request("unrelated", "independent bytes")))
		check(unrelated.slot == 2 and f.files[f.path("orchplus", 1)] == partial,
			"torn occupied slot does not block a different immutable message")
		check(f.orch.status().state == "held", "successful unrelated send retains partial-slot diagnostic")
		local reloaded = f.open("orchplus", "after-torn-write")
		check(assert(reloaded.send(request("fresh-after-reload"))).slot == 3,
			"new host incarnation routes around retained partial slot")
		check(f.files[f.path("orchplus", 1)] == partial and f.removes == 0,
			"reload never deletes undecodable transport or reconstructs its domain obligation")
		f = fixture(); f.fail_write = true
		sent, err = f.orch.send(request()); check(sent == nil, "uncertain complete write returns held"); code(err, "write_unconfirmed", "write exception")
		f.fail_write = false; writes = f.writes
		check(f.orch.send(request()) ~= nil and f.writes == writes, "complete uncertain write reconciles exact bytes without rewrite")
		f = fixture(); assert(f.orch.send(request()))
		local message = f.spawn.receive(4)[1]
		f.partial = f.ackpath("spawn", "orchplus", 1)
		local ok; ok, err = f.spawn.ack(message)
		check(not ok, "partial ACK not called complete"); code(err, "write_unconfirmed", "ACK partial")
		f.partial = nil; writes = f.writes
		ok, err = f.spawn.ack(message); check(not ok and f.writes == writes, "partial ACK is never overwritten"); code(err, "conflict", "ACK retry")
		local count; count, err = settle(f.orch)
		check(count == 0 and f.files[f.path("orchplus", 1)] ~= nil, "partial ACK cannot erase live data"); code(err, "conflicting_ack", "ACK framing")
	end

	if section == nil or section == "recovery" then
		local f = fixture(); assert(f.orch.send(request()))
		local retained = f.files[f.path("orchplus", 1)]
		local old_message = f.spawn.receive(4)[1]
		local fresh_spawn = f.open("spawn", "spawn-reloaded")
		local ok, err = fresh_spawn.ack(old_message)
		check(not ok, "reload does not restore ACK capability"); code(err, "invalid_receipt", "old host receipt")
		local new_message = fresh_spawn.receive(4)[1]
		check(new_message.body == old_message.body and new_message.incarnation == "orchplus-boot", "reload preserves old exact bytes/incarnation")
		check(new_message.fresh == nil and new_message.authorized == nil and new_message.deadline == nil, "disk never renews grant/deadline")
		local writes = f.writes
		local new_orch = f.open("orchplus", "orch-reloaded")
		check(f.files[f.path("orchplus", 1)] == retained and f.writes == writes, "open/reload does not rewrite grants")
		check(fresh_spawn.ack(new_message), "new receive can ACK only after caller reconciles durable domain result")
		check(settle(new_orch) == 1, "new producer incarnation can settle exact retained transport result")
		local old_ack = f.files[f.ackpath("spawn", "orchplus", 1)]
		poll(fresh_spawn)
		assert(new_orch.send(request("new-request", "new-grant")))
		local newer = f.files[f.path("orchplus", 1)]
		f.files[f.ackpath("spawn", "orchplus", 1)] = old_ack
		local count; count, err = settle(new_orch)
		check(count == 0 and f.files[f.path("orchplus", 1)] == newer, "delayed old ACK cannot erase reused slot")
		code(err, "conflicting_ack", "old ACK binds full frame")
		local delivered; delivered, err = poll(fresh_spawn)
		check(#delivered == 0 and err ~= nil, "old ACK conflict is explicit rather than silently dropped")
		check(f.files[f.ackpath("spawn", "orchplus", 1)] == old_ack, "conflicting ACK preserved for reconciliation")
		f = fixture(); assert(f.orch.send(request()))
		local captured = f.spawn.receive(4)[1]
		f.files[f.path("orchplus", 1)] = nil
		assert(f.open("orchplus", "orch-new").send(request("replacement", "new authority")))
		ok, err = f.spawn.ack(captured)
		check(not ok, "late callback cannot ACK replacement data"); code(err, "conflict", "late callback")
		check(f.files[f.ackpath("spawn", "orchplus", 1)] == nil, "late callback makes no ACK")
		f = fixture(); assert(f.orch.send(request()))
		writes = f.writes
		for _ = 1, 8 do poll(f.spawn); settle(f.orch) end
		check(f.writes == writes and f.removes == 0, "unhandled retained message never expires or authorizes automatically")
		f.fail_read = f.path("orchplus", 1)
		local messages; messages, err = poll(f.spawn)
		check(#messages == 0 and err ~= nil and f.spawn.status().state == "held", "read failure is persistent actionable held state")
		f.fail_read = nil
		messages = poll(f.spawn)
		check(#messages == 1 and f.spawn.status().state == "held", "idle successful poll does not conceal prior failure")
		check(f.spawn.ack(messages[1]) and f.spawn.status().state == "ready", "real protocol progress clears diagnostic")
	end

	if section == nil or section == "bounds" then
		local f = fixture()
		local body = string.rep("x", 65536)
		for index = 1, 22 do
			local receipt = assert(f.orch.send(request("full-" .. tostring(index), body)))
			check(receipt.slot == index, "deterministic fixed slot allocation")
		end
		local writes = f.writes
		local receipt, err = f.orch.send(request("overflow", body))
		check(receipt == nil and f.writes == writes, "backpressure before any write"); code(err, "backpressure", "full endpoint")
		-- Reserved completion requests can drain full ordinary request/execution
		-- pools without widening storage or taking away native authority checks.
		for index = 23, 24 do
			local drain = request("drain-" .. tostring(index), body); drain.priority = "settlement"
			check(assert(f.orch.send(drain)).slot == index, "settlement prefers the two reserved slots")
			local plain_repeat = table.clone(drain); plain_repeat.priority = nil
			check(assert(f.orch.send(plain_repeat)).slot == index, "allocation priority is not immutable message identity")
		end
		writes = f.writes
		local drain_overflow = request("drain-overflow", body); drain_overflow.priority = "settlement"
		receipt, err = f.orch.send(drain_overflow)
		check(receipt == nil and f.writes == writes, "even settlement cannot exceed 24 slots")
		code(err, "backpressure", "reserved pool bounded")
		check(f.open("orchplus", "new-incarnation").send(request("after-reload", body)) == nil, "reload cannot bypass retained storage ceiling")
		local bytes, entries = 0, 0
		for path, raw in f.files do
			if path:find("/orchplus/", 1, true) then bytes += #raw; entries += 1 end
		end
		check(entries == 24 and bytes < 8 * 1024 * 1024, "bounded outgoing disk usage at max body size")
		check(72 * 98304 < 8 * 1024 * 1024, "24 data plus worst 48 exact ACK files remain below endpoint ceiling")
		local reads, probes, read_bytes = f.reads, f.probes, f.read_bytes
		local messages = f.spawn.receive(4)
		check(#messages == 4 and f.reads - reads <= 8 and f.probes - probes <= 8, "per-turn bounded receive probes/reads")
		check(f.read_bytes - read_bytes <= 8 * 98304, "per-turn bounded bytes")
		for _, message in messages do check(#message.body == 65536, "maximum body delivered unchanged"); check(f.spawn.ack(message), "maximum body ACK fits") end
		reads, probes = f.reads, f.probes
		check(f.orch.settle(4) == 4 and f.reads - reads <= 12 and f.probes - probes <= 12, "per-turn bounded settlement")
		local drain_fallback = request("drain-general", body); drain_fallback.priority = "settlement"
		receipt, err = f.orch.send(drain_fallback)
		check(receipt == nil, "unretired ACKs exclude just-settled slots"); code(err, "backpressure", "ACK retirement")
		poll(f.spawn)
		check(assert(f.orch.send(drain_fallback)).slot == 1, "settlement falls back to retired general slots when reserve occupied")
		for _, bad in { 0, -1, 5, 1.5, "4", false } do
			local result, receive_error = f.spawn.receive(bad)
			check(#result == 0, "invalid receive budget rejected"); code(receive_error, "invalid_limit", "receive cap")
			local count, settle_error = f.orch.settle(bad)
			check(count == 0, "invalid settle budget rejected"); code(settle_error, "invalid_limit", "settle cap")
		end
		local idle = fixture(); writes = idle.writes
		local mkdirs = idle.mkdirs
		for _ = 1, 12 do poll(idle.orch, 12); settle(idle.orch); idle.orch.status() end
		check(idle.writes == writes and idle.mkdirs == mkdirs and idle.removes == 0, "empty idle pump performs zero mutations")
		local sparse = fixture()
		local callback = request("sparse-drain"); callback.priority = "settlement"
		check(assert(sparse.orch.send(callback)).slot == 23, "reserve allocation does not depend on general occupancy")
		reads, probes = sparse.reads, sparse.probes
		local sparse_messages = sparse.spawn.receive(4)
		check(#sparse_messages == 1 and sparse_messages[1].slot == 23,
			"empty fixed slots do not delay reserved traffic across timer turns")
		check(sparse.reads - reads <= 8 and sparse.probes - probes <= 52, "sparse scans are bounded without directory listing")
		check(sparse.spawn.ack(sparse_messages[1]), "sparse callback durably acknowledged")
		check(sparse.orch.settle(4) == 1, "sparse far-slot ACK settles in one call")
		sparse.spawn.receive(4)
		check(sparse.files[sparse.ackpath("spawn", "orchplus", 23)] == nil, "sparse far-slot ACK retires in one call")
		local waiting = fixture()
		for index = 1, 8 do assert(waiting.orch.send(request("acked-" .. tostring(index)))) end
		for _ = 1, 2 do
			for _, message in waiting.spawn.receive(4) do check(waiting.spawn.ack(message), "seed verified unsettled ACK pair") end
		end
		for index = 23, 24 do
			local drain = request("acked-drain-" .. tostring(index)); drain.priority = "settlement"
			check(assert(waiting.orch.send(drain)).slot == index, "seed acknowledged reserve")
			local delivered = waiting.spawn.receive(1)
			check(#delivered == 1 and delivered[1].slot == index, "position cursor across acknowledged reserve")
			check(waiting.spawn.ack(delivered[1]), "cache verified reserve ACK pair")
		end
		check(assert(waiting.orch.send(request("new-behind-acks"))).slot == 9, "new frame follows ACKed but unsettled general slots")
		reads = waiting.reads
		local fresh = waiting.spawn.receive(1)
		check(#fresh == 1 and fresh[1].id == "new-behind-acks",
			"verified ACKed pairs do not consume new-message receive budget")
		check(waiting.reads - reads == 1, "verified immutable ACK pairs require no repeated body reads")
	end

	if section == nil or section == "drain" then
		local f = fixture()
		for index = 1, 22 do
			assert(f.orch.send(request("ordinary-" .. tostring(index))))
			assert(f.spawn.send(request("execution-" .. tostring(index), "retained execution", "orchplus", "spawn.execution")))
		end
		check(f.orch.send(request("ordinary-overflow")) == nil, "ordinary ORCH burst cannot consume callback reserve")
		check(f.spawn.send(request("execution-overflow", "execution", "orchplus", "spawn.execution")) == nil,
			"retained SPAWN execution burst cannot consume completion reserve")
		local callback = request("effect-callback", "exact native effect result"); callback.priority = "settlement"
		check(assert(f.orch.send(callback)).slot == 23, "callback publishes despite full ordinary ORCH pool")
		local observed = poll(f.spawn)
		local callback_message
		for _, message in observed do if message.id == callback.id then callback_message = message end end
		check(callback_message ~= nil, "bounded pump reaches reserved callback slot")
		local proof = request("consumed-proof", "durably consumed execution", "orchplus", "spawn.source")
		proof.priority = "settlement"
		check(assert(f.spawn.send(proof)).slot == 23, "completion proof publishes despite full retained-execution pool")
		check(f.spawn.ack(callback_message), "callback request ACKed only after completion proof durably sent")
		local projections = poll(f.orch, 12)
		local proof_message
		for _, message in projections do if message.id == proof.id then proof_message = message end end
		check(proof_message ~= nil and #projections == 23, "ORCH receives complete execution burst plus reserved completion proof")
		-- This represents the adapter's durable domain gate, not authorization
		-- granted by the carrier: execution is deliberately unACKed until proof.
		check(f.orch.ack(proof_message), "durably handled completion proof ACKed")
		for _, message in projections do
			if message.route == "spawn.execution" then check(f.orch.ack(message), "consumed proof releases exact retained execution") end
		end
		check(settle(f.spawn) == 23 and settle(f.orch) == 1, "reserved completion breaks bidirectional saturation and drains")
		poll(f.orch, 12); poll(f.spawn)
		check(assert(f.spawn.send(request("next-execution", "next", "orchplus", "spawn.execution"))).slot == 1,
			"settled ACK retirement restores ordinary capacity")
	end
	if section == nil or section == "retirement" then
		local f = fixture()
		local clear, err = f.spawn.quiescent("orchplus", { "ep:lane", "ep:other" })
		check(err == nil and clear["ep:lane"] and clear["ep:other"], "empty fixed transport is observationally clear")
		local writes, removes = f.writes, f.removes
		assert(f.orch.send(request("unreceived", "opaque domain request", "spawn", "spawn.request", "ep:lane:authorize:boot")))
		clear = f.spawn.quiescent("orchplus", { "ep:lane", "ep:other" })
		check(not clear["ep:lane"] and clear["ep:other"], "unreceived incoming action suffix blocks only its binding family")
		check(f.writes == writes + 1 and f.removes == removes, "drain query performs no mutations or ACKs")
		local message = f.spawn.receive(4)[1]
		check(f.spawn.ack(message), "domain caller handles request before retirement")
		check(settle(f.orch) == 1, "producer data removed after exact ACK")
		clear = f.spawn.quiescent("orchplus", { "ep:lane" })
		check(not clear["ep:lane"], "local ACK-only obligation prevents retirement")
		clear = f.orch.quiescent("spawn", { "ep:lane" })
		check(not clear["ep:lane"], "peer ACK-only obligation prevents producer retirement")
		f.spawn.receive(4)
		clear = f.spawn.quiescent("orchplus", { "ep:lane" })
		check(clear["ep:lane"], "binding clears only after transport ACK cleanup")
		assert(f.spawn.send(request("outgoing", "result", "orchplus", "spawn.response", "ep:lane")))
		clear = f.spawn.quiescent("orchplus", { "ep:lane", "ep:lan" })
		check(not clear["ep:lane"] and clear["ep:lan"], "exact outgoing binding blocks; textual non-colon prefix does not")
		local projected = f.orch.receive(4)[1]
		check(f.orch.ack(projected), "peer durably handles outgoing response")
		check(settle(f.spawn) == 1, "own outgoing file settles")
		clear = f.spawn.quiescent("orchplus", { "ep:lane" })
		check(not clear["ep:lane"], "outgoing peer ACK remains an obligation")
		f.orch.receive(4)
		clear = f.spawn.quiescent("orchplus", { "ep:lane" })
		check(clear["ep:lane"], "both directions fully drained")
		assert(f.orch.send(request("usage-only", "read", "usage", "usage.capacity.request", "ep:lane")))
		clear = f.orch.quiescent("spawn", { "ep:lane" })
		check(clear["ep:lane"], "known valid data for another fixed peer is not a SPAWN obligation")
		for _, bad in { {}, { "ep:lane", "ep:lane" }, { [2] = "ep:lane" }, { "../lane" }, { [65] = "ep:lane" },
			{ path = "ep:lane" }, { string.rep("x", 161) } } do
			local before = f.probes
			clear, err = f.spawn.quiescent("orchplus", bad)
			check(clear == nil and f.probes == before, "invalid binding query fails before filesystem access")
			code(err, "invalid_request", "retirement schema")
		end
		clear, err = f.spawn.quiescent("usage", { "ep:lane" })
		check(clear == nil, "quiescence cannot inspect a nonpeer"); code(err, "invalid_request", "retirement peer")
		f = fixture()
		f.files[f.path("orchplus", 24)] = '{"v":1'
		clear, err = f.spawn.quiescent("orchplus", { "ep:lane", "ep:other" })
		check(not clear["ep:lane"] and not clear["ep:other"], "unclassifiable remote partial makes whole batch conservatively busy")
		code(err, "incomplete_frame", "retirement partial")
		check(f.writes == 0 and f.removes == 0, "query cannot destructively repair partial files")
		f = fixture()
		f.files[f.ackpath("orchplus", "spawn", 24)] = "partial ACK"
		clear, err = f.spawn.quiescent("orchplus", { "ep:lane" })
		check(not clear["ep:lane"], "unknown peer ACK blocks clear observation"); code(err, "invalid_ack", "retirement ACK")
		f = fixture()
		f.files[f.path("spawn", 24)] = { kind = "symlink" }
		clear, err = f.spawn.quiescent("orchplus", { "ep:lane" })
		check(not clear["ep:lane"], "unreadable own file cannot prove retirement"); code(err, "unreadable_frame", "retirement IO")
		f = fixture()
		local roots = {}; for index = 1, 64 do roots[index] = "ep:lane-" .. tostring(index) end
		local probes, reads = f.probes, f.reads
		clear = f.spawn.quiescent("orchplus", roots)
		check(f.probes - probes == 96 and f.reads == reads, "64 lane roots share one fixed 96-path empty scan")
		for _, binding in roots do check(clear[binding], "each absent requested family observed independently") end
		-- A clear observation is not an exclusion lock or domain-inert proof:
		assert(f.orch.send(request("arrives-later", "late event", "spawn", "spawn.request", roots[1] .. ":result")))
		check(clear[roots[1]], "returned observation is a value, not an authority lease")
		local later = f.spawn.quiescent("orchplus", { roots[1] })
		check(not later[roots[1]], "subsequent arrival is observed; caller must independently reject late domain effects")
		f = fixture()
		f.orch = f.open("orchplus", string.rep("o", 80))
		local maximum_body = string.rep("\255", 65536)
		for index = 1, 13 do
			local id = string.rep("i", 75) .. string.format("%05d", index)
			assert(f.orch.send(request(id, maximum_body, "usage", "usage.capacity.request", "other:" .. string.rep("b", 154))))
		end
		local acknowledged = 0
		for _ = 1, 2 do
			for _, message in f.usage.receive(4) do
				if acknowledged < 6 then check(f.usage.ack(message), "maximum valid frame has complete exact ACK"); acknowledged += 1 end
			end
		end
		reads = f.reads
		local read_bytes = f.read_bytes
		local candidates = { "ep:lane", "ep:other" }
		for index = 3, 64 do table.insert(candidates, "ep:candidate-" .. tostring(index)) end
		clear, err = f.orch.quiescent("usage", candidates)
		check(not clear["ep:lane"] and not clear["ep:other"], "budget exhaustion is unknown, never absent")
		code(err, "observation_budget", "retirement bounded reads")
		check(f.reads - reads == 12, "batch observation stops before a thirteenth body read")
		check(f.read_bytes - read_bytes > 12 * 87000 and f.read_bytes - read_bytes <= 12 * 98304,
			"retirement budget covers maximum-size bodies, identities and exact ACK frames")
		for _, binding in candidates do check(clear[binding] == false, "all 64 candidates remain unknown at maximum-frame budget") end
	end

	if section == nil or section == "ack_observation" then
		local f = fixture()
		local sent = assert(f.orch.send(request("callback", "exact callback\r\nbytes", "spawn", "spawn.request", "ep:lane:result:boot")))
		local message = f.spawn.receive(4)[1]
		local restored = native.json.decode(native.json.encode(message))
		local writes, removes = f.writes, f.removes
		local observed, err = f.spawn.acknowledged(restored)
		check(not observed and err == nil, "pending inbound message has no ACK proof")
		check(f.writes == writes and f.removes == removes, "observation never ACKs or deletes")
		observed, err = f.spawn.acknowledged(sent)
		check(not observed, "send receipt lacks original inbound identity/body"); code(err, "invalid_receipt", "restored ACK schema")
		check(f.spawn.ack(message), "domain handling explicitly creates durable transport ACK")
		writes, removes = f.writes, f.removes
		local reads = f.reads
		observed, err = f.spawn.acknowledged(restored)
		check(observed and err == nil and f.reads - reads == 2, "exact restored message observes ACK plus original data with two bounded reads")
		check(f.writes == writes and f.removes == removes, "positive observation is read-only")
		for _, change in {
			{ recipient = "orchplus" }, { peer = "usage" }, { slot = 0 }, { slot = 25 }, { slot = 1.5 },
			{ route = "spawn.response" }, { binding = "../lane" }, { incarnation = "" }, { id = "" },
			{ body = string.rep("x", 65537) }, { authorized = true },
		} do
			local invalid = table.clone(restored); for key, value in change do invalid[key] = value end
			local probes = f.probes
			observed, err = f.spawn.acknowledged(invalid)
			check(not observed and f.probes == probes, "invalid restored receipt rejected before filesystem access")
			code(err, "invalid_receipt", "closed restored receipt")
		end
		for _, change in {
			{ id = "different" }, { incarnation = "different-boot" }, { binding = "ep:other" }, { body = "different exact bytes" },
		} do
			local changed = table.clone(restored); for key, value in change do changed[key] = value end
			observed, err = f.spawn.acknowledged(changed)
			check(not observed, "existing ACK cannot attest another full message identity")
			code(err, "conflicting_ack", "exact ACK identity")
		end
		local data_path = f.path("orchplus", 1)
		local original = f.files[data_path]
		f.files[data_path] = "conflicting replacement"
		observed, err = f.spawn.acknowledged(restored)
		check(not observed, "matching ACK does not hide conflicting present producer data")
		code(err, "conflict", "producer data identity")
		f.files[data_path] = original
		check(settle(f.orch) == 1, "producer may remove data before receiver records its domain ACK fence")
		local reloaded = f.open("spawn", "spawn-after-reload")
		observed, err = reloaded.acknowledged(restored)
		check(observed and err == nil, "ACK-only exact evidence survives receiver reload before first receive")
		local acknowledged_capability = reloaded.ack(restored)
		check(not acknowledged_capability, "read-only observation never recreates a receive/ack capability")
		local ack_path = f.ackpath("spawn", "orchplus", 1)
		local complete_ack = f.files[ack_path]
		f.files[ack_path] = complete_ack:sub(1, #complete_ack - 1)
		observed, err = reloaded.acknowledged(restored)
		check(not observed and err ~= nil, "partial ACK is not evidence")
		f.files[ack_path] = { kind = "symlink" }
		observed, err = reloaded.acknowledged(restored)
		check(not observed, "nonregular ACK cannot prove handling"); code(err, "unreadable_frame", "ACK native read")
		f.files[ack_path] = complete_ack
		-- The adapter must persist the positive fence before making this call.
		check(reloaded.acknowledged(restored), "positive pre-cleanup observation remains available")
		reloaded.receive(4)
		observed, err = reloaded.acknowledged(restored)
		check(not observed and err == nil and f.files[ack_path] == nil,
			"ACK cleanup/absence never turns into a positive proof")
		local newer_producer = f.open("orchplus", "orchplus-new-incarnation")
		check(assert(newer_producer.send(request("callback", "exact callback\r\nbytes", "spawn", "spawn.request", "ep:lane:result:boot"))).slot == 1,
			"settled slot reused by a new producer incarnation")
		local newer_message = reloaded.receive(4)[1]
		check(reloaded.ack(newer_message), "new incarnation gets its own exact ACK")
		observed, err = reloaded.acknowledged(restored)
		check(not observed, "reused slot ACK cannot attest identical bytes from a foreign incarnation")
		code(err, "conflicting_ack", "slot reuse incarnation")
		check(reloaded.acknowledged(table.clone(newer_message)), "new exact restored incarnation observes its own ACK")
		f.files[ack_path] = complete_ack
		observed, err = reloaded.acknowledged(restored)
		check(not observed, "delayed old ACK cannot hide a valid newer frame in the same slot")
		code(err, "conflict", "delayed ACK slot reuse")
	end

	return "PASS channel " .. tostring(checks) .. " checks" .. (if section then " (" .. section .. ")" else "")
end
