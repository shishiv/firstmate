#!/usr/bin/env node
// A stand-in Kiro Crew gateway for tests/fm-kirocrew-harness.test.sh. It
// implements the app-token routes bin/fm-kirocrew.mjs uses, with the response
// shapes recorded in docs/verification/kirocrew.md, the owner routes
// bin/fm-kirocrew-setup.sh calls to install the app from a registry, and a few
// /__test routes that let the suite drop live chats (a gateway restart), hold
// every request unanswered (a hung gateway), seed the installed app record,
// expire the app token (Crew then answers it 403 `forbidden`), and read the
// calls. The dashboard owner reaches every chat route too, and a chat the owner
// creates is the owner's own (origin user, no app).
//
// Usage: fm-kirocrew-fake-gateway.mjs <port-file>
// Env:   FAKE_SECRET (required), FAKE_AGENT (comma-separated agents the gateway
//        offers, default firstmate-worker),
//        FAKE_TRUST=1 to grant Trust, FAKE_TURN_MS (default 300),
//        FAKE_CREW_HOME where an install writes the app files,
//        FAKE_OWNER_TOKEN the dashboard owner's token (default owner-token)
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';

const MANIFEST = JSON.parse(readFileSync(new URL('../../apps/firstmate/app.json', import.meta.url), 'utf8'));
const SECRET = process.env.FAKE_SECRET || '';
const AGENTS = (process.env.FAKE_AGENT || 'firstmate-worker').split(',');
const AGENT = AGENTS[0];
const TOKEN = 'fake-app-token';
// Crew's per-process generation, which every chat row carries as turn_gen; a
// drop (a gateway restart) mints a new one.
let gen = 'gen-1';
// The token the next exchange mints; an expired one is refused with 403.
let liveToken = TOKEN;
const expiredTokens = new Set();
const OWNER_TOKEN = process.env.FAKE_OWNER_TOKEN || 'owner-token';
let turnMs = Number(process.env.FAKE_TURN_MS || 300);
let hang = false;
let port = 0;
const live = new Map();
const transcripts = new Map();
// Who created each chat, kept with its transcript so a resume restores it.
const origins = new Map();
const calls = [];
// Owner-side app state: the operator's registry rows, which of them were read
// since they last changed, the trust grant (bound to a repository), and the
// installed app record.
let registries = [];
const refreshed = new Set();
let trustedRepository = null;
let installedApp = null;

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
  app: slot.origin === 'user' ? '' : 'firstmate',
  origin: slot.origin,
  turn_gen: gen,
});

