--!strict
local root = ...
assert(type(root) == "string")
local environment = getfenv()
local files: any = {}
local writes = 0
local config_path = "/work-data/config.json"
local config_chunk = assert(loadstring(tern.fs.read(root .. "/config.luau"), "work-config"))
local config = config_chunk()
local projects_chunk = assert(loadstring(tern.fs.read(root .. "/projects.luau"), "work-projects"))
setfenv(projects_chunk, setmetatable({
	tern = {
		json = tern.json, plugin = { data = "/work-data" }, runtime = { os = "linux" },
		fs = {
			exists = function(path) return files[path] ~= nil end,
			read = function(path, maximum) local bytes = assert(files[path]); assert(#bytes <= maximum); return bytes end,
			write = function(path, bytes) writes += 1; files[path] = bytes end,
		},
	},
	require = function(name) assert(name == "./config"); return config end,
}, { __index = environment }))
local persisted_projects = projects_chunk()
local catalog: any = { root = "/host/glitch", items = { { id = "project", name = "project", path = "/host/glitch/workspaces/project" } } }
local projects = {
	load = function(context) assert(context == true); return catalog, nil end,
	load_plans = function() return { items = { { path = "/host/glitch/plans/work.md", title = "Work", workspace_id = "project" } }, rejected = {} } end,
	find = function(current, id) for _, item in ipairs(current.items) do if item.id == id then return item end end; return nil end,
	empty = function() return { items = {} } end,
	root_snapshot = persisted_projects.root_snapshot,
	configure_root = persisted_projects.configure_root,
}
local host = { json = tern.json, ui = tern.ui }
local edit_chunk = assert(loadstring(tern.fs.read(root .. "/text_edit.luau"), "work-text-edit"))
local text_edit = edit_chunk()
assert(text_edit.apply("😀", { len = 2, from = 1, to = 2, text = "x", cursor = 2 }, 4096) == nil, "native edit cannot split a surrogate pair")
assert(text_edit.apply("雪", { len = 1, from = 0, to = 1, text = "é", cursor = 2 }, 4096) == nil, "native caret outside the updated UTF16 text is rejected")
local chunk = assert(loadstring(tern.fs.read(root .. "/orchestration.luau"), "work-orchestration"))
setfenv(chunk, setmetatable({ tern = host, require = function(name) if name == "./text_edit" then return text_edit end; assert(name == "./projects"); return projects end }, { __index = environment }))
local selection = chunk()
local request = { mode = "orchestration", form_nonce = "nonce-1", request_id = "request-1", source = { pane = "7", host = "host", window = "", session = "session" }, revision = 3 }
local bytes = tern.json.encode(request)
local state = assert(selection.new({ bytes }, nil))
local context_node = selection.context_node(state)
assert(context_node.p.key == "orch-context" and context_node.p.role == "work.orch.context" and context_node.p.hidden == true, "choosing WORK pane publishes a hidden machine-mode frame before selection")
local foreign = { mode = "orchestration", form_nonce = "other", request_id = "other", source = request.source, revision = request.revision }
selection.event(state, { ev = "action", act = "orch-open", value = tern.json.encode(foreign) }, {})
assert(state.request.request_id == "request-1" and state.result == nil, "a busy choosing request cannot be replaced")
local cx = { frame = function() end }
local function act(kind, value)
	selection.view(state)
	for token, entry in pairs(state.actions) do
		if entry.kind == kind and (value == nil or entry.value == value) then selection.event(state, { ev = "action", act = kind, value = token }, cx); return end
	end
	error("action absent: " .. kind)
end
state.query = "A😀雪Z"
selection.event(state, { ev = "edit", id = "main.orch-search", from = 1, to = 4, text = "é", cursor = 2, len = 5 }, cx)
assert(state.query == "AéZ" and state.cursor == 3, "native selection replacement converts UTF16 offsets to byte caret")
selection.event(state, { ev = "edit", id = "main.orch-search", from = 0, to = 3, text = "stale", cursor = 5, len = 5 }, cx)
assert(state.query == "AéZ", "stale edit lengths cannot replace newer field text")
selection.event(state, { ev = "undo", id = "main.orch-search" }, cx)
assert(state.query == "A😀雪Z", "native undo restores the Unicode draft")
state.query = ""
act("orch-plan", "/host/glitch/plans/work.md")
act("orch-submit")
assert(state.result.phase == "selected" and state.result.selection_revision == 1)
assert(state.result.source_locator == "/host/glitch/plans/work.md" and state.result.workspace_id == "project")
selection.event(state, { ev = "action", act = "orch-selection-ack", value = tern.json.encode({ form_nonce = "wrong", request_id = "request-1", selection_revision = 1, outcome = "success" }) }, cx)
assert(state.result.phase == "selected", "foreign ACK must not settle selection")
selection.event(state, { ev = "action", act = "orch-selection-ack", value = tern.json.encode({ form_nonce = "nonce-1", request_id = "request-1", selection_revision = 1, outcome = "success" }) }, cx)
assert(state.result.phase == "accepted" and state.outcome == "success")
local saved = { orchestration = selection.save(state) }
state = assert(selection.new({ bytes }, saved))
assert(state.result.phase == "accepted", "reload retains the once-only tombstone")
selection.event(state, { ev = "action", act = "orch-open", value = bytes }, cx)
assert(state.result.phase == "accepted", "same request cannot be accepted twice")
request.form_nonce, request.request_id = "nonce-2", "request-2"
selection.event(state, { ev = "action", act = "orch-open", value = tern.json.encode(request) }, cx)
assert(state.result == nil and state.request.request_id == "request-2")
state = assert(selection.new({ bytes }, { orchestration = selection.save(state) }))
assert(state.request.request_id == "request-2", "reused panel reload must not restore its original launch request")
act("orch-workspace", "project")
catalog = { root = "/host/glitch", items = {} }
act("orch-submit")
assert(state.result == nil, "removed registry entry cannot return a selection")
assert(selection.new({ "{}" }, nil) == nil, "malformed launch context is rejected")
catalog = { items = {} }
state = assert(selection.new({ bytes }, nil))
assert(state.root_setup == true and state.request.form_nonce == "nonce-1")
selection.view(state)
local save_action = false
for _, entry in pairs(state.actions) do if entry.kind == "orch-root-save" then save_action = true end end
assert(save_action, "clean installed WORK exposes usable in-pane root setup")
selection.event(state, { ev = "edit", id = "main.orch-root", from = 0, to = 0, text = "/host/雪", cursor = 7, len = 0 }, cx)
local retained_setup = { orchestration = selection.save(state) }
local external_config = tern.json.encode({ glitch_root = "/external/glitch", agent = { kind = "acp", argv = { "actual-agent" } } })
files[config_path] = external_config
state = assert(selection.new({ bytes }, retained_setup))
assert(state.root == "/host/雪" and state.root_setup and state.request.request_id == "request-1", "root setup retains its draft and original request across reload")
act("orch-root-save")
assert(writes == 0 and files[config_path] == external_config and state.root_setup, "reload must not rebase an old root draft onto external configuration edits")
assert(state.root_expected.exists == false, "reload preserves the original expected snapshot")
act("orch-refresh")
assert(state.root_expected.text == external_config and state.root == "/host/雪" and state.request.request_id == "request-1", "only explicit Refresh rebases configuration while preserving draft and request")
act("orch-cancel")
assert(state.result.phase == "cancelled" and state.result.workspace_id == nil and state.result.source_locator == nil, "Back returns only bounded cancellation identity, not work")
selection.event(state, { ev = "action", act = "orch-selection-ack", value = tern.json.encode({ form_nonce = "nonce-1", request_id = "request-1", selection_revision = 1, outcome = "cancelled" }) }, cx)
assert(state.result.phase == "accepted" and state.cancelled and state.outcome == "cancelled", "cancel settlement never becomes success")
selection.view(state)
local standalone_action = false
for _, entry in pairs(state.actions) do if entry.kind == "orch-standalone" then standalone_action = true end end
assert(standalone_action, "settled cancellation leaves usable WORK navigation")
assert(selection.new({ bytes }, { mode = "standalone" }) == nil, "returning to standalone persists across reload despite original orchestration launch args")
state = assert(selection.new({ bytes }, nil))
state.result = { phase = "selected", selection_revision = 1 }
selection.event(state, { ev = "action", act = "orch-selection-ack", value = tern.json.encode({ form_nonce = "nonce-1", request_id = "request-1", selection_revision = 1, outcome = "refused", message = "Plan import was refused." }) }, cx)
assert(state.result.phase == "accepted" and state.outcome == "refused", "failed import settles without asserting success")
return true
