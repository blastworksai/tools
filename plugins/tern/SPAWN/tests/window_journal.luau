-- Native journal/host migration boundaries; all storage and process results are deterministic.
local root = ...
local runtime, environment = tern, getfenv()
local source = runtime.fs.read(root .. '/window_journal.luau')
local codec = assert(loadstring(runtime.fs.read(root .. '/wire/codec.luau'), 'codec'))()
local checks = 0
local function check(value, message) assert(value, message); checks += 1 end
local function clone(value)
 if type(value) ~= 'table' then return value end
 local out = {}; for key, item in pairs(value) do out[key] = clone(item) end; return out
end
local function equal(a, b)
 if type(a) ~= type(b) then return false end
 if type(a) ~= 'table' then return a == b end
 for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
 for key in pairs(b) do if a[key] == nil then return false end end
 return true
end
-- Older production lacks capture; passing nil still exercises its existing open
-- behavior, so before/after failures concern deletion rather than a missing API.
local function capture(journal) return if journal.capture then journal.capture() else nil end
local function world(data)
 data = data or '/fixture/native-data/spawn'
 local w = { data = data, files = {}, dirs = {}, kv = {}, deleted = {}, writes = 0, generated = 0 }
 local function owned(path)
  assert(path:sub(1, #data + 1) == data .. '/', 'journal operation escaped native plugin data: ' .. path)
 end
 local function mkdir(path)
  owned(path)
  w.dirs[path] = true
  local parent = path:match('^(.*)/[^/]+$')
  if parent and #parent > #data then mkdir(parent) end
 end
 local function list(path)
  assert(w.dirs[path], 'not a fixture directory: ' .. path)
  if w.unreadable == path then error('unreadable directory') end
  local seen, result = {}, {}
  for _, entries in ipairs({w.files, w.dirs}) do
   for entry in pairs(entries) do
    if entry:sub(1, #path + 1) == path .. '/' then
     local name = entry:sub(#path + 2):match('^[^/]+')
     if not seen[name] then seen[name] = true;table.insert(result, name) end
    end
   end
  end
  table.sort(result);return result
 end
 local fake = { context = 'host', json = runtime.json, plugin = { data = data, dir = '/fixture/linked-source/SPAWN' },
  fs = { exists = function(path) return w.files[path] ~= nil or w.dirs[path] == true end, mkdir = mkdir, list = list,
   read = function(path) if w.unreadable == path then error('unreadable file') end;return assert(w.files[path], 'missing ' .. path) end,
   remove = function(path)
    owned(path)
    if w.fail_cleanup then error('interrupted migration cleanup') end
    for _, entries in ipairs({w.files, w.dirs}) do
     for key in pairs(entries) do if key == path or key:sub(1, #path + 1) == path .. '/' then entries[key] = nil end end
    end
   end,
   write = function(path, bytes)
    owned(path)
    w.writes += 1
    if w.fail_write == w.writes then error('interrupted native write') end
    w.files[path] = if w.corrupt_journal and path:sub(-14) == '/observer.json' then '{}' else bytes
   end },
  kv = { get = function(key) return clone(w.kv[key]) end,
   set = function(key, value)
    assert(value == nil, 'migration only deletes KV')
    if w.fail_delete == key then error('interrupted legacy delete') end
    table.insert(w.deleted, key); w.kv[key] = clone(value)
   end } }
 -- Separate VM module instances share only the native disk model.
 function w.load(context)
  local vm = setmetatable({ context = context }, { __index = fake })
  local chunk = assert(loadstring(source, 'window_journal'))
  setfenv(chunk, setmetatable({ tern = vm, require = function(name) assert(name == './wire/codec');return codec end }, { __index = environment }))
  return chunk()
 end
 w.host = w.load('host')
 function w.initialize()
  return w.host.host_initialize(function() w.generated += 1; return 'ns' end)
 end
 return w
end
local function inspect(window, conn, since)
 return { status = 0, timed_out = false, stdout = runtime.json.encode({ clients = {
  { kind = 'terminal', window = window, conn = 999, since = 999 },
  { kind = 'window', window = window, conn = conn, since = since },
 } }) }
end
local function legacy(w, count)
 w.kv['window-observer-namespace'] = 'ns'
 local index = {}
 for i = 1, count do
  local id = 'window-ns-' .. i .. '-' .. (100 + i) .. '-same/window:CON.'
  local key = 'window-observer:' .. id
  index[key] = { window = 'same/window:CON.', saved = i }
  w.kv[key] = { version = 2, id = id, next_run = i,
   transports = { authority = { sequence = i, acknowledgments = { 'ack' .. i }, pending = { request_id = 'request' .. i, op = 'launch_record' } } },
   tracked = { live = { allocation_intent = true, attempt = { phase = 'Unknown' }, job = { ticket = 'ticket' .. i } } },
   setup = { id = 'setup' .. i, ticket = 'setup-ticket' .. i, reviewing = true },
   restart_notices = { session = 'restart' .. i }, extension = { preserve = true } }
 end
 w.kv['window-observer-index:ns'] = index
 w.kv['spawn.records-seen.v1'] = { host = 7 }
 w.kv['spawn.intents.v1'] = { 'already-started' }
 return clone(w.kv)
end
local cold = world()
local window = cold.load('window')
check(window.open('win', inspect('win', 1, 1)) == nil and cold.generated == 0 and next(cold.files) == nil,
 'a window never fabricates a missing HOST namespace')
check(window.host_initialize(function() error('must not call') end) == nil, 'window cannot invoke HOST migration')
check(cold.initialize() == 'ns' and cold.generated == 1, 'HOST creates one native namespace')
check(cold.initialize() == 'ns' and cold.generated == 1, 'HOST reload preserves the namespace')
local handle = assert(window.open('win', inspect('win', 1, 1)))
handle.observer.transports.authority = { sequence = 9, acknowledgments = { 'a' }, pending = { request_id = 'p', op = 'launch_record' } }
handle.observer.tracked = { unresolved = { phase = 'Unknown' } }
handle.observer.setup = { id = 'setup', imported = false }
handle.observer.restart_notices = { session = 'restart' }
window.save(handle, handle.observer)
window.save_cache(handle, 'spawn.records-seen.v1', { host = 3 })
window.save_cache(handle, 'spawn.intents.v1', { 'intent' })
local reload = cold.load('window')
local restored = assert(reload.open('win', inspect('win', 1, 1)))
check(equal(restored.observer, handle.observer), 'window reload preserves complete v2 observer content')
check(reload.cache(restored, 'spawn.records-seen.v1').host == 3 and reload.cache(restored, 'spawn.intents.v1')[1] == 'intent', 'both window caches persist outside KV')
local replacement = assert(reload.open('win', inspect('win', 2, 2)))
check(replacement.path ~= restored.path and next(replacement.observer.transports) == nil, 'reused positional key cannot inherit an older incarnation')
check(equal(assert(reload.open('win', inspect('win', 1, 1))).observer, handle.observer), 'old unresolved incarnation is retained')
for _, key in ipairs({ '', '.', '..', 'CON', 'con', 'NUL.', 'a/b', 'a\\b', 'a:b', 'a b', string.rep('w', 160) }) do
 local h = assert(reload.open(key, inspect(key, 1, 1)))
 for part in h.path:gmatch('[^/]+') do check(#part <= 121 and part ~= '..' and not part:find('[:\\ ]'), 'filename component is bounded and safe on POSIX/Windows') end
end
check(assert(reload.open('CON', inspect('CON', 1, 1))).path ~= assert(reload.open('con', inspect('con', 1, 1))).path,
 'encoding preserves opaque case on case-insensitive filesystems')
for _, result in ipairs({ { status = 1, stdout = '{}' }, { status = 0, timed_out = true, stdout = '{}' },
 { status = 0, stdout_truncated = true, stdout = '{}' }, { status = 0, stdout = '{' },
 { status = 0, stdout = runtime.json.encode({ complete = false, clients = {} }) },
 { status = 0, stdout = runtime.json.encode({ clients = { { kind = 'window', window = 'win', conn = 1 } } }) },
 { status = 0, stdout = runtime.json.encode({ clients = { { kind = 'window', window = 'win', conn = 1, since = 1 }, { kind = 'window', window = 'win', conn = 2, since = 2 } } }) },
}) do check(reload.open('win', result) == nil, 'incomplete/ambiguous native identity never falls back to positional identity') end
local unused = world()
local unusedBefore = legacy(unused, 2)
local unusedKey = 'window-observer:window-ns-1-101-same/window:CON.'
unused.kv[unusedKey] = nil -- Legacy initialization publishes the index before its first save.
check(unused.initialize() == 'ns', 'an indexed but never-saved legacy window can upgrade')
local unusedHandle = assert(unused.load('window').open('same/window:CON.', inspect('same/window:CON.', 1, 101)))
check(equal(unusedHandle.observer, { version = 2, id = unusedKey:sub(17), transports = {}, tracked = {}, next_run = 1 }),
 'unused legacy window retains the old initial journal contract')
check(unused.host.cache(unusedHandle, 'spawn.intents.v1')[1] == 'already-started',
 'migration preserves exclusion markers even when the legacy journal was never saved')
local usedHandle = assert(unused.host.open('same/window:CON.', inspect('same/window:CON.', 2, 102)))
check(equal(usedHandle.observer, unusedBefore['window-observer:window-ns-2-102-same/window:CON.']),
 'an unused window does not discard another window pending launches')
unused.files[unusedHandle.path .. '/observer.json'] = nil
check(unused.host.open('same/window:CON.', inspect('same/window:CON.', 1, 101)) == nil,
 'missing published native journals are still refused rather than reset')
local migrated = world()
local before = legacy(migrated, 12)
check(migrated.initialize() == 'ns' and migrated.generated == 0, 'HOST retains the existing legacy namespace')
for key, value in pairs(before['window-observer-index:ns']) do
 local saved = before[key]
 local conn, since = saved.id:match('window%-ns%-(%d+)%-(%d+)%-')
 local h = assert(migrated.load('window').open(value.window, inspect(value.window, tonumber(conn), tonumber(since))))
 check(equal(h.observer, saved), 'migration preserves each complete unresolved v2 journal beyond eight')
 check(migrated.kv[key] == nil, 'HOST deletes each copied legacy journal after verified read-back')
 check(migrated.host.cache(h, 'spawn.records-seen.v1').host == 7 and migrated.host.cache(h, 'spawn.intents.v1')[1] == 'already-started', 'legacy caches seed incarnation files without losing exclusion evidence')
 check(migrated.files[h.root .. '/index.json'] == nil and migrated.files[h.root .. '/spawn.records-seen.v1.json'] == nil and migrated.files[h.root .. '/spawn.intents.v1.json'] == nil, 'ready migration leaves no namespace-level legacy copies or global seeds')
end
check(next(migrated.kv) == nil, 'all indexed owned KV keys migrate, including namespace and index')
local freshIncarnation = assert(migrated.host.open('same/window:CON.', inspect('same/window:CON.', 99, 199)))
check(next(migrated.host.cache(freshIncarnation, 'spawn.intents.v1')) == nil, 'new incarnations do not resurrect old ordinary seen-ID history')
local cleanup = world(); legacy(cleanup, 12); cleanup.fail_cleanup = true
check(cleanup.initialize() == nil and next(cleanup.kv) == nil, 'cleanup failure remains visible after verified legacy deletion')
check(cleanup.load('window').open('same/window:CON.', inspect('same/window:CON.', 1, 101)) == nil, 'windows wait for migration cleanup, not just KV deletion')
cleanup.fail_cleanup = nil
check(cleanup.initialize() == 'ns', 'interrupted cleanup resumes without needing deleted legacy values')
local cleaned = assert(cleanup.host.open('same/window:CON.', inspect('same/window:CON.', 1, 101)))
check(cleanup.host.cache(cleaned, 'spawn.intents.v1')[1] == 'already-started' and cleanup.files[cleaned.root .. '/index.json'] == nil, 'resumed cleanup preserves current incarnation caches and removes obsolete migration index')
local interrupted = world(); local original = legacy(interrupted, 12)
interrupted.fail_write = 5
local ns, why = interrupted.initialize()
check(ns == nil and why:find('incomplete') ~= nil and #interrupted.deleted == 0 and equal(interrupted.kv, original), 'interrupted copy exposes incomplete migration and deletes no KV')
check(interrupted.load('window').open('same/window:CON.', inspect('same/window:CON.', 1, 101)) == nil, 'windows cannot use partially migrated files')
interrupted.fail_write = nil
check(interrupted.initialize() == 'ns' and next(interrupted.kv) == nil, 'interrupted equal-value copies resume without replacing source values')
local deleting = world(); legacy(deleting, 12)
deleting.fail_delete = 'spawn.intents.v1'
check(deleting.initialize() == nil and #deleting.deleted > 0, 'partial HOST deletion remains an incomplete migration')
check(deleting.load('window').open('same/window:CON.', inspect('same/window:CON.', 1, 101)) == nil, 'deletion phase is not published as complete')
deleting.fail_delete = nil
check(deleting.initialize() == 'ns' and next(deleting.kv) == nil, 'deletion interruption resumes from the retained native index without dropping unresolved journals')
local conflict = world(); legacy(conflict, 1)
conflict.fail_write = 6
check(conflict.initialize() == nil, 'stop after a copied journal before completion')
conflict.fail_write = nil
for path in pairs(conflict.files) do if path:sub(-14) == '/observer.json' then conflict.files[path] = '{}' end end
check(conflict.initialize() == nil and #conflict.deleted == 0, 'unequal native/legacy values never authorize legacy deletion')
local corrupt = world(); local corruptSource = legacy(corrupt, 1); corrupt.corrupt_journal = true
check(corrupt.initialize() == nil and #corrupt.deleted == 0 and equal(corrupt.kv, corruptSource), 'unequal immediate native read-back prevents every legacy deletion')
-- Resume a copying migration whose already-published destination identity is no
-- longer ours/readable. Missing obligations do not authorize repairing that leaf.
for _, fault in ipairs({'conflicting', 'unreadable'}) do
 for _, missing in ipairs({'observer.json', 'spawn.intents.v1.json', 'spawn.records-seen.v1.json'}) do
  local resumed = world()
  local sourceValues = legacy(resumed, 1)
  assert(resumed.initialize() == 'ns')
  local destination = assert(resumed.host.open('same/window:CON.', inspect('same/window:CON.', 1, 101)))
  resumed.kv = clone(sourceValues);resumed.deleted = {}
  resumed.files[destination.root .. '/migration.json'] = runtime.json.encode({phase = 'copying', layout = 'flat-v1'})
  resumed.files[destination.root .. '/index.json'] = runtime.json.encode(sourceValues['window-observer-index:ns'])
  for _, key in ipairs({'spawn.records-seen.v1', 'spawn.intents.v1'}) do
   resumed.files[destination.root .. '/' .. key .. '.json'] = runtime.json.encode(sourceValues[key])
  end
  local identityFile = destination.path .. '/identity.json'
  if fault == 'conflicting' then
   local foreign = runtime.json.decode(resumed.files[identityFile]);foreign.observer_id = 'unrelated-owner'
   resumed.files[identityFile] = runtime.json.encode(foreign)
  else resumed.unreadable = identityFile end
  resumed.files[destination.path .. '/' .. missing] = nil
  local nativeBefore, writesBefore = clone(resumed.files), resumed.writes
  local migrated, diagnostic = resumed.initialize()
  check(migrated == nil and type(diagnostic) == 'string',
   fault .. ' existing identity refuses resumed migration with missing ' .. missing)
  check(resumed.writes == writesBefore and equal(resumed.files, nativeBefore)
   and #resumed.deleted == 0 and equal(resumed.kv, sourceValues),
   fault .. ' identity is checked before any missing ' .. missing .. ' obligation can be copied or any KV deleted')
 end
end
local missingNamespace = world()
missingNamespace.files[missingNamespace.data .. '/window-observer'] = true
check(missingNamespace.initialize() == nil and missingNamespace.generated == 0, 'missing initialized native namespace is not first use and never generates a fallback')
local windows = world('C:/Users/fixture/AppData/Roaming/tern/plugin-data/spawn')
windows.kv['window-observer-namespace'] = 'observer-1730937600-11111111-22222222-33333333'
check(windows.initialize() ~= nil, 'realistic generated HOST namespace initializes without path aliases')
local practical = assert(windows.host.open('0:0', inspect('0:0', 123, 1730937600000)))
local absolute = practical.path .. '/spawn.records-seen.v1.json'
check(#absolute < 260, 'generated namespace and native positional key fit a complete ordinary Windows plugin path, not just per-component limits')
-- Existing open/save/cache calls exercise cleanup as a consumer does; these
-- regressions can run unchanged with frozen R17 production implementations.
local retirement = world();assert(retirement.initialize())
local rw = retirement.load('window')
local handles, liveClients = {}, {}
for i = 1, 14 do
 table.insert(liveClients, { kind = 'window', window = 'retire-' .. i, conn = i, since = 100 + i })
end
local full = { status = 0, stdout = runtime.json.encode({clients = liveClients}) }
for i, client in ipairs(liveClients) do
 local h = assert(rw.open(client.window, full));handles[i] = h
 rw.save(h, h.observer)
 rw.save_cache(h, 'spawn.intents.v1', {})
 rw.save_cache(h, 'spawn.records-seen.v1', {host = 3})
end
handles[4].observer.tracked = {ordinary = {phase = 'Failed', diagnostic = 'preserve ordinary history'}}
rw.save(handles[4], handles[4].observer)
handles[5].observer.transports = {authority = {pending = {request_id = 'unanswered'}}}
rw.save(handles[5], handles[5].observer)
rw.save_cache(handles[6], 'spawn.intents.v1', {'unresolved-legacy-id'})
handles[7].observer.extension = {unknown = true};rw.save(handles[7], handles[7].observer)
retirement.files[handles[8].path .. '/unrecognized.bin'] = 'unrecognized evidence'
retirement.unreadable = handles[9].path .. '/observer.json'
retirement.files[handles[10].path .. '/observer.json'] = '{'
handles[11].observer.version = 99;rw.save(handles[11], handles[11].observer)
handles[12].observer.tracked = {ordinary = {phase = 'Exited', diagnostic = 'preserve exit history'}}
rw.save(handles[12], handles[12].observer)
handles[13].observer.setup = {id = 'unresolved-setup'};rw.save(handles[13], handles[13].observer)
local candidates = capture(rw)
local ended = inspect('retire-14', 14, 114)
local incomplete = clone(ended);incomplete.stdout_truncated = true
check(rw.open('retire-14', incomplete, candidates) == nil, 'truncated inventory cannot retire or open')
for _, h in ipairs(handles) do check(retirement.files[h.path .. '/observer.json'] ~= nil, 'incomplete inventory preserves every incarnation') end
local malformed = clone(ended)
malformed.stdout = runtime.json.encode({clients = {liveClients[14], {kind = 'window', window = 'unknown', conn = 99}}})
rw.open('retire-14', malformed, candidates)
for _, h in ipairs(handles) do check(retirement.files[h.path .. '/observer.json'] ~= nil, 'a malformed non-current client preserves every incarnation') end
assert(rw.open('retire-14', ended, candidates))
for i = 1, 3 do
 check(retirement.files[handles[i].path .. '/observer.json'] == nil and retirement.dirs[handles[i].path] == nil,
  'complete absence retires multiple empty ended incarnation files and leaf directories')
end
for i = 4, 14 do
 check(retirement.files[handles[i].path .. '/observer.json'] ~= nil,
  'live, historical, unresolved, unreadable, unknown-file and unknown-schema incarnations survive')
end
-- New empty lifetimes leave neither files nor per-connection directories behind.
local cycles = world();assert(cycles.initialize());local cw = cycles.load('window')
for i = 1, 12 do
 local prior = capture(cw)
 local h = assert(cw.open('cycling', inspect('cycling', i, i), prior))
 cw.save(h, h.observer);cw.save_cache(h, 'spawn.intents.v1', {})
end
local last = assert(cw.open('cycling', inspect('cycling', 12, 12)))
local children = 0
for path in pairs(cycles.dirs) do if path:sub(1, #last.root + 9) == last.root .. '/windows/' then children += 1 end end
check(children == 1, 'empty ended lifetimes do not accumulate incarnation or connection directories')
local unindexed = world()
unindexed.kv['window-observer-namespace'] = 'ns'
unindexed.kv['spawn.intents.v1'] = {'unindexed-unresolved'}
check(unindexed.initialize() == 'ns', 'unindexed legacy caches migrate without losing exclusions')
local fresh = assert(unindexed.host.open('fresh', inspect('fresh', 1, 1)))
local evidence = unindexed.files[fresh.root .. '/spawn.intents.v1.json']
check(evidence ~= nil and runtime.json.decode(evidence)[1] == 'unindexed-unresolved', 'unresolved legacy IDs without an indexed incarnation stay retained')
check(next(unindexed.host.cache(fresh, 'spawn.intents.v1')) == nil, 'retained unindexed evidence is not replayed into a new incarnation')
local obsolete = world();assert(obsolete.initialize())
local oldHandle = assert(obsolete.host.open('old-layout', inspect('old-layout', 1, 1)))
obsolete.files[oldHandle.root .. '/migration.json'] = runtime.json.encode({phase = 'ready'})
local preserved = clone(obsolete.files)
local unsupported, unsupportedWhy = obsolete.host.open('old-layout', inspect('old-layout', 2, 2))
check(unsupported == nil and unsupportedWhy:find('Unsupported native window journal layout', 1, true) ~= nil
 and equal(obsolete.files, preserved), 'unreleased R17 metadata fails closed without rewriting or bypassing its native evidence')
check(obsolete.initialize() == nil and equal(obsolete.files, preserved), 'HOST cannot silently migrate an unreleased native layout')
local collision = world();assert(collision.initialize())
local originalIdentity = assert(collision.host.open('collision', inspect('collision', 1, 1)))
local identityPath = originalIdentity.path .. '/identity.json'
local altered = runtime.json.decode(collision.files[identityPath]);altered.since = 2
collision.files[identityPath] = runtime.json.encode(altered)
local collisionFiles = clone(collision.files)
check(collision.host.open('collision', inspect('collision', 1, 1)) == nil and equal(collision.files, collisionFiles),
 'a matching locator never substitutes for full stored native identity')
-- A's already captured inventory cannot establish the lifetime of B, whose leaf
-- did not exist before A started inspecting. This models delayed native callbacks.
local delayed = world();assert(delayed.initialize());local dj = delayed.load('window')
local a = assert(dj.open('A', inspect('A', 1, 1)))
local beforeInspection = capture(dj)
local inventoryA = inspect('A', 1, 1)
local inventoryAB = {status = 0, stdout = runtime.json.encode({clients = {
 {kind = 'window', window = 'A', conn = 1, since = 1}, {kind = 'window', window = 'B', conn = 2, since = 2},
}})}
local b = assert(dj.open('B', inventoryAB))
dj.save(b, b.observer);dj.save_cache(b, 'spawn.intents.v1', {})
dj.save_cache(b, 'spawn.records-seen.v1', {})
local bFiles = clone(delayed.files)
assert(dj.open('A', inventoryA, beforeInspection))
check(equal(delayed.files, bFiles) and delayed.dirs[b.path] == true,
 'delayed A inventory never deletes later-created live B journal state')
-- Without a pre-inspection capture no callback has retirement authority.
assert(dj.open('A', inventoryA))
check(delayed.files[b.path .. '/observer.json'] ~= nil, 'an uncaptured inventory never falls back to rescanning current leaves')
-- A fresh inspection may retire that same leaf after it is positively absent.
local afterB = capture(dj)
assert(dj.open('A', inspect('A', 1, 1), afterB))
check(delayed.dirs[b.path] == nil and delayed.files[a.path .. '/observer.json'] ~= nil,
 'a captured ended B leaf retires without deleting the current A sibling')
local changed = world();assert(changed.initialize());local cj = changed.load('window')
assert(cj.open('A', inventoryAB));local changedB = assert(cj.open('B', inventoryAB))
local capturedEmpty = capture(cj)
cj.save_cache(changedB, 'spawn.intents.v1', {'became-pending-during-inspection'})
local changedFiles = clone(changed.files)
assert(cj.open('A', inspect('A', 1, 1), capturedEmpty))
check(equal(changed.files, changedFiles),
 'captured candidates re-read current obligations instead of deleting from an earlier empty snapshot')
for _, missing in ipairs({'observer.json', 'spawn.intents.v1.json', 'spawn.records-seen.v1.json', 'identity.json'}) do
 local lost = world();assert(lost.initialize());local lj = lost.load('window')
 local subject = assert(lj.open('subject', inspect('subject', 1, 1)))
 local both = {status = 0, stdout = runtime.json.encode({clients = {
  {kind = 'window', window = 'subject', conn = 1, since = 1}, {kind = 'window', window = 'reader', conn = 2, since = 2},
 }})}
 assert(lj.open('reader', both))
 lj.save(subject, subject.observer);lj.save_cache(subject, 'spawn.intents.v1', {})
 lj.save_cache(subject, 'spawn.records-seen.v1', {})
 lost.files[subject.path .. '/' .. missing] = nil
 local incompleteFiles = clone(lost.files)
 local heldCandidates = capture(lj)
 assert(lj.open('reader', inspect('reader', 2, 2), heldCandidates))
 check(equal(lost.files, incompleteFiles) and lost.dirs[subject.path] == true,
  'ended incarnation with missing ' .. missing .. ' is unknown, not empty')
 check(lj.open('subject', inspect('subject', 1, 1)) == nil and equal(lost.files, incompleteFiles),
  'reopening missing ' .. missing .. ' cannot recreate exclusion state')
 local cacheOk = pcall(lj.cache, subject, 'spawn.intents.v1')
 local saveOk = pcall(lj.save, subject, subject.observer)
 local cacheSaveOk = pcall(lj.save_cache, subject, 'spawn.intents.v1', {})
 check(not cacheOk and not saveOk and not cacheSaveOk and equal(lost.files, incompleteFiles),
  'existing handles preserve missing ' .. missing .. ' without reads or writes inventing empty state')
end
local partial = world();assert(partial.initialize());local pj = partial.load('window')
partial.fail_write = partial.writes + 2
check(pj.open('partial', inspect('partial', 1, 1)) == nil, 'interrupted new-leaf initialization publishes no handle')
partial.fail_write = nil
local partialFiles = clone(partial.files)
check(pj.open('partial', inspect('partial', 1, 1)) == nil and equal(partial.files, partialFiles),
 'partial initialization without a published identity remains unknown and is never reset')
local partialCandidates = capture(pj)
assert(pj.open('reader', inspect('reader', 2, 2), partialCandidates))
for path, bytes in pairs(partialFiles) do
 check(partial.files[path] == bytes, 'complete absence cannot retire an incompletely initialized unknown leaf')
end
return 'PASS window_journal ' .. tostring(checks)
