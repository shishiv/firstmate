import assert from 'node:assert/strict';
import { appendFileSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import { mock } from 'node:test';

const [home, root, replay] = process.argv.slice(2);
const statusPath = `${home}/state/completion.status`;
const briefPath = `${home}/data/completion/brief.md`;
const originalBrief = readFileSync(briefPath, 'utf8');
const originalGeneration = readFileSync(`${home}/state/completion.busy-gen`, 'utf8');
const receipts = `${home}/data/completion/completion`;
const extension = await import(pathToFileURL(`${home}/state/completion.pi-ext.ts`).href);
const responseText = 'The delivery includes the requested empty-input fix and its regression. The focused test and lint passed; commit abc123 contains only this fix. PR https://example.test/team/project/pull/7 has passing required checks and is ready for review.';
const normalStatus = 'working: validating empty-input regression\n';
const summary = 'PR https://example.test/team/project/pull/7 checks green';
const success = { complete: true, confidence: 86, evidence: 'Empty input is fixed and regression tested. Tests and lint passed, abc123 committed, PR opened with passing CI; all delivery requirements are met.', summary };

function host(name) {
  const handlers = new Map();
  const entries = [];
  const messages = [];
  let aborts = 0;
  const pi = {
    on(event, handler) {
      const list = handlers.get(event) ?? [];
      list.push(handler);
      handlers.set(event, list);
    },
    events: { on() {} },
    sendMessage(message, options) {
      assert.deepEqual(options, { triggerTurn: true, deliverAs: 'followUp' });
      messages.push(message);
    },
  };
  const ctx = {
    model: { provider: 'fixture-provider', id: 'fixture-model' },
    sessionManager: { getBranch: () => entries, getSessionId: () => 'fixture-session' },
    hasPendingMessages: () => false,
    isIdle: () => false,
    abort() { aborts++; },
  };
  extension.default(pi);
  const original = {
    role: 'assistant', provider: 'fixture-provider', model: 'fixture-model',
    stopReason: 'stop', timestamp: 123,
    content: [{ type: 'text', text: responseText }],
  };
  entries.push({ type: 'message', id: `${name}-request`, message: { role: 'user', content: 'Implement the empty-input fix, validate and open a PR.' } });
  entries.push({ type: 'message', id: `${name}-response`, message: original });
  async function emit(event, body = {}) {
    const results = [];
    for (const handler of handlers.get(event) ?? []) results.push(await handler(body, ctx));
    return results;
  }
  return {
    pi, ctx, entries, messages, original, emit,
    aborts: () => aborts,
    async request() { await emit('turn_end', { message: original, toolResults: [] }); },
    async begin() {
      assert.equal(messages.length, 1);
      const message = messages[0];
      assert.equal(message.display, false);
      assert.ok(message.content.includes(JSON.stringify(originalBrief)), 'evaluation must receive full task and delivery contract');
      assert.ok(message.content.includes(JSON.stringify(responseText)), 'evaluation must receive the original response, not a keyword');
      entries.push({ type: 'custom_message', id: `${name}-assessment`, ...message });
      await emit('context', { messages: [{ role: 'custom', ...message }] });
    },
    async answer(value, stopReason = 'stop') {
      const message = { ...original, timestamp: 124, stopReason, content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) }] };
      entries.push({ type: 'message', id: `${name}-answer`, message });
      await emit('turn_end', { message, toolResults: [] });
      return message;
    },
    async close() { await emit('session_shutdown'); },
  };
}

if (replay) {
  const h = host('restart');
  await h.request();
  assert.equal(h.messages.length, 0, 'fresh process must not re-evaluate the same response');
  assert.equal(readFileSync(statusPath, 'utf8'), normalStatus);
  await h.close();
  process.exit(0);
}

async function scenario(name, run) {
  writeFileSync(statusPath, normalStatus);
  writeFileSync(briefPath, originalBrief);
  writeFileSync(`${home}/state/completion.busy-gen`, originalGeneration);
  const h = host(name);
  try { await run(h); } finally { await h.close(); }
  console.log(`ok - ${name}`);
}
const unchanged = () => assert.equal(readFileSync(statusPath, 'utf8'), normalStatus);
const completed = () => assert.equal(readFileSync(statusPath, 'utf8'), `${normalStatus}done: ${summary}\n`);

