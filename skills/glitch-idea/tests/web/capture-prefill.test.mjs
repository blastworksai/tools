// Capture prefill: the asking session's project wins over the configured default; typed text is never replaced.
// Real app.js with a fake DOM (as backlog.test.mjs drives it) and the real api.js for the state-shape cells.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const web = new URL('../../glitch-idea/web/', import.meta.url);
const source = async name => await readFile(new URL(name, web), 'utf8');
const dataUrl = value => 'data:text/javascript;base64,' + Buffer.from(value).toString('base64');
const apiUrl = dataUrl(await source('api.js'));
const foldsUrl = dataUrl(await source('folds.js'));
const {STEPS} = await import(foldsUrl);
const {IdeaApi, ApiError} = await import(apiUrl);
const appSource = (await source('app.js')).replace("'./api.js'", JSON.stringify(apiUrl)).replace("'./folds.js'", JSON.stringify(foldsUrl));
const {startApp} = await import(dataUrl(appSource));
const A = 'binding_' + 'a'.repeat(32), SA = 'session_' + 'a'.repeat(32);
const dflt = {name: 'Default Site', path: '/work/default'}, mine = {name: 'Session Site', path: '/work/session'};

async function app(run, {stateExtra = {}, drop = []} = {}) {
  const names = ['document', 'location', 'history', 'addEventListener', 'setTimeout', 'clearTimeout'];
  const saved = new Map(names.map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
  let doc, currentUrl = new URL('http://127.0.0.1:1234/?binding=' + A);
  class Node {
    constructor(tag = 'div') { this.tagName = tag.toUpperCase(); this.children = []; this.listeners = {}; this.dataset = {}; this.disabled = false; this.value = ''; this.textContent = ''; this.hidden = false; this.scrollTop = 0; this.scrollLeft = 0; }
    append(...nodes) { this.children.push(...nodes); }
    contains(node) { return node === this || this.children.some(child => child.contains(node)); }
    replaceChildren(...nodes) { if (this.children.some(child => child.contains(doc.activeElement))) doc.activeElement = doc.body; this.children = nodes; }
    setAttribute(name, value) { this[name] = value; }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    focus() { if (!this.disabled) doc.activeElement = this; }
    setSelectionRange() {}
    async click() { if (!this.disabled) return this.listeners.click?.({target: this}); }
    all() { return [this, ...this.children.flatMap(child => child.all())]; }
    text() { return this.all().map(node => node.textContent).join(' '); }
    set innerHTML(value) { throw new Error('HTML injection refused'); }
  }
  const roots = new Map(['announcement', 'identity', 'progress', 'save-status', 'agent-status', 'compact-nav', 'columns', 'connection', 'nav-ideas'].map(key => { const node = new Node(); node.id = key; return [key, node]; }));
  const find = (node, key) => node.id === key ? node : node.children.map(child => find(child, key)).find(Boolean);
  doc = {body: new Node('body'), activeElement: null, hidden: true, createElement: tag => new Node(tag), getElementById: key => [...roots.values()].map(node => find(node, key)).find(Boolean) ?? null};
  doc.activeElement = doc.body; globalThis.document = doc;
  Object.defineProperty(globalThis, 'location', {configurable: true, get: () => currentUrl});
  globalThis.history = {replaceState: (_s, _t, url) => { currentUrl = new URL(url, currentUrl); }};
  globalThis.addEventListener = () => {};
  globalThis.setTimeout = () => ({unref() {}});
  globalThis.clearTimeout = () => {};
  const state = {ok: true, code: 'ok', session_id: SA, idea_id: null, idea_status: 'active', revision: 0, draft_version: 0, backlog_revision: 0, current_step: 'capture', agent_status: 'disconnected',
    steps: Object.fromEntries(STEPS.map(({key}, index) => [key, {status: index === 0 ? 'current' : 'todo', accepted_revision: null, evidence_id: null}])), accepted: {}, drafts: {}, draft: null, ...stateExtra};
  for (const key of drop) delete state[key];
  // The fake api runs the real state-shape check, so the page sees exactly what api.js lets through.
  const real = new IdeaApi(async () => ({status: 200, ok: true, json: async () => structuredClone(state)}), 1000, A);
  real.csrf = 'csrf'; real.sessionId = SA;
  const api = {bindingId: A, csrf: 'csrf', pinBinding() {}, session: async () => ({ok: true, code: 'ok', binding_id: A, session_id: SA, csrf_token: 'csrf'}),
    state: () => real.state(), ideas: async () => ({ok: true, code: 'ok', backlog_revision: 1, total: 0, ideas: []}),
    write: async () => ({ok: true, code: 'ok'}), reconcile: async () => ({result: null, state: structuredClone(state)})};
  let flow;
  try {
    flow = startApp(api); await new Promise(resolve => setImmediate(resolve));
    await run({flow, state, get: key => doc.getElementById(key), settle: () => new Promise(resolve => setImmediate(resolve))});
  } finally {
    flow?.dispose();
    for (const [name, descriptor] of saved) if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete globalThis[name];
  }
}
const open = async h => { h.flow.view = 'workflow'; h.flow.current = 'capture'; h.flow.onChange(); await h.settle(); };
const fields = h => [h.get('workspace-name').value, h.get('workspace-path').value];

test('the session workspace wins over the configured default', async () => {
  await app(async h => { await open(h); assert.deepEqual(fields(h), ['Session Site', '/work/session']); },
    {stateExtra: {session_workspace: mine, default_workspace: dflt}});
});

test('the default alone behaves as before, and neither leaves the fields empty', async () => {
  await app(async h => { await open(h); assert.deepEqual(fields(h), ['Default Site', '/work/default']); },
    {stateExtra: {session_workspace: null, default_workspace: dflt}});
  await app(async h => { await open(h); assert.deepEqual(fields(h), ['', '']); }, {stateExtra: {session_workspace: null}});
});

test('the prefill is not confirmed and is not an unsaved edit', async () => {
  await app(async h => {
    await open(h);
    assert.equal(h.flow.buffers.capture.workspace.confirmed, false);
    assert.equal(h.flow.dirty.size, 0);
  }, {stateExtra: {session_workspace: mine}});
});

test('typed text is never replaced, also on a later state refresh', async () => {
  await app(async h => {
    h.flow.buffers.capture = {raw_text: '', workspace: {name: 'Typed', path: '', confirmed: false}};
    h.flow.workspacePrefilled = false; // the page prefilled at start; re-arm so only the typed-text guard can stop a second prefill
    await open(h);
    assert.deepEqual(fields(h), ['Typed', '']);
    h.flow.onChange(); await h.settle(); assert.deepEqual(fields(h), ['Typed', '']);
  }, {stateExtra: {session_workspace: mine, default_workspace: dflt}});
  await app(async h => {
    h.flow.buffers.capture = {raw_text: '', workspace: {name: '', path: '/typed/path', confirmed: false}};
    h.flow.workspacePrefilled = false;
    await open(h);
    assert.deepEqual(fields(h), ['', '/typed/path']);
  }, {stateExtra: {session_workspace: mine}});
  await app(async h => {
    await open(h);
    h.get('workspace-path').value = '/edited'; await h.get('workspace-path').listeners.input({target: h.get('workspace-path')}); await h.settle();
    h.flow.state = {...h.flow.state, session_workspace: {name: 'Other', path: '/work/other'}}; h.flow.workspacePrefilled = false;
    h.flow.onChange(); await h.settle();
    assert.deepEqual(fields(h), ['Session Site', '/edited']);
  }, {stateExtra: {session_workspace: mine}});
});

test('an existing idea is never prefilled', async () => {
  await app(async h => { await open(h); assert.deepEqual(fields(h), ['', '']); },
    {stateExtra: {idea_id: 'idea_' + '1'.repeat(32), session_workspace: mine, default_workspace: dflt}});
});

test('a state without the session_workspace key (older service) loads and falls back to the default', async () => {
  await app(async h => {
    assert.equal(Object.hasOwn(h.state, 'session_workspace'), false);
    await open(h); assert.deepEqual(fields(h), ['Default Site', '/work/default']);
  }, {stateExtra: {default_workspace: dflt}});
  await app(async h => { await open(h); assert.deepEqual(fields(h), ['', '']); });
});

test('api.js rejects a malformed session_workspace like other malformed state', async () => {
  const stateReply = extra => new IdeaApi(async () => ({status: 200, ok: true, json: async () => ({ok: true, code: 'ok', ...extra})}), 1000, A);
  const make = extra => { const api = stateReply(extra); api.csrf = 'csrf'; api.sessionId = SA; return api; };
  for (const good of [null, mine, {name: '', path: ''}]) assert.deepEqual((await make({session_workspace: good}).state()).session_workspace, good);
  assert.equal(Object.hasOwn(await make({}).state(), 'session_workspace'), false);
  const bad = ['/work/session', ['Session Site', '/work/session'], {name: 'x'}, {path: '/x'}, {name: 5, path: '/x'}, {name: 'x', path: null},
    {name: 'x', path: '/x', extra: 1}, 7, true];
  for (const value of bad) {
    await assert.rejects(make({session_workspace: value}).state(), error => error instanceof ApiError && error.code === 'invalid_response', JSON.stringify(value));
  }
});
