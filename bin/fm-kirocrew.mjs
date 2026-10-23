#!/usr/bin/env node
// fm-kirocrew.mjs - the one owner of Kiro Crew's wire protocol inside firstmate.
//
// Kiro Crew is a gateway that drives Kiro sessions over ACP and shows them in
// its dashboard. Firstmate reaches it only through Crew's supported external
// app identity: the Crew app `firstmate` (apps/firstmate/app.json), which
// bin/fm-kirocrew-setup.sh installs from this repository through a Crew app
// registry. Crew writes its secret to <crew-home>/apps/firstmate/.app_secret,
// and POST /api/apps/firstmate/token trades that secret for an app token, which
// Crew confines to the app's own chats ("slots") and to the manifest's
// permissions.api prefixes. Firstmate never reads Crew's .local_secret and never
// calls /api/session-control: those belong to Crew's own processes.
//
// Every app-token route, JSON shape, and HTTP status mapping lives here, so
// bin/fm-kirocrew-run.mjs (the harness program) never parses Crew JSON;
// bin/fm-kirocrew-setup.sh owns the few dashboard-owner calls of the install.
// docs/verification/kirocrew.md records the live behavior each mapping relies on.
//
// Every HTTP exchange is bounded by FM_KIROCREW_TIMEOUT_MS (default 15000): a
// gateway that accepts the connection and never answers fails as unreachable.
//
// CLI verbs (plain key=value output, exit 0 ok, 2 usage, 3 unreachable,
// 4 auth, 5 not found, 6 refused, 7 invalid, 8 a chat the app may not control):
//   (every verb also takes --config-dir <dir> and --state-dir <dir>)
//   fm-kirocrew.mjs config  --home <fm-home>
//   fm-kirocrew.mjs ping    --home <fm-home>
//   fm-kirocrew.mjs slots   --home <fm-home> [--prefix <name-prefix>]
//   fm-kirocrew.mjs close   --home <fm-home> --slot <name>
//   fm-kirocrew.mjs probe   --home <fm-home> --slot <name>
//       create an empty chat on the configured agent, report whether Crew
//       granted Trust to the app, then close it (bin/fm-kirocrew-setup.sh --check)
//   fm-kirocrew.mjs state   --home <fm-home> --slot <name>
//       state=idle|working|approval|queued, or state=absent when Crew does not
//       list the chat, then gen=<the gateway process generation>, read from any
//       listed chat, or empty when Crew lists none
//   fm-kirocrew.mjs ring    --home <fm-home> --slot <name> --message <text>
//       send one message only while the chat is idle: exit 5 when Crew does not
//       list the chat, 6 when it is not idle, 8 when the app may not control it
//       (bin/fm-primary-endpoint-lib.sh)
// The app's consent ("Enable and allow chat control") lets it list every chat
// of the instance, and message the app's own chats and the captain's own
// chats, the ones whose origin is `user`. Crew refuses it every other chat,
// such as one a resume opened with no recorded origin, and it may resume only
// a transcript the app owns.
import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

export const APP_NAME = 'firstmate';
export const DEFAULT_URL = 'http://127.0.0.1:5476';
export const DEFAULT_AGENT = 'firstmate-worker';
// The git repository whose apps/firstmate/app.json Crew installs the app from.
export const DEFAULT_APP_REGISTRY = 'https://github.com/shishiv/firstmate';

const EXIT = { usage: 2, unreachable: 3, auth: 4, not_found: 5, refused: 6, invalid: 7, uncontrolled: 8 };
const TIMEOUT_MS = Number(process.env.FM_KIROCREW_TIMEOUT_MS) || 15000;

export class CrewError extends Error {
  constructor(code, message, detail = {}) {
    super(message);
    this.code = code;
    this.detail = detail;
  }
}

// <config-dir>/kirocrew (default <fm-home>/config) holds optional key=value
// lines (url=, crew-home=, agent=, app-registry=, app-registry-branch=).
// Explicit options win over the file, and the file wins over defaults. The app
// token cache lives in the state directory.
export function loadConfig({ home, configDir, stateDir, url, crewHome, agent } = {}) {
  if (!home) throw new CrewError('usage', 'a firstmate home is required');
  const file = {};
  let text = '';
  try {
    text = readFileSync(join(configDir || join(home, 'config'), 'kirocrew'), 'utf8');
  } catch {
    text = '';
  }
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq > 0) file[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  const baseUrl = (url || file.url || DEFAULT_URL).replace(/\/+$/, '');
  const parsed = new URL(baseUrl);
  return {
    home,
    baseUrl,
    port: parsed.port || (parsed.protocol === 'https:' ? '443' : '80'),
    crewHome: crewHome || file['crew-home'] || join(homedir(), '.kiro', 'crew'),
    agent: agent || file.agent || DEFAULT_AGENT,
    appRegistry: file['app-registry'] || DEFAULT_APP_REGISTRY,
    appRegistryBranch: file['app-registry-branch'] || 'main',
    tokenCache: join(stateDir || join(home, 'state'), '.kirocrew-token'),
  };
}

