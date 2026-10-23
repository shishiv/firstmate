#!/usr/bin/env node
// fm-kirocrew-run.mjs - the kirocrew harness program: one Kiro Crew chat per
// firstmate task, driven from an ordinary task pane.
//
// The worker's conversation runs inside Kiro Crew, so the captain can read it
// in Crew's dashboard. This program is what firstmate's pane-based machinery
// talks to: it creates or resumes the task's chat (bin/fm-kirocrew.mjs owns
// every Crew call), sends the launch brief, mirrors the transcript into the
// pane, forwards typed lines as messages, and turns Crew's turn flags into the
// busy-state contract through bin/fm-busy-event.sh (the only writer).
//
// Pane contract (docs/verification/kirocrew.md):
//   status row  "Kiro Crew is working · esc to cancel" while a turn runs,
//               "Kiro Crew · idle" between turns
//   composer    "› " followed by the unsent text; empty means nothing pending
//   Enter       sends the composer text; a busy chat queues it for the next turn
//   Escape      interrupts the running turn and keeps the chat
//   /quit       closes the chat (its transcript stays in Crew) and exits
//
// On the Herdr backend fm-spawn passes the task pane (--herdr-pane,
// --herdr-session), and the program reports itself as that pane's agent
// (`herdr pane report-agent`), because Herdr does not detect it natively and
// firstmate's Herdr liveness read requires a registered agent. The pane comes
// only from those arguments, never from inherited HERDR_* variables, so a
// program started anywhere else can never claim another pane.
//
// Busy lifecycle: a turn start applies busy; a turn end applies idle and
// touches state/<id>.turn-ended; an interrupt or exit applies idle without
// the wake. A chat that Crew dropped (gateway restart) is resumed from its
// transcript, and the lost turn counts as ended so the watcher looks at it. A
// gateway that stays unreachable for 30 poll intervals turns the record
// `unknown`, and the next answer writes the chat's real state back.
//
// SIGHUP and SIGTERM end the program at once, whatever request is in flight:
// the record goes idle, and the chat close gets CLOSE_WAIT_MS (3 s) before exit.
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  CrewError,
  closeSlot,
  configureSlot,
  createSlot,
  findSlot,
  history,
  interruptSlot,
  listSlots,
  loadConfig,
  renderRow,
  requestTrust,
  resumeSlot,
  sendMessage,
} from './fm-kirocrew.mjs';

process.title = 'fm-kirocrew';

const POLL_MS = Number(process.env.FM_KIROCREW_POLL_MS || 1000);
const PROGRESS_EVERY_MS = 15000;
const RESUME_EVERY_MS = 30000;
const UNKNOWN_AFTER_MS = 30 * POLL_MS;
const CLOSE_WAIT_MS = 3000;

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--') {
      out._.push(...argv.slice(i + 1));
      break;
    }
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

const args = parseArgs(process.argv.slice(2));
for (const required of ['home', 'task', 'state', 'cwd']) {
  if (typeof args[required] !== 'string' || !args[required]) {
    process.stderr.write(`fm-kirocrew-run: --${required} is required\n`);
    process.exit(2);
  }
}
const cfg = loadConfig({ home: args.home, configDir: typeof args['config-dir'] === 'string' ? args['config-dir'] : '', stateDir: args.state });
const task = args.task;
const slotFile = join(args.state, `${task}.kirocrew-slot`);
const label = typeof args.label === 'string' && args.label ? args.label : 'fm';
const firstMessage = args._.join(' ');
const tty = Boolean(process.stdout.isTTY);

// ---- busy-state writer ------------------------------------------------------

let quitting = false;
// True while the record holds `unknown` from this program's last write.
let recordUnknown = false;

function writeBusy(state, event, turnEnded) {
  if (typeof args['busy-writer'] !== 'string' || typeof args['busy-gen'] !== 'string') return;
  const argv = ['apply', args.state, task, state, '--gen', args['busy-gen'], '--source', 'kirocrew-client', '--event', event];
  if (turnEnded) argv.push('--turn-ended');
  spawnSync(args['busy-writer'], argv, { stdio: 'ignore', timeout: 10000 });
  recordUnknown = state === 'unknown';
}

