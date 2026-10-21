import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { TaskBridge } from './server.mjs';
import { repositorySnapshot, repositoryEvidence, workEvidenceResponse } from './work-evidence.mjs';

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'doboo-work-memory-'));
  const codex = join(directory, 'codex'); writeFileSync(codex, '#!/bin/sh\nexit 1\n', { mode: 0o700 });
  const options = { project: directory, directory: join(directory, 'state'), codex };
  const bridge = new TaskBridge(options); bridge.execute = async () => {};
  for (const id of ['doubt', 'spark', 'forge']) bridge.updateCompanion(id, { serverId: bridge.serverId, expectedRevision: 0, memory: '',
    profile: { id, version: 1, name: id, identity: { backstory: id, voice: id }, personality: { traits: [id], instructions: [] } } });
  t.after(() => { bridge.close(); rmSync(directory, { recursive: true, force: true }); });
  const request = parentTaskId => ({ id: randomUUID(), prompt: 'Fix actual code', character: { id: 'doubt', name: 'doubt', version: 1 },
    continuity: { serverId: bridge.serverId, companionRevision: bridge.companion('doubt').revision, ...(parentTaskId ? { parentTaskId } : {}) },
    work: { cast: ['doubt', 'spark', 'forge'].map(id => ({ character: { id, name: id, version: 1 }, companionRevision: bridge.companion(id).revision })) } });
  return { directory, options, bridge, request };
}
function record(task) {
  return { taskId: task.id, project: 'fixture', recordedAt: new Date().toISOString(), summary: 'Validated integer-cents convention',
    decisions: [{ characterId: 'forge', proposalId: 'cents', disposition: 'adopted', rationale: 'Preserve exact monetary arithmetic' }],
    contributions: [{ characterId: 'forge', proposals: [{ id: 'cents', summary: 'Keep cents as integers', paths: ['money.js'] }] }],
    evidence: { commands: [{ itemId: 'test', command: 'node --test', exitCode: 0, status: 'completed', purpose: 'Arithmetic regression' }], fileChanges: [] },
    contextDigest: task._execution.work.contextDigest, remainingRisks: [] };
}
test('work request freezes every member, forbids busy profile mutation, and detects changed retry identities', async t => {
  const { bridge, request } = fixture(t); const input = request(); const task = await bridge.submit(input);
  assert.equal(task._execution.work.cast.length, 3); assert.equal(task.continuity.workCast.length, 3);
  assert.equal(await bridge.submit(input), task);
  await assert.rejects(bridge.submit({ ...input, work: { cast: input.work.cast.slice(0, 2) } }), /같은 요청/);
  const spark = bridge.companion('spark');
  assert.throws(() => bridge.updateCompanion('spark', { serverId: bridge.serverId, expectedRevision: 1, profile: spark.profile, memory: 'new' }), /진행 중/);
});
test('structured decisions and runtime checks survive restart and enter all new character contexts', async t => {
  const { options, bridge, request } = fixture(t); const first = await bridge.submit(request());
  bridge.change(first, { status: 'completed', result: 'Implemented', workRecord: record(first) });
  const restarted = new TaskBridge(options); restarted.execute = async () => {}; t.after(() => restarted.close());
  const next = await restarted.submit(request(first.id));
  const remembered = next._execution.work.snapshot.history[0];
  assert.equal(remembered.taskId, first.id);
  assert.equal(remembered.workRecord.decisions[0].proposal, 'Keep cents as integers');
  assert.equal(remembered.workRecord.verification[0].exitCode, 0);
  assert.equal(remembered.workRecord.cast.length, 3);
  assert.equal(next.continuity.historyCount, 1);
});
test('large work evidence keeps the immediate adopted decision and verification in the next task', async t => {
  const { bridge, request } = fixture(t);
  const first = await bridge.submit({ ...request(), prompt: 'p'.repeat(8000) });
  const full = record(first);
  full.summary = 's'.repeat(8000);
  full.decisions = Array.from({ length: 12 }, (_, index) => ({ characterId: ['doubt', 'forge', 'spark'][Math.floor(index / 4)],
    proposalId: `p${index}`, disposition: index === 11 ? 'adopted' : 'deferred', rationale: 'r'.repeat(4000) }));
  full.contributions = ['doubt', 'forge', 'spark'].map(characterId => ({ characterId,
    proposals: full.decisions.filter(decision => decision.characterId === characterId).map(decision => ({
      id: decision.proposalId, summary: 'Use exact cents. '.repeat(200), paths: Array.from({ length: 20 }, (_, i) => `${'x'.repeat(990)}${i}.js`),
    })) }));
  full.evidence.commands = Array.from({ length: 30 }, (_, index) => ({ itemId: `test-${index}`, command: 'c'.repeat(4000),
    exitCode: 0, status: 'completed', purpose: 'v'.repeat(2000) }));
  full.evidence.repository = { changes: Array.from({ length: 5000 }, (_, index) => ({ path: `code-${index}.js`, beforeSHA256: 'a'.repeat(64), afterSHA256: 'b'.repeat(64) })) };
  full.remainingRisks = Array.from({ length: 12 }, () => 'risk'.repeat(500));
  const original = structuredClone(full);
  bridge.change(first, { status: 'completed', result: 'done'.repeat(2000), workRecord: full });
  const next = await bridge.submit(request(first.id));
  const memory = next._execution.work.snapshot.history[0]?.workRecord;
  assert.equal(memory?.taskId, first.id);
  assert.equal(memory.truncated, true);
  assert.equal(next.continuity.historyTruncated, true);
  assert(JSON.stringify(memory).length <= 24000);
  assert(memory.decisions.some(decision => decision.proposalId === 'p11' && decision.disposition === 'adopted'));
  assert(memory.verification.some(check => check.itemId === 'test-0' && check.exitCode === 0));
  assert(memory.omitted.changedFiles > 0);
  assert.deepEqual(first.workRecord, original);
});
test('shortened details are disclosed even when the overall memory is small', async t => {
  const { bridge, request } = fixture(t); const first = await bridge.submit(request());
  const full = record(first);
  full.decisions[0].rationale = 'r'.repeat(1001);
  full.contributions[0].proposals[0].summary = 'p'.repeat(1001);
  full.evidence.commands[0].command = 'c'.repeat(1001);
  bridge.change(first, { status: 'completed', workRecord: full });
  const next = await bridge.submit(request(first.id));
  const memory = next._execution.work.snapshot.history[0].workRecord;
  assert.equal(memory.truncated, true);
  assert.equal(next.continuity.historyTruncated, true);
  assert.equal(memory.omitted.detailTextMayBeShortened, true);
  assert.equal(memory.omitted.decisions, 0);
  assert.equal(memory.decisions[0].rationale.length, 1000);
  assert.equal(memory.decisions[0].proposal.length, 1000);
  assert.equal(memory.verification[0].command.length, 1000);
  assert.equal(first.workRecord.decisions[0].rationale.length, 1001);
});
test('changed secondary memory or cast membership invalidates old continuation', async t => {
  const { bridge, request } = fixture(t); const first = await bridge.submit(request());
  bridge.change(first, { status: 'completed', workRecord: record(first) });
  const changed = request(first.id); changed.work.cast.pop();
  await assert.rejects(bridge.submit(changed), /참여 캐릭터/);
  const spark = bridge.companion('spark');
  bridge.updateCompanion('spark', { serverId: bridge.serverId, expectedRevision: spark.revision, profile: spark.profile, memory: 'forgotten' });
  await assert.rejects(bridge.submit(request(first.id)), /참여 캐릭터/);
});
test('failed work is never accepted as continuation and failed persistence rolls back admission/outcome', async t => {
  const { bridge, request } = fixture(t); const first = await bridge.submit(request());
  bridge.change(first, { status: 'failed' });
  await assert.rejects(bridge.submit(request(first.id)), /맥락/);
  const second = await bridge.submit(request());
  bridge.persist = () => { throw Error('disk full'); };
  assert.throws(() => bridge.change(second, { status: 'completed', workRecord: record(second) }), /disk full/);
  assert.equal(second.workRecord, undefined); assert.equal(second.status, 'queued');
  second.status = 'failed';
  const next = request(); await assert.rejects(bridge.submit(next), /disk full/);
  assert.equal(bridge.jobs.has(next.id), false);
});
test('unregistered, stale, duplicate, single and host-missing casts are rejected before execution', async t => {
  const { bridge, request } = fixture(t);
  for (const modify of [r => r.work.cast[1].companionRevision++, r => r.work.cast[1].character.id = 'unknown',
    r => r.work.cast[1] = r.work.cast[0], r => r.work.cast.splice(1), r => r.work.cast.shift(), r => delete r.continuity]) {
    const input = request(); modify(input); await assert.rejects(bridge.submit(input)); assert.equal(bridge.jobs.has(input.id), false);
  }
});
test('host repository observations distinguish actual edits including untracked files', t => {
  const { directory } = fixture(t); spawnSync('git', ['init', '-q', directory]);
  writeFileSync(join(directory, '.gitignore'), 'state/\ncodex\n');
  writeFileSync(join(directory, 'code.js'), 'export const n = 1;');
  spawnSync('git', ['-C', directory, 'add', '.']);
  const before = repositorySnapshot(directory);
  writeFileSync(join(directory, 'code.js'), 'export const n = 2;');
  writeFileSync(join(directory, 'new-test.js'), 'test();');
  const evidence = repositoryEvidence(before, repositorySnapshot(directory));
  assert.equal(evidence.available, true); assert.equal(evidence.truncated, false);
  assert.deepEqual(evidence.changes.map(change => change.path), ['code.js', 'new-test.js']);
  assert.notEqual(evidence.changes[0].beforeSHA256, evidence.changes[0].afterSHA256);
  assert.equal(evidence.changes[1].beforeSHA256, null);
  assert.match(evidence.changes[1].afterSHA256, /^[a-f0-9]{64}$/);
});