function readSecret(cfg) {
  try {
    return readFileSync(join(cfg.crewHome, 'apps', APP_NAME, '.app_secret'), 'utf8').trim();
  } catch {
    throw new CrewError('auth', `no app secret at ${join(cfg.crewHome, 'apps', APP_NAME, '.app_secret')}; run bin/fm-kirocrew-setup.sh`);
  }
}

function writePrivate(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, text, { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

// The only function that talks HTTP. The timeout covers the body as well as
// the headers, because a gateway can send headers and then stall.
async function exchange(cfg, method, path, headers, body) {
  try {
    const res = await fetch(cfg.baseUrl + path, { method, headers, body, signal: AbortSignal.timeout(TIMEOUT_MS) });
    return { status: res.status, ok: res.ok, text: await res.text() };
  } catch (err) {
    const why = err?.name === 'TimeoutError' ? `no answer within ${TIMEOUT_MS} ms` : err.cause?.code || err.message;
    throw new CrewError('unreachable', `Kiro Crew at ${cfg.baseUrl} is unreachable: ${why}`);
  }
}

async function exchangeToken(cfg) {
  const secret = readSecret(cfg);
  const res = await exchange(cfg, 'POST', `/api/apps/${APP_NAME}/token`, { 'X-App-Secret': secret, 'Content-Type': 'application/json' });
  let data;
  try {
    data = JSON.parse(res.text);
  } catch {
    data = null;
  }
  if (!res.ok || typeof data?.token !== 'string' || !data.token) {
    throw new CrewError('auth', `Kiro Crew refused the firstmate app secret (HTTP ${res.status})`);
  }
  writePrivate(cfg.tokenCache, data.token);
  return data.token;
}

async function appToken(cfg, { refresh = false } = {}) {
  if (!refresh) {
    try {
      const cached = readFileSync(cfg.tokenCache, 'utf8').trim();
      if (cached) return cached;
    } catch {
      // no cache yet
    }
  }
  return exchangeToken(cfg);
}

// The token travels as Crew's auth cookie, as kirocrew-client sends it, so it
// never lands in a URL or a log line. A loopback request without an Origin
// header passes Crew's CSRF barrier. Crew refuses an app token one hour after
// it was minted (its session lifetime) with a plain 403 `forbidden`, the
// answer its auth gate gives, and a missing or forged one with 401, so either
// answer to a cached token gets one fresh token before it counts.
export async function request(cfg, method, path, body) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const token = await appToken(cfg, { refresh: attempt > 0 });
    const headers = { Cookie: `mc_token_${cfg.port}=${token}` };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const res = await exchange(cfg, method, path, headers, body === undefined ? undefined : JSON.stringify(body));
    let data;
    try {
      data = res.text ? JSON.parse(res.text) : {};
    } catch {
      if (attempt === 0 && (res.status === 401 || res.status === 403)) continue;
      throw new CrewError('invalid', `Kiro Crew answered ${method} ${path} with non-JSON (HTTP ${res.status})`);
    }
    const code = typeof data?.code === 'string' ? data.code : '';
    if (attempt === 0 && (res.status === 401 || (res.status === 403 && code === 'forbidden'))) continue;
    if (res.ok) return data;
    const message = `${method} ${path}: HTTP ${res.status}${code ? ` ${code}` : ''}${data?.error ? `: ${data.error}` : ''}`;
    if (res.status === 401) throw new CrewError('auth', message, { status: res.status, crewCode: code });
    if (res.status === 404) throw new CrewError('not_found', message, { status: res.status, crewCode: code });
    throw new CrewError('refused', message, { status: res.status, crewCode: code });
  }
  throw new CrewError('auth', 'Kiro Crew rejected the refreshed app token');
}

// One verdict per chat, derived from the flags Crew reports for it.
export function slotState(raw) {
  if (raw.pending_approval) return 'approval';
  if (raw.running) return 'working';
  if (Number(raw.queue_depth) > 0) return 'queued';
  return 'idle';
}