function newSlot(key, fields = {}) {
  return { key, title: '', agent: AGENT, project: '/fake/workspace', model: '', effort: '', running: false, queue: [], rows: [], trust: false, timer: null, origin: 'app', ...fields };
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

// The registry that lists the app: a configured row read since it last changed.
// Every such fake registry lists `firstmate`, from the manifest in this repo.
const listingRegistry = () => registries.find((r) => refreshed.has(r.repo)) || null;

// The dashboard-owner routes bin/fm-kirocrew-setup.sh calls, with the
// preconditions Crew enforces: trust names the app's repository, and an install
// needs both a registry listing the app and that trust.
function ownerRoute(req, res, path, body) {
  if ((req.headers.cookie || '') !== `mc_token_${port}=${OWNER_TOKEN}`) return send(res, 401, { error: 'Token required' });
  const method = req.method;
  if (path === '/api/apps/firstmate' && method === 'GET') {
    return installedApp ? send(res, 200, installedApp) : send(res, 404, { error: "app 'firstmate' not installed" });
  }
  if (path === '/api/apps/registries' && method === 'GET') {
    return send(res, 200, { registries: registries.map((r) => ({ ...r, trust: 'index' })), pinned: [] });
  }
  if (path === '/api/apps/registries' && method === 'PUT') {
    if (!Array.isArray(body.registries) || body.registries.some((r) => !r || !r.repo || !r.name)) return send(res, 400, { error: 'registries must be an array' });
    registries = body.registries.map(({ name, repo, branch }) => ({ name, repo, branch: branch || 'main' }));
    refreshed.clear();
    return send(res, 200, { ok: true, registries, newlyTrustedHosts: [] });
  }
  if (path === '/api/apps/registries/refresh' && method === 'POST') {
    const reg = registries.find((r) => r.repo === body.repo);
    if (!reg) return send(res, 404, { error: 'unknown registry' });
    refreshed.add(reg.repo);
    return send(res, 200, { ok: true, refreshed: [reg.name], failed: [] });
  }
  if (path === '/api/security/trusted-apps/firstmate' && method === 'POST') {
    const reg = listingRegistry();
    if (!installedApp && !reg) return send(res, 404, { error: 'app is neither installed nor in a known registry', code: 'app_not_installed' });
    const repository = installedApp ? installedApp.sourceUrl || '' : reg.repo;
    if ((body.repository || '') !== repository) return send(res, 409, { error: 'repository consent proof is required', code: 'app_trust_repository_mismatch' });
    trustedRepository = repository;
    return send(res, 200, { ok: true });
  }
  if (path === '/api/apps/registry/install' && method === 'POST') {
    const reg = listingRegistry();
    if (body.name !== MANIFEST.name || !reg) return send(res, 404, { ok: false, error: `app ${body.name} is not in any registry` });
    if (installedApp) return send(res, 400, { ok: false, error: 'already installed' });
    if (trustedRepository !== reg.repo) return send(res, 400, { ok: false, error: 'blocked by execution policy: third-party app execution is disabled' });
    const dir = join(process.env.FAKE_CREW_HOME || '', 'apps', MANIFEST.name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, '.app_secret'), `${SECRET}\n`, { mode: 0o600 });
    installedApp = {
      name: MANIFEST.name,
      version: MANIFEST.version,
      enabled: false,
      sessionApprovalConsentPending: Boolean(MANIFEST.permissions?.sessionApproval),
      resources: 'gateway',
      origin: 'registry',
      sourceUrl: reg.repo,
    };
    return send(res, 201, { ok: true, name: MANIFEST.name, message: `installed ${MANIFEST.name}` });
  }
  return send(res, 404, { error: 'no route' });
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
    // A gateway restart: a new generation, every live chat's turn lost, and
    // every chat dropped but its transcript, except the owner's own chats when
    // keep_owner is set (Crew restores the owner's open chats).
    if (path === '/__test/drop') {
      gen = `gen-${Number(gen.slice(4)) + 1}`;
      for (const slot of [...live.values()]) {
        if (slot.timer) clearTimeout(slot.timer);
        slot.timer = null;
        slot.running = false;
        slot.queue = [];
        transcripts.set(slot.key, slot.rows);
        if (!(body.keep_owner && slot.origin === 'user')) live.delete(slot.key);
      }
      return send(res, 200, { ok: true, gen });
    }
    if (path === '/__test/turn-ms') {
      turnMs = Number(body.ms);
      return send(res, 200, { ok: true });
    }
    if (path === '/__test/hang') {
      hang = Boolean(body.on);
      return send(res, 200, { ok: true });
    }
    if (path === '/__test/app') {
      installedApp = body.record || null;
      return send(res, 200, { ok: true });
    }
    if (path === '/__test/expire-token') {
      expiredTokens.add(liveToken);
      liveToken = `${TOKEN}-${expiredTokens.size + 1}`;
      return send(res, 200, { ok: true });
    }
    // A hung gateway: the connection stays open and nothing answers.
    if (hang) return undefined;
    if (path === '/api/apps/firstmate/token' && req.method === 'POST') {
      return req.headers['x-app-secret'] === SECRET ? send(res, 200, { token: liveToken }) : send(res, 403, { error: 'bad secret' });
    }
    if (path.startsWith('/api/apps/') || path.startsWith('/api/security/')) return ownerRoute(req, res, path, body);
    const cookie = req.headers.cookie || '';
    const owner = cookie === `mc_token_${port}=${OWNER_TOKEN}`;
    if (expiredTokens.has(cookie.replace(`mc_token_${port}=`, ''))) return send(res, 403, { error: 'Forbidden', code: 'forbidden' });
    if (!owner && cookie !== `mc_token_${port}=${liveToken}`) return send(res, 401, { error: 'Token required' });
    if (path === '/api/chat/slots' && req.method === 'GET') return send(res, 200, [...live.values()].map(row));
    if (path === '/api/chat/slots' && req.method === 'POST') {
      if (!AGENTS.includes(body.agent)) return send(res, 409, { error: 'the selected agent choice is not available', code: 'agent_choice_unavailable' });
      const slot = newSlot(body.name, { title: body.title || '', agent: body.agent, origin: owner ? 'user' : 'app' });
      origins.set(slot.key, slot.origin);
      live.set(slot.key, slot);
      return send(res, 200, row(slot));
    }
    if (path === '/api/chat/mode') {
      if ((owner || process.env.FAKE_TRUST === '1') && live.has(body.slot)) {
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
      const slot = newSlot(name, { rows: transcripts.get(name), project: '/fake/resumed', origin: origins.get(name) || 'app' });
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