test('host evidence tool exposes actual successful IDs only to the current parent turn', () => {
  const task = { work: {}, status: 'running', threadId: 'parent', turnId: 'turn', commands: [
    { itemId: 'good', threadId: 'parent', turnId: 'turn', command: 'node --test', status: 'completed', exitCode: 0, output: 'pass' },
    { itemId: 'fail', threadId: 'parent', turnId: 'turn', status: 'failed', exitCode: 1 },
    { itemId: 'other', threadId: 'child', turnId: 'turn', status: 'completed', exitCode: 0 },
  ] };
  const params = { threadId: 'parent', turnId: 'turn', namespace: null, tool: 'doboo_work_evidence', arguments: {} };
  const response = workEvidenceResponse(task, params);
  assert.equal(response.success, true);
  const evidence = JSON.parse(response.contentItems[0].text);
  assert.deepEqual(evidence.commands.map(command => command.itemId), ['good']);
  assert.equal(evidence.commands[0].output, undefined);
  for (const bad of [{ threadId: 'child' }, { turnId: 'other' }, { tool: 'write' }, { arguments: { run: 'anything' } }, { namespace: 'mcp' }])
    assert.throws(() => workEvidenceResponse(task, { ...params, ...bad }));
  assert.throws(() => workEvidenceResponse({ ...task, cancelRequested: true }, params));
});