// Once quit() wrote the final idle, a poll still in flight must not reopen it.
function busy(state, event, { turnEnded = false } = {}) {
  if (!quitting) writeBusy(state, event, turnEnded);
}

let lastProgress = 0;
function progress() {
  if (typeof args['busy-writer'] !== 'string' || typeof args['busy-gen'] !== 'string') return;
  const now = Date.now();
  if (now - lastProgress < PROGRESS_EVERY_MS) return;
  lastProgress = now;
  spawnSync(args['busy-writer'], ['progress', args.state, task, '--gen', args['busy-gen']], { stdio: 'ignore', timeout: 10000 });
}

// ---- Herdr agent registration ----------------------------------------------

const herdrPane = typeof args['herdr-pane'] === 'string' ? args['herdr-pane'] : '';
const herdrSession = typeof args['herdr-session'] === 'string' ? args['herdr-session'] : '';
let herdrState = '';

function herdr(argv) {
  if (herdrSession) argv.push('--session', herdrSession);
  spawnSync(process.env.HERDR_BIN_PATH || 'herdr', argv, { stdio: 'ignore', timeout: 5000 });
}

function herdrReport(state) {
  if (!herdrPane || quitting || state === herdrState) return;
  herdrState = state;
  // A clock-based sequence keeps rising across relaunches of this program.
  herdr(['pane', 'report-agent', '--source', 'fm-kirocrew', '--agent', 'kirocrew', '--state', state, '--seq', String(Date.now()), herdrPane]);
}

function herdrRelease() {
  if (!herdrPane) return;
  herdr(['pane', 'release-agent', '--source', 'fm-kirocrew', '--agent', 'kirocrew', herdrPane]);
}

// ---- pane rendering ---------------------------------------------------------

let status = 'Kiro Crew · starting';
let buffer = '';
let drawn = false;

function promptLine() {
  return `› ${buffer.replace(/\n/g, ' ⏎ ')}`;
}

function clearBottom() {
  if (tty && drawn) process.stdout.write('\x1b[1A\r\x1b[J');
}

function drawBottom() {
  if (!tty) return;
  process.stdout.write(`${status}\n${promptLine()}`);
  drawn = true;
}

function say(text) {
  clearBottom();
  process.stdout.write(`${text}\n`);
  drawBottom();
}

function setStatus(next) {
  if (next === status) return;
  status = next;
  if (!tty) {
    process.stdout.write(`${next}\n`);
    return;
  }
  clearBottom();
  drawBottom();
}

function redrawPrompt() {
  if (tty && drawn) process.stdout.write(`\r\x1b[2K${promptLine()}`);
}

// ---- chat lifecycle ---------------------------------------------------------

function slotName() {
  const clean = (s) => s.toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '');
  return `fm-${clean(label)}-${clean(task)}-${Date.now().toString(36)}`;
}

function recordedSlot() {
  try {
    return readFileSync(slotFile, 'utf8').trim();
  } catch {
    return '';
  }
}

async function ensureSlot() {
  const recorded = recordedSlot();
  if (args.resume && recorded) {
    const live = await findSlot(cfg, recorded);
    if (live) return { slot: live, how: 'adopted' };
    try {
      const resumed = await resumeSlot(cfg, recorded);
      if (resumed) return { slot: resumed, how: 'resumed' };
    } catch (err) {
      if (!(err instanceof CrewError && err.code === 'not_found')) throw err;
    }
  } else if (recorded) {
    // A fresh launch never continues an older incarnation's conversation.
    await closeSlot(cfg, recorded);
  }
  const name = slotName();
  const slot = await createSlot(cfg, name, `firstmate · ${task}`);
  writeFileSync(slotFile, `${slot.key}\n`, { mode: 0o600 });
  return { slot, how: 'created' };
}

let slot;
// printedTotal counts transcript rows (history total); lastSeen is the chat
// list's own counter, which counts more row kinds and only signals a change.
let printedTotal = 0;
let lastSeen = -1;
let turnState = 'idle';

