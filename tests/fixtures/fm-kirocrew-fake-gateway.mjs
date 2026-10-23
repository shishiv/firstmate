#!/usr/bin/env node
// A stand-in Kiro Crew gateway for tests/fm-kirocrew-harness.test.sh. It
// implements the app-token routes bin/fm-kirocrew.mjs uses, with the response
// shapes recorded in docs/verification/kirocrew.md, the two owner routes
// bin/fm-kirocrew-setup.sh calls, and a few /__test routes that let the suite
// drop live chats (a gateway restart), hold every request unanswered (a hung
// gateway), and read the calls.
//
// Usage: fm-kirocrew-fake-gateway.mjs <port-file>
// Env:   FAKE_SECRET (required), FAKE_AGENT (default firstmate-worker),
//        FAKE_TRUST=1 to grant Trust, FAKE_TURN_MS (default 300),
//        FAKE_CREW_HOME where a registration writes the app files,
//        FAKE_OWNER_TOKEN the dashboard owner's token (default owner-token)
import { mkdirSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';

const SECRET = process.env.FAKE_SECRET || '';
const AGENT = process.env.FAKE_AGENT || 'firstmate-worker';
const TOKEN = 'fake-app-token';
const OWNER_TOKEN = process.env.FAKE_OWNER_TOKEN || 'owner-token';
let turnMs = Number(process.env.FAKE_TURN_MS || 300);
let hang = false;
let port = 0;
const live = new Map();
const transcripts = new Map();
const calls = [];

const row = (slot) => ({
  key: slot.key,
  title: slot.title,
  agent: slot.agent,
  agent_kind: 'template',
  project: slot.project,
  model: slot.model,
  reasoning_effort: slot.effort,
  running: slot.running,
  queue_depth: slot.queue.length,
  pending_approval: false,
  messages: slot.rows.length * 2,
  trust: slot.trust,
  app: 'firstmate',
  origin: 'app',
});

function newSlot(key, fields = {}) {
  return { key, title: '', agent: AGENT, project: '/fake/workspace', model: '', effort: '', running: false, queue: [], rows: [], trust: false, timer: null, ...fields };
}

function startTurn(slot, message) {
  slot.rows.push({ role: 'user', content: message, ts: new Date().toISOString(), meta: {} });
  slot.running = true;
  slot.timer = setTimeout(() => {
    slot.rows.push({ role: 'assistant', content: `echo: ${message.slice(0, 40)}`, ts: new Date().toISOString(), meta: {} });
    endTurn(slot);
  }, turnMs);
}

function endTurn(slot) {
  slot.running = false;
  slot.timer = null;
  transcripts.set(slot.key, slot.rows);
  const next = slot.queue.shift();
  if (next !== undefined) startTurn(slot, next);
}

function send(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

const server = createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => { raw += c; });
  req.on('end', () => {
    const url = new URL(req.url, 'http://fake');
    const body = raw ? JSON.parse(raw) : {};
    const path = url.pathname;
    if (!path.startsWith('/__test/')) calls.push({ method: req.method, path: path + url.search, body });
    if (path === '/__test/calls') return send(res, 200, calls);
    if (path === '/__test/drop') {
      for (const slot of live.values()) {
        if (slot.timer) clearTimeout(slot.timer);
        transcripts.set(slot.key, slot.rows);
      }
      live.clear();
      return send(res, 200, { ok: true });
    }
    if (path === '/__test/turn-ms') {
      turnMs = Number(body.ms);
      return send(res, 200, { ok: true });
    }
    if (path === '/__test/hang') {
      hang = Boolean(body.on);
      return send(res, 200, { ok: true });
    }
    // A hung gateway: the connection stays open and nothing answers.
    if (hang) return undefined;
    if (path === '/api/apps/firstmate/token' && req.method === 'POST') {
      return req.headers['x-app-secret'] === SECRET ? send(res, 200, { token: TOKEN }) : send(res, 403, { error: 'bad secret' });
    }
    if (path === '/api/apps/register' || path.startsWith('/api/security/')) {
      if ((req.headers.cookie || '') !== `mc_token_${port}=${OWNER_TOKEN}`) return send(res, 401, { error: 'Token required' });
      if (path === '/api/security/trusted-apps/firstmate' && req.method === 'POST') return send(res, 200, { ok: true });
      if (path !== '/api/apps/register' || req.method !== 'POST' || body.name !== 'firstmate') return send(res, 404, { error: 'no route' });
      const dir = join(process.env.FAKE_CREW_HOME || '', 'apps', 'firstmate');
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, '.app_secret'), `${SECRET}\n`, { mode: 0o600 });
      writeFileSync(join(dir, 'installed.json'), JSON.stringify({ name: 'firstmate', version: body.version, enabled: false, sessionApprovalConsentPending: true }));
      return send(res, 201, { ok: true, message: 'app registered', secret: SECRET });
    }
    if ((req.headers.cookie || '') !== `mc_token_${port}=${TOKEN}`) return send(res, 401, { error: 'Token required' });
    if (path === '/api/chat/slots' && req.method === 'GET') return send(res, 200, [...live.values()].map(row));
    if (path === '/api/chat/slots' && req.method === 'POST') {
      if (body.agent !== AGENT) return send(res, 409, { error: 'the selected agent choice is not available', code: 'agent_choice_unavailable' });
      const slot = newSlot(body.name, { title: body.title || '' });
      live.set(slot.key, slot);
      return send(res, 200, row(slot));
    }
    if (path === '/api/chat/mode') {
      if (process.env.FAKE_TRUST === '1' && live.has(body.slot)) {
        live.get(body.slot).trust = true;
        return send(res, 200, { ok: true, mode: body.mode });
      }
      return send(res, 403, { error: 'app cannot manage session approvals', code: 'session_approval_not_granted' });
    }
    if (path === '/api/chat' && req.method === 'POST') {
      const slot = live.get(body.slot);
      if (!slot) return send(res, 404, { error: 'slot not found', code: 'slot_not_found' });
      if (slot.running) {
        slot.queue.push(body.message);
        return send(res, 200, { ok: true, queued: true, queue_id: `q${calls.length}` });
      }
      startTurn(slot, body.message);
      return send(res, 200, { ok: true, slot: slot.key, mid: `m${calls.length}` });
    }
    const m = path.match(/^\/api\/chat\/slots\/([^/]+)(?:\/([a-z-]+))?$/);
    if (!m) return send(res, 404, { error: 'no route' });
    const name = decodeURIComponent(m[1]);
    const verb = m[2] || '';
    if (verb === 'resume') {
      if (live.has(name) || !transcripts.has(name) || body.key !== `dashboard_${name}`) return send(res, 404, { error: 'not found', code: 'slot_not_found' });
      const slot = newSlot(name, { rows: transcripts.get(name), project: '/fake/resumed' });
      live.set(name, slot);
      return send(res, 200, { ok: true, key: name, messages: slot.rows });
    }
    const slot = live.get(name);
    if (!slot) return send(res, 404, { error: 'slot not found', code: 'slot_not_found' });
    if (!verb && req.method === 'GET') {
      const limit = Number(url.searchParams.get('limit') || 50);
      return send(res, 200, { key: name, messages: slot.rows.slice(-limit), total: slot.rows.length, context_pct: 1.5, running: slot.running });
    }
    if (!verb && req.method === 'DELETE') {
      if (slot.timer) clearTimeout(slot.timer);
      transcripts.set(name, slot.rows);
      live.delete(name);
      return send(res, 200, { ok: true });
    }
    if (verb === 'project') { slot.project = body.project; return send(res, 200, { ok: true, project: body.project }); }
    if (verb === 'model') { slot.model = body.model; return send(res, 200, { ok: true, model: body.model }); }
    if (verb === 'reasoning-effort') { slot.effort = body.reasoning_effort; return send(res, 200, { ok: true, reasoning_effort: body.reasoning_effort }); }
    if (verb === 'turn-timeout') return send(res, 200, { ok: true, secs: body.secs });
    if (verb === 'interrupt' && slot.queue.length === 0) return send(res, 400, { error: 'queue empty, use /stop instead' });
    if (verb === 'interrupt' || verb === 'stop') {
      if (slot.running) {
        clearTimeout(slot.timer);
        slot.rows.push({ role: 'system', content: '{"kind": "stop_event"}', ts: new Date().toISOString(), meta: {} });
        endTurn(slot);
      }
      return send(res, 200, { ok: true, outcome: 'soft' });
    }
    return send(res, 404, { error: 'no route' });
  });
});

server.listen(0, '127.0.0.1', () => {
  port = server.address().port;
  writeFileSync(process.argv[2], String(port));
});