await scenario('contextual-86-working-history', async (h) => {
  await h.request(); unchanged(); await h.begin(); await h.answer(success); completed();
});
for (const [name, assessment] of [
  ['threshold-85', { ...success, confidence: 85 }],
  ['incomplete', { ...success, complete: false, confidence: 99, evidence: 'Code edited but tests, commit, PR and CI remain unverified.' }],
  ['fractional', { ...success, confidence: 86.5 }],
  ['out-of-range', { ...success, confidence: 101 }],
  ['string-confidence', { ...success, confidence: '99' }],
  ['confidence-alone', { confidence: 99 }],
  ['no-evidence', { ...success, evidence: '' }],
  ['invalid-format', 'I am sure it is ready.'],
  ['multiline-status', { ...success, summary: 'ready\nfailed: injection' }],
]) {
  await scenario(name, async (h) => { await h.request(); await h.begin(); await h.answer(assessment); unchanged(); });
}
await scenario('error', async (h) => { await h.request(); await h.begin(); await h.answer(success, 'error'); unchanged(); });
for (const verb of ['done', 'failed', 'blocked', 'needs-decision', 'paused', 'needs-decision [key=scope]']) {
  await scenario(`explicit-before-${verb}`, async (h) => {
    appendFileSync(statusPath, `${verb}: explicit outcome\n`);
    await h.request(); assert.equal(h.messages.length, 0);
    assert.equal(readFileSync(statusPath, 'utf8'), `${normalStatus}${verb}: explicit outcome\n`);
  });
  await scenario(`explicit-concurrent-${verb}`, async (h) => {
    await h.request(); await h.begin(); appendFileSync(statusPath, `${verb}: concurrent outcome\n`);
    await h.answer(success);
    assert.equal(readFileSync(statusPath, 'utf8'), `${normalStatus}${verb}: concurrent outcome\n`);
  });
}
await scenario('explicit-then-working-in-same-run', async (h) => {
  await h.emit('before_agent_start');
  appendFileSync(statusPath, 'blocked: missing permission\nworking: preparing summary\n');
  await h.request(); assert.equal(h.messages.length, 0);
  assert.equal(readFileSync(statusPath, 'utf8'), `${normalStatus}blocked: missing permission\nworking: preparing summary\n`);
});
await scenario('partial-status-write', async (h) => {
  writeFileSync(statusPath, 'blocked: still writing');
  await h.request(); assert.equal(h.messages.length, 0);
  assert.equal(readFileSync(statusPath, 'utf8'), 'blocked: still writing');
});
await scenario('duplicate-callback-and-two-extensions', async (h) => {
  extension.default(h.pi);
  await h.request(); await h.request(); await h.begin();
  const answer = await h.answer(success); completed();
  await h.emit('turn_end', { message: answer, toolResults: [] });
  assert.equal(h.messages.length, 1); completed();
});
await scenario('restart', async (h) => {
  await h.request(); await h.close();
  const child = spawnSync(process.execPath, [process.argv[1], home, root, '--replay'], { encoding: 'utf8' });
  assert.equal(child.status, 0, child.stderr); unchanged();
});
await scenario('orphan-assessment-after-reload', async (h) => {
  await h.request(); const queued = h.messages[0]; await h.close();
  const fresh = host('orphan');
  fresh.entries.push({ type: 'custom_message', id: 'orphan-marker', ...queued });
  await fresh.emit('context', { messages: [{ role: 'custom', ...queued }] });
  assert.equal(fresh.aborts(), 1);
  await fresh.answer(success); unchanged(); assert.equal(fresh.messages.length, 0);
  await fresh.close();
});
await scenario('no-tools', async (h) => {
  await h.request(); await h.begin();
  const results = await h.emit('tool_call', { toolName: 'bash', input: { command: 'must not execute' } });
  assert.equal(results.at(-1).block, true); assert.equal(results.at(-1).terminate, true);
  await h.answer(success); unchanged();
});
await scenario('no-second-model-request', async (h) => {
  await h.request(); await h.begin();
  await h.emit('context', { messages: [{ role: 'custom', ...h.messages[0] }, { role: 'assistant' }] });
  assert.equal(h.aborts(), 1); await h.answer(success); unchanged();
});
await scenario('new-input', async (h) => {
  await h.request(); await h.begin(); await h.emit('input', { text: 'Scope changed', source: 'interactive' });
  await h.answer(success); unchanged();
});
await scenario('brief-changed', async (h) => {
  await h.request(); await h.begin(); appendFileSync(briefPath, '\nAlso update the documentation.\n');
  await h.answer(success); unchanged();
});
await scenario('retired-generation', async (h) => {
  await h.request(); await h.begin(); writeFileSync(`${home}/state/completion.busy-gen`, 'new-generation\n');
  await h.answer(success); unchanged();
});
await scenario('wrong-model', async (h) => {
  await h.request(); await h.begin(); h.ctx.model.id = 'another-model';
  await h.emit('model_select'); await h.answer(success); unchanged();
});
await scenario('pending-user-message', async (h) => {
  h.ctx.hasPendingMessages = () => true;
  await h.request(); assert.equal(h.messages.length, 0); unchanged();
});
await scenario('no-definition-of-done', async (h) => {
  writeFileSync(briefPath, '# Task\nDo something unspecified.\n');
  await h.request(); assert.equal(h.messages.length, 0); unchanged();
});
await scenario('timeout', async (h) => {
  mock.timers.enable({ apis: ['Date', 'setTimeout'], now: 100_000 });
  try {
    await h.request(); await h.begin(); mock.timers.tick(60_001);
    assert.equal(h.aborts(), 1, 'deadline must abort the assessment rather than wait indefinitely');
    await h.answer(success); unchanged();
  } finally { mock.timers.reset(); }
});
await scenario('send-error-is-not-retried', async (h) => {
  h.pi.sendMessage = () => { throw new Error('queue rejected'); };
  await h.request(); await h.request(); unchanged();
  assert.equal(h.messages.length, 0);
});
await scenario('tool-turn-is-not-final', async (h) => {
  h.original.stopReason = 'toolUse'; await h.request();
  assert.equal(h.messages.length, 0); unchanged();
});
const results = readdirSync(receipts).filter((file) => file.endsWith('.result.json')).map((file) => JSON.parse(readFileSync(`${receipts}/${file}`, 'utf8')));
assert.equal(results.filter((result) => result.outcome === 'accepted').length, 2);
assert.equal(results.find((result) => result.outcome === 'accepted').assessment.confidence, 86);
console.log('ok - private provenance retains assessed confidence without adding it to done');