async function catchUp() {
  const page = await history(cfg, slot.key, 50);
  const fresh = page.total - printedTotal;
  if (fresh > 0) for (const row of page.rows.slice(-Math.min(fresh, page.rows.length))) say(renderRow(row));
  printedTotal = page.total;
  return fresh > 0;
}

async function start() {
  const { slot: s, how } = await ensureSlot();
  slot = s;
  await configureSlot(cfg, slot, {
    project: args.cwd,
    model: typeof args.model === 'string' ? args.model : '',
    effort: typeof args.effort === 'string' ? args.effort : '',
  });
  const trust = await requestTrust(cfg, slot.key);
  say(`Kiro Crew chat ${slot.key} (${how}) · agent ${slot.agent} · ${cfg.baseUrl}`);
  if (trust !== 'granted') say('Kiro Crew has not granted firstmate approval control, so each shell or file tool waits for approval in the Crew dashboard.');
  const page = await history(cfg, slot.key, 3);
  for (const row of page.rows) say(renderRow(row));
  printedTotal = page.total;
  herdrReport(firstMessage ? 'working' : 'idle');
  if (firstMessage) {
    await sendMessage(cfg, slot.key, firstMessage);
    // fm-spawn armed the busy record for the launch brief, so the brief's turn
    // is already the busy turn this loop must end.
    turnState = 'working';
  }
}

let lastResume = 0;
let unreachableSince = 0;

async function tick() {
  let current;
  try {
    current = (await listSlots(cfg)).find((s) => s.key === slot.key) || null;
    unreachableSince = 0;
  } catch (err) {
    if (!(err instanceof CrewError && err.code === 'unreachable')) throw err;
    if (!unreachableSince) unreachableSince = Date.now();
    setStatus('Kiro Crew gateway is unreachable · retrying');
    if (!recordUnknown && Date.now() - unreachableSince > UNKNOWN_AFTER_MS) busy('unknown', 'gateway-unreachable');
    return;
  }
  if (!current) {
    if (Date.now() - lastResume < RESUME_EVERY_MS) return;
    lastResume = Date.now();
    try {
      current = await resumeSlot(cfg, slot.key);
    } catch (err) {
      if (!(err instanceof CrewError && err.code === 'not_found')) throw err;
    }
    if (!current) {
      setStatus('Kiro Crew dropped this chat and its transcript cannot be resumed');
      return;
    }
    say('Kiro Crew restarted and dropped this chat; it is resumed from its transcript, and the turn that was running is lost.');
    await configureSlot(cfg, current, { project: args.cwd });
    await requestTrust(cfg, current.key);
    if (turnState !== 'idle') busy('idle', 'chat-lost', { turnEnded: true });
    turnState = 'idle';
    lastSeen = -1;
  }
  slot = current;
  const active = current.state !== 'idle';
  if (current.messages !== lastSeen) {
    lastSeen = current.messages;
    if ((await catchUp()) && active) progress();
  }
  if (active && turnState === 'idle') busy('busy', 'turn-start');
  else if (!active && turnState !== 'idle') busy('idle', 'turn-end', { turnEnded: true });
  else if (recordUnknown) busy(active ? 'busy' : 'idle', 'gateway-reachable');
  turnState = active ? 'working' : 'idle';
  herdrReport(current.state === 'approval' ? 'blocked' : active ? 'working' : 'idle');
  if (current.state === 'approval') setStatus('Kiro Crew is waiting for a tool approval in the Crew dashboard');
  else if (current.state === 'queued') setStatus(`Kiro Crew is working · ${current.queueDepth} queued`);
  else if (active) setStatus('Kiro Crew is working · esc to cancel');
  else setStatus('Kiro Crew · idle');
}

async function submit(text) {
  const line = text.trim();
  if (!line) return;
  if (line === '/quit' || line === '/exit') {
    await quit(0, { close: true });
    return;
  }
  const delivery = await sendMessage(cfg, slot.key, text);
  say(delivery === 'queued' ? '(queued for the next turn)' : '(sent)');
  if (turnState === 'idle') {
    busy('busy', 'user-message');
    turnState = 'working';
  }
}

async function interrupt() {
  if (turnState === 'idle') return;
  await interruptSlot(cfg, slot.key);
  busy('idle', 'interrupted');
  turnState = 'idle';
  say('(interrupted)');
}