export function parseSlot(raw) {
  if (!raw || typeof raw.key !== 'string' || !raw.key) throw new CrewError('invalid', 'Kiro Crew returned a chat without a key');
  return {
    key: raw.key,
    state: slotState(raw),
    queueDepth: Number(raw.queue_depth) || 0,
    messages: Number(raw.messages) || 0,
    project: raw.project || '',
    agent: raw.agent || '',
    model: raw.model || '',
    effort: raw.reasoning_effort || '',
    trust: Boolean(raw.trust),
    app: raw.app || '',
    origin: raw.origin || '',
    // One random value per gateway process (Crew's chunk generation), so a
    // changed value means the gateway restarted, even when a dashboard restart
    // re-executed it under the same pid.
    gen: typeof raw.turn_gen === 'string' ? raw.turn_gen : '',
  };
}

const slotPath = (name) => `/api/chat/slots/${encodeURIComponent(name)}`;

export async function listSlots(cfg) {
  const data = await request(cfg, 'GET', '/api/chat/slots');
  if (!Array.isArray(data)) throw new CrewError('invalid', 'Kiro Crew returned a chat list that is not an array');
  return data.map(parseSlot);
}

export async function findSlot(cfg, name) {
  return (await listSlots(cfg)).find((slot) => slot.key === name) || null;
}

export async function createSlot(cfg, name, title = '') {
  // Template selection runs the shared agent file on the app's own memory.
  // Temporary memory keeps worker transcripts out of Crew's long-term memory,
  // because firstmate keeps durable task memory in its own records.
  const body = { name, agent: cfg.agent, agent_kind: 'template', memory_mode: 'temporary' };
  if (title) body.title = title;
  try {
    return parseSlot(await request(cfg, 'POST', '/api/chat/slots', body));
  } catch (err) {
    if (!(err instanceof CrewError && err.detail.crewCode === 'agent_choice_unavailable')) throw err;
    throw new CrewError('refused', `Kiro Crew does not offer the agent ${cfg.agent}. Crew reads agent files only when its gateway starts, from <KIRO_HOME>/agents of the gateway; bin/fm-kirocrew-setup.sh --kiro-home writes the file there`, err.detail);
  }
}

// Crew drops live chats when its gateway restarts but keeps their transcripts;
// resume puts the transcript back into a live chat with its agent, project,
// model and effort. A chat whose transcript is gone answers not_found.
export async function resumeSlot(cfg, name) {
  await request(cfg, 'POST', `${slotPath(name)}/resume`, { key: `dashboard_${name}` });
  return findSlot(cfg, name);
}

// Applies only the difference, so a relaunch or a retry converges.
export async function configureSlot(cfg, slot, { project, model, effort, turnTimeoutSecs = 86400 }) {
  if (project && slot.project !== project) await request(cfg, 'POST', `${slotPath(slot.key)}/project`, { project });
  if (model && slot.model !== model) await request(cfg, 'POST', `${slotPath(slot.key)}/model`, { model });
  if (effort && slot.effort !== effort) await request(cfg, 'POST', `${slotPath(slot.key)}/reasoning-effort`, { reasoning_effort: effort });
  await request(cfg, 'POST', `${slotPath(slot.key)}/turn-timeout`, { secs: turnTimeoutSecs });
}

// Trust needs the app's sessionApproval permission, which Crew grants only from
// its dashboard. Without it every shell and file tool waits for a person.
export async function requestTrust(cfg, name) {
  try {
    await request(cfg, 'POST', '/api/chat/mode', { mode: 'trust', slot: name });
    return 'granted';
  } catch (err) {
    if (err instanceof CrewError && err.code === 'refused' && err.detail.crewCode === 'session_approval_not_granted') return 'not-granted';
    throw err;
  }
}

// ws=1 makes Crew answer with a receipt and run the turn on its own; without
// it the response streams until the turn ends. A busy chat queues the message.
export async function sendMessage(cfg, name, message) {
  const data = await request(cfg, 'POST', '/api/chat?ws=1', { slot: name, message });
  return data.queued ? 'queued' : 'started';
}

// Stop cancels the running turn and keeps the chat. Crew's interrupt route is
// a different verb: it cuts a turn short only to run a queued message, and it
// refuses an empty queue.
export async function interruptSlot(cfg, name) {
  await request(cfg, 'POST', `${slotPath(name)}/stop`, {});
}

export async function closeSlot(cfg, name) {
  try {
    await request(cfg, 'DELETE', slotPath(name));
  } catch (err) {
    if (!(err instanceof CrewError && err.code === 'not_found')) throw err;
  }
}

