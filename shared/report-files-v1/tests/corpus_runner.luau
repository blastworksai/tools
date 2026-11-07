-- Exact bytes, including malformed UTF-8, come from the maintained shared corpus.
local root, consumer, case_id = ...
local environment, modules = getfenv(), {}
local function load(name, base)
	name = (base or "") .. name:gsub("^%./", "")
	if modules[name] then return modules[name] end
	local chunk = assert(loadstring(tern.fs.read(root .. "/" .. name .. ".luau"), name))
	local dir = name:match("^(.*/)")
	setfenv(chunk, setmetatable({ require = function(n) return load(n, dir) end }, { __index = environment }))
	local value = chunk(); modules[name] = value; return value
end
local codec = load(consumer)
local corpus = tern.json.decode(tern.fs.read(tern.plugin.dir .. "/corpus.json"))
local case
for _, entry in corpus.cases do if entry.id == case_id then case = entry; break end end
assert(case, "unknown corpus case " .. tostring(case_id))
local binding = case.binding or corpus.binding
local function bytes(encoded) return tern.base64.decode(encoded) end
local function restore(state) return tern.json.decode(tern.json.encode(state)) end
local value, diagnostic
if case.op == "assembly" then
	local raw = bytes(case.manifest_b64)
	local state
	state, diagnostic = codec.assembly_start(raw, case.manifest_sha256 or codec.sha256(raw), binding)
	value = state
	if state then
		for ordinal, index in case.pushes do
			local chunk = bytes(case.chunks_b64[index])
			local override = case.chunk_sha256 and (case.chunk_sha256[tostring(index)] or case.chunk_sha256[index])
			value, diagnostic = codec.assembly_push(state, chunk, override or codec.sha256(chunk), binding)
			if not value then break end
			if case.restore_after == ordinal then state = restore(state) end
		end
	end
elseif case.op == "frame" then
	local raw = bytes(case.bytes_b64)
	value, diagnostic = codec.frame(raw, case.direction or "report", binding)
	if value then
		local state = assert(codec.assembly_start(value.manifest, codec.sha256(value.manifest), binding))
		for _, chunk in value.chunks do
			local pushed, why = codec.assembly_push(state, chunk, codec.sha256(chunk), binding)
			assert(pushed, why and why.code)
			state = restore(state)
			if pushed.complete then assert(pushed.bytes == raw, "roundtrip changed exact bytes") end
			value = pushed
		end
		assert(value.complete, "framed message never completed")
	end
else
	local raw = bytes(case.bytes_b64)
	if case.op == "strict_decode" then value, diagnostic = codec.strict_decode(raw, case.maximum)
	elseif case.op == "decode_report" or case.op == "decode_reply" then value, diagnostic = codec[case.op](raw, binding)
	elseif case.op == "decode_object" or case.op == "decode_manifest" then value, diagnostic = codec[case.op](raw)
	elseif case.op == "decode_page" then value, diagnostic = codec.decode_page(raw, case.selector)
	else error("unsupported corpus op " .. tostring(case.op)) end
end
assert((value ~= nil) == case.expect.ok, case.id .. ": unexpected acceptance; " .. tostring(diagnostic and diagnostic.code))
if case.expect.code then
	local got = if diagnostic then diagnostic.code elseif value then value.code else nil
	local allowed = corpus.diagnostics[case.expect.code]
	assert(got == case.expect.code or allowed and table.find(allowed.luau, got), case.id .. ": diagnostic " .. tostring(got))
end
if case.expect.completed_bytes_b64 then
	assert(value == nil and diagnostic and diagnostic.completed_bytes == bytes(case.expect.completed_bytes_b64),
		case.id .. ": rejected complete bytes were not retained exactly")
end
return "shared/" .. consumer .. "/" .. case.id .. ": 1 checks passed"