async function quit(code, { close }) {
  if (quitting) return;
  quitting = true;
  writeBusy('idle', 'session-end', false);
  herdrRelease();
  if (close && slot) {
    const outcome = await Promise.race([
      closeSlot(cfg, slot.key).then(() => 'closed', (err) => err),
      new Promise((resolve) => setTimeout(resolve, CLOSE_WAIT_MS, 'timeout')),
    ]);
    if (outcome instanceof Error) process.stderr.write(`fm-kirocrew-run: ${outcome.message}\n`);
    else if (outcome === 'timeout') process.stderr.write(`fm-kirocrew-run: Kiro Crew did not confirm the close of ${slot.key} within ${CLOSE_WAIT_MS} ms\n`);
  }
  if (tty) {
    process.stdout.write('\x1b[?2004l\n');
    if (process.stdin.isTTY) process.stdin.setRawMode(false);
  }
  process.exit(code);
}

// ---- input ------------------------------------------------------------------

let lastCtrlC = 0;
let pasting = false;
let queue = Promise.resolve();
const serial = (fn) => {
  queue = queue.then(fn).catch((err) => say(`fm-kirocrew-run: ${err.message}`));
};

function onKeys(chunk) {
  let data = chunk.toString('utf8');
  if (data === '\x1b') {
    serial(interrupt);
    return;
  }
  while (data.length) {
    if (data.startsWith('\x1b[200~')) {
      pasting = true;
      data = data.slice(6);
      continue;
    }
    if (data.startsWith('\x1b[201~')) {
      pasting = false;
      data = data.slice(6);
      continue;
    }
    if (data.startsWith('\x1b')) {
      // Any other escape sequence (arrows, focus reports) is ignored whole.
      const m = data.match(/^\x1b(\[[0-9;?]*[ -/]*[@-~]|O.|.)/);
      data = data.slice(m ? m[0].length : 1);
      continue;
    }
    const ch = data[0];
    data = data.slice(1);
    if (ch === '\r' && !pasting) {
      const text = buffer;
      buffer = '';
      redrawPrompt();
      serial(() => submit(text));
    } else if (ch === '\n' || ch === '\r') buffer += '\n';
    else if (ch === '\x7f' || ch === '\b') buffer = buffer.slice(0, -1);
    else if (ch === '\x15') buffer = '';
    else if (ch === '\x03') {
      if (buffer) buffer = '';
      else if (Date.now() - lastCtrlC < 1000) serial(() => quit(0, { close: true }));
      lastCtrlC = Date.now();
    } else if (ch === '\x04') serial(() => quit(0, { close: true }));
    else if (ch >= ' ' || ch === '\t') buffer += ch;
  }
  redrawPrompt();
}

function readLines() {
  let pending = '';
  process.stdin.on('data', (chunk) => {
    pending += chunk.toString('utf8');
    let nl;
    while ((nl = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, nl);
      pending = pending.slice(nl + 1);
      if (line === '\x1b') serial(interrupt);
      else serial(() => submit(line));
    }
  });
  process.stdin.on('end', () => serial(() => quit(0, { close: false })));
}

// ---- main -------------------------------------------------------------------

// A signal must not wait behind a request that is still in flight.
for (const sig of ['SIGHUP', 'SIGTERM']) process.on(sig, () => quit(0, { close: true }));

try {
  await start();
} catch (err) {
  process.stderr.write(`fm-kirocrew-run: could not start the Kiro Crew chat: ${err.message}\n`);
  busy('idle', 'start-failed');
  process.exit(err instanceof CrewError && err.code === 'unreachable' ? 3 : 1);
}

if (process.stdin.isTTY) {
  process.stdin.setRawMode(true);
  process.stdout.write('\x1b[?2004h');
  process.stdin.on('data', onKeys);
} else {
  readLines();
}
drawBottom();

const loop = async () => {
  if (quitting) return;
  try {
    await tick();
  } catch (err) {
    say(`fm-kirocrew-run: ${err.message}`);
  }
  setTimeout(() => serial(loop), POLL_MS);
};
serial(loop);
