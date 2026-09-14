import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
const [lab, outcome] = process.argv.slice(2);
const sessionFiles = readdirSync(`${lab}/sessions`);
assert.equal(sessionFiles.length, 1, 'evaluation must not create a second session');
const entries = readFileSync(join(lab, 'sessions', sessionFiles[0]), 'utf8').trim().split('\n').map((line) => JSON.parse(line));
const assessments = entries.filter((entry) => entry.type === 'custom_message' && entry.customType === 'fm-worker-completion-v1');
assert.equal(assessments.length, 1, 'one evaluation, no recursive evaluation');
const replies = entries.filter((entry) => entry.type === 'message' && entry.message.role === 'assistant' && entry.message.stopReason === 'stop');
assert.equal(replies.length, 2, 'one final task response and one assessment');
assert.equal(replies[0].message.model, replies[1].message.model);
assert.equal(replies[0].message.provider, replies[1].message.provider);
const receiptDir = `${lab}/home/data/completion/completion`;
const results = readdirSync(receiptDir).filter((file) => file.endsWith('.result.json'));
assert.equal(results.length, 1);
const result = JSON.parse(readFileSync(join(receiptDir, results[0]), 'utf8'));
const status = readFileSync(`${lab}/home/state/completion.status`, 'utf8');
const report = readFileSync(`${lab}/wt/report.md`, 'utf8');
for (const value of ['3', '42', '14']) assert.ok(report.includes(value), `report must contain ${value}`);
if (outcome === 'complete') {
  assert.equal(result.outcome, 'accepted');
  assert.ok(Number.isInteger(result.assessment.confidence) && result.assessment.confidence > 85);
  assert.equal(status, `working: analyzing measurements\ndone: ${result.assessment.summary}\n`);
} else {
  assert.equal(result.outcome, 'not-accepted');
  assert.equal(result.assessment.complete, false);
  assert.equal(status, 'working: analyzing measurements\n');
}
console.log(`assessment: provider=${replies[1].message.provider} model=${replies[1].message.model} complete=${result.assessment.complete} confidence=${result.assessment.confidence}`);
