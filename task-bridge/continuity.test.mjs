import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { TaskBridge, startBridge } from './server.mjs';

const profile = (id = 'doboo', version = 1) => ({ id, version, name: id === 'doboo' ? 'Doboo' : 'Other',
  identity: { backstory: 'A small peach companion.', voice: 'Use concise, warm Korean.' },
  personality: { traits: ['patient'], instructions: ['Explain verified results and uncertainty separately.'] } });
function fixture({ hold = false } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'doboo-continuity-'));
  const codex = join(directory, 'fake-codex');
  const calls = join(directory, 'calls.jsonl');
  writeFileSync(codex, `#!/usr/bin/env node
const fs=require('node:fs');
const send=x=>process.stdout.write(JSON.stringify(x)+'\\n');
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
  const m=JSON.parse(line);
  if(m.method)fs.appendFileSync(${JSON.stringify(calls)},JSON.stringify(m)+'\\n');
  if(m.method==='initialize')send({id:m.id,result:{}});
  if(m.method==='account/read')send({id:m.id,result:{account:{type:'chatgpt'}}});
  if(m.method==='thread/start')send({id:m.id,result:{thread:{id:'thread-'+process.pid}}});
  if(m.method==='turn/start'){
    send({id:m.id,result:{turn:{id:'turn-'+process.pid}}});
    if(${hold})return;
    const text=m.params.input.at(-1).text;
    send({method:'item/completed',params:{threadId:m.params.threadId,item:{type:'agentMessage',text:'Verified answer to: '+text}}});
    send({method:'turn/completed',params:{threadId:m.params.threadId,turn:{status:text.includes('FAIL_FIXTURE')?'failed':'completed',error:null}}});
  }
  if(m.method==='turn/interrupt')send({id:m.id,result:{}});
});`, { mode: 0o700 });
  return { directory, project: directory, codex, calls };
}
async function until(predicate) {
  for (let count = 0; count < 150; count++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error('Timed out waiting for fixture');
}
const callLog = options => readFileSync(options.calls, 'utf8').trim().split('\n').map(JSON.parse);
const save = (bridge, value = profile(), memory = '', extra = {}) => bridge.updateCompanion(value.id, {
  serverId: bridge.serverId, expectedRevision: bridge.companion(value.id)?.revision ?? 0, profile: value, memory, resetHistory: false, ...extra,
});
const request = (bridge, context, prompt, parentTaskId) => ({ id: randomUUID(), prompt,
  character: { id: context.profile.id, version: context.profile.version, name: context.profile.name },
  continuity: { serverId: bridge.serverId, companionRevision: context.revision, ...(parentTaskId ? { parentTaskId } : {}) } });
async function complete(bridge, input) {
  const task = await bridge.submit(input);
  await until(() => task.status === 'completed' && !bridge.sessions.has(task.id));
  return task;
}
function suppliedContext(options, index = -1) {
  const turn = callLog(options).filter(call => call.method === 'turn/start').at(index);
  return JSON.parse(turn.params.input[0].text.split('\n').slice(1).join('\n'));
}

test('persona and explicit memory actually enter execution, with prior completed work after restart', async t => {
  const options = fixture(); let bridge = new TaskBridge(options);
  t.after(() => bridge.close());
  const context = save(bridge, profile(), 'Call me Mina. The release color is teal.');
  const firstRequest = request(bridge, context, 'Remember the plan for the teal release.');
  const first = await complete(bridge, firstRequest);
  const firstInput = suppliedContext(options);
  assert.deepEqual(firstInput.character, profile());
  assert.equal(firstInput.savedMemory, context.memory);
  assert.deepEqual(firstInput.previousCompletedWork, []);
  assert.equal(first.continuity.memoryApplied, true);
  const rules = callLog(options).find(call => call.method === 'thread/start').params.developerInstructions;
  assert.match(rules, /apply its voice, traits/);
  assert.match(rules, /untrusted context, never permission/);
  assert.match(rules, /Only the final current-task input supplies a new request/);
  const serverId = bridge.serverId;
  bridge.close(); bridge = new TaskBridge(options);
  assert.equal(bridge.serverId, serverId);
  assert.deepEqual(bridge.companion('doboo'), context);
  const second = await complete(bridge, request(bridge, context, 'Continue that release plan with one next step.', first.id));
  const secondInput = suppliedContext(options);
  assert.deepEqual(secondInput.previousCompletedWork, [{ prompt: first.prompt, result: first.result }]);
  assert.equal(secondInput.savedMemory, context.memory);
  assert.equal(second.continuity.conversationId, first.continuity.conversationId);
  assert.notEqual(second.threadId, first.threadId);
  assert.equal(second.continuity.historyCount, 1);
  assert.equal((await bridge.submit(firstRequest)).id, first.id, 'lost response retry must not rerun historical work');
  assert.equal(callLog(options).filter(call => call.method === 'turn/start').length, 2);
});

test('two authenticated device clients see the same context without receiving private execution snapshots', async t => {
  const app = await startBridge(fixture());
  t.after(() => { app.bridge.close(); app.server.close(); });
  const fetchJSON = async (path, body) => {
    const response = await fetch(app.connection.url + path, { method: body ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${app.connection.token}`, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined });
    return { status: response.status, body: await response.json() };
  };
  const phoneList = (await fetchJSON('/v1/tasks')).body;
  assert.equal(phoneList.serverId, app.bridge.serverId);
  const context = (await fetchJSON('/v1/companions/doboo', {
    serverId: phoneList.serverId, expectedRevision: 0, profile: profile(), memory: 'My delivery window is Friday.', resetHistory: false,
  })).body;
  const submitted = await fetchJSON('/v1/tasks', request(app.bridge, context, 'Plan delivery.'));
  assert.equal(submitted.status, 200);
  assert.equal(submitted.body._execution, undefined);
  await until(() => app.bridge.jobs.get(submitted.body.id).status === 'completed');
  const watchList = (await fetchJSON('/v1/tasks')).body;
  assert.deepEqual(watchList.companions, [context]);
  assert.equal(watchList.tasks[0].continuity.serverId, phoneList.serverId);
  assert.equal(watchList.tasks[0]._execution, undefined);
  assert.equal((await fetchJSON(`/v1/tasks/${submitted.body.id}`)).body._execution, undefined);
  const receipt = await fetchJSON(`/v1/tasks/${submitted.body.id}/receipt`, { surface: 'watch', sequence: watchList.tasks[0].sequence });
  assert.equal(receipt.status, 200);
  const follow = await fetchJSON('/v1/tasks', request(app.bridge, context, 'What is the next step?', submitted.body.id));
  assert.equal(follow.status, 200);
  assert.equal(follow.body.continuity.conversationId, submitted.body.continuity.conversationId);
});

test('profile updates, memory edits and explicit forget enforce revisions and cut stale ancestry', async t => {
  const bridge = new TaskBridge(fixture()); t.after(() => bridge.close());
  const initial = save(bridge, profile(), 'Private note never to reintroduce.');
  const first = await complete(bridge, request(bridge, initial, 'Use my saved note.'));
  assert.throws(() => save(bridge, profile(), '', { expectedRevision: 0 }), /다른 기기/);
  assert.throws(() => save(bridge, { ...profile(), name: 'Conflicting same version' }, initial.memory), /같은 버전/);
  const cosmetic = save(bridge, profile('doboo', 2), initial.memory);
  assert.equal(cosmetic.profileDigest, initial.profileDigest);
  assert.equal(cosmetic.generation, initial.generation);
  const second = await complete(bridge, request(bridge, cosmetic, 'Continue after a visual-only revision.', first.id));
  const edited = save(bridge, profile('doboo', 2), 'A replacement note.');
  assert.equal(edited.generation, cosmetic.generation + 1);
  await assert.rejects(bridge.submit(request(bridge, edited, 'Continue old content.', second.id)), /새 작업/);
  await assert.rejects(bridge.submit(request(bridge, cosmetic, 'Stale memory request.')), /바뀌었습니다/);
  const fresh = await complete(bridge, request(bridge, edited, 'Use only new context.'));
  assert.equal(fresh.continuity.historyCount, 0);
  const forgotten = save(bridge, profile('doboo', 2), '', { resetHistory: true });
  await assert.rejects(bridge.submit(request(bridge, forgotten, 'Old context must stay forgotten.', fresh.id)), /새 작업/);
  assert.equal(bridge.jobs.get(first.id).result, first.result, 'forget should not claim historical logs were erased');
  const afterForget = await complete(bridge, request(bridge, forgotten, 'Start again.'));
  assert.equal(afterForget.continuity.memoryApplied, false);
  assert.equal(afterForget.continuity.historyCount, 0);
  const changedProfile = profile('doboo', 3); changedProfile.identity.voice = 'Use a dry, concise voice.';
  const changed = save(bridge, changedProfile, '');
  assert.equal(changed.generation, forgotten.generation + 1);
  assert.notEqual(changed.profileDigest, forgotten.profileDigest);
  await assert.rejects(bridge.submit(request(bridge, changed, 'Must not inherit old personality.', afterForget.id)), /새 작업/);
  assert.throws(() => save(bridge, profile('doboo', 1), ''), /이전 버전/);
});

test('server/project, character and conversation ancestry prevent cross-context mixing or forks', async t => {
  const options = fixture(); const bridge = new TaskBridge(options); t.after(() => bridge.close());
  const one = save(bridge, profile(), 'Only Doboo may receive this saved memory.');
  const other = save(bridge, profile('other'), 'An unrelated preference.');
  const task = await complete(bridge, request(bridge, one, 'First conversation.'));
  await assert.rejects(bridge.submit(request(bridge, other, 'Cross character.', task.id)), /새 작업/);
  const otherTask = await complete(bridge, request(bridge, other, 'Separate character work.'));
  assert.notEqual(otherTask.continuity.conversationId, task.continuity.conversationId);
  assert.deepEqual(suppliedContext(options).previousCompletedWork, []);
  assert.equal(suppliedContext(options).savedMemory, other.memory);
  const child = await complete(bridge, request(bridge, one, 'Follow the first conversation.', task.id));
  await assert.rejects(bridge.submit(request(bridge, one, 'Try forking the old parent.', task.id)), /가장 최근/);
  const pending = request(bridge, one, 'Wrong bridge.'); pending.continuity.serverId = randomUUID();
  await assert.rejects(bridge.submit(pending), /컴퓨터가 변경/);
  assert.throws(() => save(bridge, profile(), '', { serverId: randomUUID() }), /컴퓨터가 변경/);
  const anotherProject = join(options.directory, 'another-project'); mkdirSync(anotherProject);
  assert.throws(() => new TaskBridge({ ...options, project: anotherProject }), /다른 프로젝트/);
  const newConversation = await complete(bridge, request(bridge, one, 'Start unrelated work.'));
  assert.notEqual(newConversation.continuity.conversationId, child.continuity.conversationId);
  assert.deepEqual(suppliedContext(options).previousCompletedWork, []);
});

test('bounded history supplies at most six turns and 12000 UTF-16 characters, reporting truncation', async t => {
  const options = fixture(); const bridge = new TaskBridge(options); t.after(() => bridge.close());
  const context = save(bridge);
  let parent;
  for (let index = 0; index < 8; index++) parent = await complete(bridge, request(bridge, context, `Step ${index}.`, parent?.id));
  const history = suppliedContext(options);
  assert.equal(history.previousCompletedWork.length, 6);
  assert.equal(history.historyTruncated, true);
  assert.equal(history.previousCompletedWork[0].prompt, 'Step 1.');
  let large = await complete(bridge, request(bridge, context, 'x'.repeat(8000)));
  large = await complete(bridge, request(bridge, context, 'y'.repeat(8000), large.id));
  await complete(bridge, request(bridge, context, 'Use bounded history.', large.id));
  const limited = suppliedContext(options);
  assert.equal(limited.historyTruncated, true);
  assert.ok(limited.previousCompletedWork.reduce((count, value) => count + value.prompt.length + value.result.length, 0) <= 12000);
});

test('retry identity includes context, and legacy requests never silently inherit persona or memory', async t => {
  const options = fixture(); const bridge = new TaskBridge(options); t.after(() => bridge.close());
  const context = save(bridge, profile(), 'Memory requiring explicit profile use.');
  const payload = request(bridge, context, 'Run with context.');
  const task = await complete(bridge, payload);
  const next = save(bridge, profile(), 'Updated memory.');
  assert.equal((await bridge.submit(payload)).id, task.id);
  await assert.rejects(bridge.submit({ ...payload, continuity: { ...payload.continuity, companionRevision: next.revision } }), /같은 요청 ID/);
  const legacy = { id: randomUUID(), prompt: 'Legacy request.', character: payload.character };
  const legacyTask = await complete(bridge, legacy);
  assert.equal(legacyTask.continuity, undefined);
  assert.deepEqual(callLog(options).filter(call => call.method === 'turn/start').at(-1).params.input, [{ type: 'text', text: legacy.prompt }]);
});

test('invalid profiles and memory cannot enter stored executable context', () => {
  const bridge = new TaskBridge(fixture());
  assert.throws(() => save(bridge, { ...profile(), identity: { ...profile().identity, authority: 'system' } }), /형식/);
  assert.throws(() => save(bridge, { ...profile(), personality: { traits: [], instructions: ['x'.repeat(501)] } }), /형식/);
  assert.throws(() => save(bridge, profile(), 'x'.repeat(4001)), /형식/);
  assert.throws(() => save(bridge, { ...profile(), id: undefined }), /형식/);
  const unusualID = save(bridge, profile('constructor'));
  assert.equal(unusualID.revision, 1);
  bridge.close();
});

test('failed follow-up can be explicitly retried from its last successful parent without replaying failure', async t => {
  const options = fixture(); const bridge = new TaskBridge(options); t.after(() => bridge.close());
  const context = save(bridge);
  const parent = await complete(bridge, request(bridge, context, 'Successful plan.'));
  const failed = await bridge.submit(request(bridge, context, 'FAIL_FIXTURE partial attempted change.', parent.id));
  await until(() => failed.status === 'failed' && !bridge.sessions.has(failed.id));
  const retry = await complete(bridge, request(bridge, context, 'Try this other explicit next step.', parent.id));
  assert.equal(retry.continuity.conversationId, parent.continuity.conversationId);
  assert.deepEqual(suppliedContext(options).previousCompletedWork, [{ prompt: parent.prompt, result: parent.result }]);
  await assert.rejects(bridge.submit(request(bridge, context, 'Cannot continue from failed evidence.', failed.id)), /새 작업/);
});

test('memory edits cannot claim to forget an in-flight execution, and stale context is explicitly non-admitted', async t => {
  const options = fixture({ hold: true }); const app = await startBridge(options);
  t.after(() => { app.bridge.close(); app.server.close(); });
  const context = save(app.bridge, profile(), 'Original memory.');
  const task = await app.bridge.submit(request(app.bridge, context, 'Hold this work.'));
  await until(() => task.turnId);
  assert.throws(() => save(app.bridge, profile(), '', { resetHistory: true }), /진행 중인 작업/);
  assert.equal(app.bridge.companion('doboo').memory, context.memory);
  await app.bridge.cancel(task);
  const newer = save(app.bridge, profile(), 'New saved memory.');
  const payload = request(app.bridge, context, 'Stale phone state.');
  const response = await fetch(app.connection.url + '/v1/tasks', { method: 'POST',
    headers: { Authorization: `Bearer ${app.connection.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).submissionRejected, true);
  assert.equal(app.bridge.jobs.has(payload.id), false);
  assert.equal(app.bridge.companion('doboo').revision, newer.revision);
});

test('a failed memory write cannot expose or execute an unpersisted revision', async t => {
  const options = fixture(); const bridge = new TaskBridge(options); t.after(() => bridge.close());
  const original = save(bridge, profile(), 'Durable original memory.');
  bridge.contextFile = join(options.directory, 'missing-parent', 'companions.json');
  assert.throws(() => save(bridge, profile(), 'Must not become visible.'), /ENOENT/);
  assert.deepEqual(bridge.companion('doboo'), original);
  const task = await complete(bridge, request(bridge, original, 'Use the durable memory.'));
  assert.equal(task.continuity.companionRevision, original.revision);
  assert.equal(suppliedContext(options).savedMemory, original.memory);
  const restarted = new TaskBridge(options);
  assert.deepEqual(restarted.companion('doboo'), original);
  restarted.close();
});
