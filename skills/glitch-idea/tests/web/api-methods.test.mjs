// The ideas list accepts every stored method id (the retired one stays readable) and still rejects an unknown id.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const source = await readFile(new URL('../../glitch-idea/web/api.js', import.meta.url), 'utf8');
const {IdeaApi, ApiError} = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const binding = 'binding_' + 'a'.repeat(32), session = 'session_' + 'b'.repeat(32), idea = 'idea_' + 'c'.repeat(32);
const reply = method => ({ok: true, code: 'ok', backlog_revision: 1, total: 1, ideas: [{idea_id: idea, revision: 2, position: 1, title: 'T', status: 'in-progress',
  method, updated: '2026-10-01T10:00:00+02:00', detail_path: '/x/' + idea + '.md'}]});
const api = body => {
  const value = new IdeaApi(async () => ({status: 200, ok: true, json: async () => body}), 1000, binding);
  value.csrf = 'test-only-csrf'; value.sessionId = session; return value;
};

test('a state row with bmad, any older method, or no method is accepted', async () => {
  for (const method of ['bmad', 'adaptive-slices', 'bounded-plan', 'appetite-led', 'experiment-led', null]) {
    assert.equal((await api(reply(method)).ideas()).ideas[0].method, method, String(method));
  }
});

test('a state row with an unknown method id is rejected', async () => {
  await assert.rejects(api(reply('waterfall')).ideas(), error => error instanceof ApiError && error.code === 'invalid_response');
});
