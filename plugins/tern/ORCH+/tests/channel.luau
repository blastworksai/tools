-- Native harness group channel[/paths|delivery|framing|recovery|bounds|drain|retirement|ack_observation].
-- Run the actual vendored carrier; canonical behavior source is shared, not a
-- second implementation. The injected disk never touches real plugin data.
local root, section = ...
assert(type(root) == "string" and root ~= "", "pass plugin source root")
local function load(path, name)
	local chunk = assert(loadstring(tern.fs.read(path, 65536), name))
	setfenv(chunk, setmetatable({}, { __index = getfenv() }))
	return chunk()
end
local Channel = load(root .. "/channel/channel.luau", "channel/channel")
local run = load(root .. "/../../../shared/plugin-channel-v1/tests/carrier.luau", "shared/channel-tests")
return run(Channel, tern, section)