export async function history(cfg, name, limit) {
  const data = await request(cfg, 'GET', `${slotPath(name)}?limit=${Math.max(1, Math.min(200, limit))}`);
  const rows = Array.isArray(data.messages) ? data.messages : [];
  return {
    total: Number(data.total) || 0,
    contextPct: typeof data.context_pct === 'number' ? data.context_pct : null,
    rows: rows.map((row) => ({ role: String(row.role || ''), content: typeof row.content === 'string' ? row.content : JSON.stringify(row.content ?? ''), ts: String(row.ts || '') })),
  };
}

// One deterministic text block per transcript row for the pane mirror. No
// spinner and no clock, so an unchanged transcript renders unchanged bytes.
export function renderRow(row) {
  const text = row.content.replace(/\r/g, '');
  const lines = text.split('\n');
  const first = lines[0].slice(0, 300);
  const more = lines.length > 1 ? ` (+${lines.length - 1} lines)` : '';
  switch (row.role) {
    case 'user':
      return `▸ ${first}${more}`;
    case 'assistant':
      return text;
    case 'tool':
      return `  ${first}`;
    default:
      return `  · ${row.role}: ${first}${more}`;
  }
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg.startsWith('--')) {
      const key = arg.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) out[key] = true;
      else {
        out[key] = next;
        i += 1;
      }
    } else out._.push(arg);
  }
  return out;
}

async function main(argv) {
  const args = parseArgs(argv);
  const verb = args._[0];
  const cfg = loadConfig({ home: args.home, configDir: args['config-dir'], stateDir: args['state-dir'], url: args.url, crewHome: args['crew-home'], agent: args.agent });
  switch (verb) {
    case 'config':
      console.log(`url=${cfg.baseUrl}\ncrew-home=${cfg.crewHome}\nagent=${cfg.agent}\napp-registry=${cfg.appRegistry}\napp-registry-branch=${cfg.appRegistryBranch}`);
      return;
    case 'ping': {
      const slots = await listSlots(cfg);
      console.log(`gateway=ok app=${APP_NAME} chats=${slots.length}`);
      return;
    }
    case 'slots': {
      const prefix = typeof args.prefix === 'string' ? args.prefix : '';
      for (const slot of await listSlots(cfg)) if (slot.key.startsWith(prefix)) console.log(`${slot.key}\t${slot.state}\t${slot.project}`);
      return;
    }
    case 'close':
      if (typeof args.slot !== 'string') throw new CrewError('usage', 'close needs --slot');
      await closeSlot(cfg, args.slot);
      console.log(`closed=${args.slot}`);
      return;
    case 'state': {
      if (typeof args.slot !== 'string') throw new CrewError('usage', 'state needs --slot');
      const slots = await listSlots(cfg);
      const slot = slots.find((s) => s.key === args.slot);
      const gen = (slot || slots.find((s) => s.gen) || {}).gen || '';
      console.log(`state=${slot ? slot.state : 'absent'} gen=${gen}`);
      return;
    }
    case 'ring': {
      if (typeof args.slot !== 'string' || typeof args.message !== 'string' || !args.message) throw new CrewError('usage', 'ring needs --slot and --message');
      const slot = await findSlot(cfg, args.slot);
      if (!slot) throw new CrewError('not_found', `Kiro Crew does not list the chat ${args.slot}`);
      if (slot.app !== APP_NAME && slot.origin !== 'user') {
        throw new CrewError('uncontrolled', `the firstmate app may not message the chat ${args.slot}, whose origin is ${slot.origin || 'unrecorded'}`);
      }
      if (slot.state !== 'idle') throw new CrewError('refused', `the chat ${args.slot} is ${slot.state}`);
      try {
        console.log(`rung=${slot.key} delivery=${await sendMessage(cfg, slot.key, args.message)}`);
      } catch (err) {
        // Crew answers a send it refuses on a listed chat with its uniform 404.
        if (err instanceof CrewError && err.code === 'not_found') throw new CrewError('uncontrolled', `Kiro Crew refused the firstmate app's message to the chat ${args.slot}`, err.detail);
        throw err;
      }
      return;
    }
    case 'probe': {
      if (typeof args.slot !== 'string') throw new CrewError('usage', 'probe needs --slot');
      const slot = await createSlot(cfg, args.slot);
      try {
        console.log(`agent=${slot.agent}\ntrust=${await requestTrust(cfg, slot.key)}`);
      } finally {
        await closeSlot(cfg, slot.key);
      }
      return;
    }
    default:
      throw new CrewError('usage', 'usage: fm-kirocrew.mjs config|ping|slots|close|probe|state|ring --home <fm-home> [...]');
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2)).catch((err) => {
    process.stderr.write(`fm-kirocrew: ${err.message}\n`);
    process.exit(err instanceof CrewError ? EXIT[err.code] || 1 : 1);
  });
}
