import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, appendFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { WorkCast, prepareWorkCastWorkspace, workConfig, workRules, workSchema } from './work-cast.mjs';

const model = 'preserve-user-model'; const effort = 'xhigh';
function fixture(t) {
  const snapshot = { project: '/actual/project', history: [{ taskId: 'previous-work', summary: 'Adopted a narrow change and checked it.' }] };
  const task = { id: 'work-task', threadId: 'parent', turnId: null, prompt: '실제 코드를 수정하고 검증해 주세요. 문서와 커밋은 금지합니다.', commands: [],
    _execution: { work: { cast: [
      { id: 'doboo', version: 2, name: '도부', identity: { voice: '차분히 설명', backstory: 'quoted "character"\nUnicode 눈' } },
      { id: 'mori', version: 3, name: '모리', identity: { voice: '신중히 점검', backstory: 'Independent perspective' } },
    ], snapshot, contextDigest: createHash('sha256').update(JSON.stringify(snapshot)).digest('hex') } } };
  const binding = prepareWorkCastWorkspace(task); t.after(() => binding.cleanup());
  const cast = new WorkCast(task, model, effort, binding); const metadata = new Map();
  const childValues = task._execution.work.cast.map(profile => ({ characterId: profile.id, contextDigest: task._execution.work.contextDigest,
    proposals: [{ id: 'p1', summary: `${profile.id} useful code change`, rationale: 'Observed repository behavior.', paths: ['src/code.mjs'] }], rememberedTaskIds: ['previous-work'] }));
  const parentValue = { summary: 'Applied the chosen change and verified behavior.', decisions: [
    { characterId: 'doboo', proposalId: 'p1', disposition: 'adopted', rationale: 'Fixes the observed behavior.' },
    { characterId: 'mori', proposalId: 'p1', disposition: 'deferred', rationale: 'Useful follow-up outside this task.' },
  ], validation: [{ commandItemId: 'test-command', purpose: 'Check the changed behavior.' }], remainingRisks: [] };
  const observe = (method, threadId, params) => cast.observe(method, { threadId, ...params });
  const command = (threadId, turnId, id, additions = {}) => {
    const item = { type: 'commandExecution', id, command: threadId === 'parent' ? 'node --test src/code.test.mjs' : 'rg -n behavior src/code.mjs',
      cwd: '/actual/project', status: 'completed', exitCode: 0, aggregatedOutput: threadId === 'parent' ? '1 test passed' : '12: observed behavior', ...additions };
    observe('item/completed', threadId, { turnId, item });
    if (threadId === 'parent') task.commands.push({ itemId: id, threadId, turnId, command: item.command, status: item.status, exitCode: item.exitCode, output: item.aggregatedOutput });
    return item;
  };
  const done = (threadId, turnId, value, extras = []) => {
    const item = { type: 'agentMessage', phase: 'final_answer', id: `final-${threadId}`, text: JSON.stringify(value) };
    observe('item/completed', threadId, { turnId, item });
    observe('turn/completed', threadId, { turn: { id: turnId, rootTurnId: 'parent-turn', status: 'completed', items: [...extras, item] } });
  };
  const start = () => {
    observe('turn/started', 'parent', { turn: { id: 'parent-turn', rootTurnId: 'parent-turn' } });
    task._execution.work.cast.forEach((profile, index) => {
      const threadId = `child-${index}`; const turnId = `child-turn-${index}`;
      const path = `/root/work_${index}_${profile.id}`;
      const role = binding.roles[index];
      metadata.set(threadId, { id: threadId, parentThreadId: 'parent', ephemeral: true, forkedFromId: null, model, reasoningEffort: effort, agentRole: role.name,
        source: { subAgent: { thread_spawn: { parent_thread_id: 'parent', depth: 1, agent_path: path, agent_role: role.name } } } });
      observe('item/started', 'parent', { turnId: 'parent-turn', item: { type: 'subAgentActivity', id: `spawn-${index}`, kind: 'started', agentThreadId: threadId,
        agentPath: path, model, reasoningEffort: effort } });
      observe('turn/started', threadId, { turn: { id: turnId, rootTurnId: 'parent-turn' } });
    });
  };
  const complete = () => {
    start();
    childValues.forEach((value, index) => {
      command(`child-${index}`, `child-turn-${index}`, `read-${index}`);
      done(`child-${index}`, `child-turn-${index}`, value);
    });
    const cmd = command('parent', 'parent-turn', 'test-command');
    done('parent', 'parent-turn', parentValue, [cmd]);
  };
  const rpc = async (method, params) => { assert.equal(method, 'thread/read'); return { thread: metadata.get(params.threadId) }; };
  return { task, binding, cast, metadata, childValues, parentValue, observe, command, done, start, complete, rpc };
}

test('private roles preserve immutable per-character inputs without changing the project cwd or parent code tool settings', t => {
  const f = fixture(t);
  assert.equal(f.binding.cwd, undefined);
  assert.equal(workConfig['features.multi_agent'], true);
  assert.equal(workConfig['features.shell_tool'], undefined);
  assert.equal(workConfig['features.unified_exec'], undefined);
  assert.match(workRules, /Only the current user task/);
  assert.match(workRules, /call the host-provided doboo_work_evidence/);
  assert.match(workRules, /chunk_id is not a command item ID/);
  assert.ok(workSchema.properties.validation.minItems > 0);
  const jobs = JSON.parse(f.cast.input()[0].text.split('\n').slice(1).join('\n'));
  jobs.forEach((job, index) => {
    const role = f.binding.roles[index]; const contents = readFileSync(role.path, 'utf8');
    const instructions = JSON.parse(/^developer_instructions = (.+)$/m.exec(contents)[1]);
    assert.equal(instructions, role.instructions);
    assert.ok(instructions.includes(JSON.stringify(f.task._execution.work.cast[index])));
    assert.ok(instructions.includes(JSON.stringify(f.task._execution.work.snapshot)));
    assert.ok(instructions.includes(JSON.stringify(f.task.prompt)));
    assert.match(contents, /sandbox_mode = "read-only"/);
    assert.match(contents, /multi_agent = false/);
    assert.equal(job.agent_type, role.name); assert.equal(job.fork_turns, 'none');
    assert.equal(job.model, model); assert.equal(job.reasoning_effort, effort);
    assert.ok(job.message.length < 300); assert.ok(!job.message.includes('Own character profile'));
  });
  f.binding.cleanup(); assert.equal(existsSync(f.binding.directory), false);
});

test('native child advice, host decisions and successful parent evidence validate with their actual runtime sources', async t => {
  const f = fixture(t); f.complete();
  const result = await f.cast.validate(f.rpc);
  assert.deepEqual(result.value, f.parentValue);
  assert.equal(result.execution.coordinatorThreadId, 'parent');
  assert.equal(result.execution.coordinatorResult, JSON.stringify(f.parentValue));
  assert.equal(result.execution.coordinatorFinalMessageId, 'final-parent');
  assert.equal(result.execution.coordinatorTurnId, 'parent-turn');
  assert.equal(result.execution.agents.length, 2);
  assert.equal(new Set(result.execution.agents.map(agent => agent.threadId)).size, 2);
  assert.deepEqual(result.execution.sourceTaskIds, ['previous-work']);
  assert.equal(result.execution.parentCommands.length, 1, 'completed-turn replay must not duplicate command evidence');
  result.execution.agents.forEach((agent, index) => {
    assert.equal(agent.model, model); assert.equal(agent.reasoningEffort, effort);
    assert.equal(agent.instructionsDigest, f.binding.roles[index].instructionsDigest);
    assert.equal(agent.profileDigest, f.binding.roles[index].profileDigest);
    assert.equal(agent.finalMessageId, `final-child-${index}`);
    assert.deepEqual(result.contributions[index].proposals, f.childValues[index].proposals);
    assert.equal(result.contributions[index].commands[0].itemId, `read-${index}`);
    assert.equal(result.contributions[index].commands[0].cwd, '/actual/project');
  });
});

test('forged child provenance, changed role files and changed profiles fail closed', async t => {
  const changes = [
    thread => { thread.parentThreadId = 'unrelated-parent'; },
    thread => { thread.model = 'cheaper-model'; },
    thread => { thread.reasoningEffort = 'low'; },
    thread => { thread.forkedFromId = 'inherited-thread'; },
    thread => { thread.ephemeral = false; },
    thread => { thread.source.subAgent.thread_spawn.depth = 2; },
    thread => { thread.source.subAgent.thread_spawn.agent_path = '/root/another-character'; },
    thread => { thread.source.subAgent.thread_spawn.agent_role = 'forged-role'; },
    thread => { thread.agentRole = 'forged-role'; },
  ];
  for (const change of changes) {
    const f = fixture(t); f.complete(); change(f.metadata.get('child-0'));
    await assert.rejects(f.cast.validate(f.rpc), /메타데이터/);
  }
  const changedRole = fixture(t); changedRole.complete(); appendFileSync(changedRole.binding.roles[0].path, '\n# modified\n');
  await assert.rejects(changedRole.cast.validate(changedRole.rpc), /역할 또는 성격/);
  const changedProfile = fixture(t); changedProfile.complete(); changedProfile.task._execution.work.cast[0].name = 'Replacement';
  await assert.rejects(changedProfile.cast.validate(changedProfile.rpc), /역할 또는 성격/);
  const changedContext = fixture(t); changedContext.complete(); changedContext.task._execution.work.snapshot.history[0].summary = 'Replacement history';
  await assert.rejects(changedContext.cast.validate(changedContext.rpc), /역할 또는 성격/);
});

test('proposals and remembered work must belong to the actual child and frozen context', async t => {
  const changes = [
    value => { value.characterId = 'another-character'; },
    value => { value.contextDigest = 'forged-digest'; },
    value => { value.rememberedTaskIds = ['imagined-history']; },
    value => { value.rememberedTaskIds = ['previous-work', 'previous-work']; },
    value => { value.proposals.push(structuredClone(value.proposals[0])); },
    value => { value.proposals = []; },
    value => { value.proposals[0].paths = ['/outside/project']; },
    value => { value.proposals[0].paths = ['../outside/project']; },
    value => { value.proposals[0].paths = []; },
    value => { value.proposals = [null]; },
    value => { value.execution = { threadId: 'invented' }; },
  ];
  for (const change of changes) {
    const f = fixture(t); change(f.childValues[0]); f.complete();
    await assert.rejects(f.cast.validate(f.rpc), /검증 실패/);
  }
});

test('each code advisor needs successful project inspection and native activity replay preserves completed state', async t => {
  for (const additions of [{ cwd: '/another/project' }, { status: 'failed', exitCode: 1 }]) {
    const f = fixture(t); f.start();
    f.childValues.forEach((value, index) => {
      f.command(`child-${index}`, `child-turn-${index}`, `read-${index}`, index === 0 ? additions : {});
      f.done(`child-${index}`, `child-turn-${index}`, value);
    });
    f.command('parent', 'parent-turn', 'test-command'); f.done('parent', 'parent-turn', f.parentValue);
    await assert.rejects(f.cast.validate(f.rpc), /프로젝트 읽기 실행 증거/);
  }
  const f = fixture(t); f.complete();
  f.observe('item/completed', 'parent', { turnId: 'parent-turn', item: { type: 'subAgentActivity', id: 'spawn-0', kind: 'started', agentPath: '/root/work_0_doboo', agentThreadId: 'child-0', model, reasoningEffort: effort } });
  const result = await f.cast.validate(f.rpc);
  assert.equal(result.execution.agents[0].status, 'completed');
});

test('every real proposal needs exactly one disposition and at least one adoption', async t => {
  const changes = [
    value => { value.decisions[0].proposalId = 'invented-proposal'; },
    value => { value.decisions[0].characterId = 'invented-character'; },
    value => { value.decisions[1] = structuredClone(value.decisions[0]); },
    value => { value.decisions.pop(); },
    value => { value.decisions[0].disposition = 'rejected'; },
    value => { value.decisions[0].disposition = 'implemented'; },
  ];
  for (const change of changes) {
    const f = fixture(t); change(f.parentValue); f.complete();
    await assert.rejects(f.cast.validate(f.rpc), /검증 실패/);
  }
});

test('validation requires successful observed parent commands and matching stored runtime identities', async t => {
  const changes = [
    f => { f.parentValue.validation[0].commandItemId = 'read-0'; },
    f => { f.parentValue.validation[0].commandItemId = 'fabricated'; },
    f => { f.parentValue.validation = []; },
    f => { f.parentValue.validation.push(structuredClone(f.parentValue.validation[0])); },
  ];
  for (const change of changes) {
    const f = fixture(t); change(f); f.complete(); await assert.rejects(f.cast.validate(f.rpc), /검증 실패/);
  }
  for (const change of [record => { record.exitCode = 1; }, record => { record.status = 'failed'; }, record => { record.turnId = 'old-turn'; }, record => { record.threadId = 'child-0'; }]) {
    const f = fixture(t); f.complete(); change(f.task.commands[0]); await assert.rejects(f.cast.validate(f.rpc), /실제로 성공한 부모 검증/);
  }
  const f = fixture(t); f.complete(); f.task.commands.push({ itemId: 'fabricated', threadId: 'parent', turnId: 'parent-turn', status: 'completed', exitCode: 0 });
  f.cast.commandItems.delete('test-command');
  await assert.rejects(f.cast.validate(f.rpc), /실제로 성공한 부모 검증/);
});

test('child writes, delegation, apps and approval requests are rejected, including hidden completed-turn tool items', t => {
  for (const type of ['fileChange', 'mcpToolCall', 'dynamicToolCall', 'webSearch', 'collabAgentToolCall', 'subAgentActivity']) {
    const f = fixture(t); f.start();
    assert.throws(() => f.done('child-0', 'child-turn-0', f.childValues[0], [{ id: 'hidden-tool', type }]), /검증 실패/);
  }
  const f = fixture(t); f.start();
  assert.throws(() => f.observe('item/commandExecution/requestApproval', 'child-0', { turnId: 'child-turn-0' }), /자식 권한/);
  assert.throws(() => f.observe('item/completed', 'unknown-child', { turnId: 'foreign-turn', item: { type: 'commandExecution', id: 'bad', command: 'cat code' } }), /등록되지 않은/);
});

test('only the parent host evidence tool with empty arguments is allowed, including completed-turn replay', async t => {
  const item = { type: 'dynamicToolCall', id: 'evidence-query', namespace: null, tool: 'doboo_work_evidence', arguments: {}, status: 'completed',
    contentItems: [{ type: 'inputText', text: JSON.stringify({ commands: [{ itemId: 'test-command' }] }) }], success: true };
  const f = fixture(t); f.complete();
  f.observe('item/started', 'parent', { turnId: 'parent-turn', item: { ...item, status: 'inProgress', success: null } });
  f.observe('item/completed', 'parent', { turnId: 'parent-turn', item });
  f.done('parent', 'parent-turn', f.parentValue, [item]);
  const result = await f.cast.validate(f.rpc);
  assert.deepEqual(result.execution.evidenceLookups, [{ itemId: 'evidence-query', threadId: 'parent', turnId: 'parent-turn', tool: 'doboo_work_evidence', status: 'completed', success: true }]);
  for (const additions of [{ namespace: 'other' }, { tool: 'another_tool' }, { arguments: { command: 'invented' } }, { arguments: [] }, { status: 'failed' }, { success: false }]) {
    const bad = fixture(t); bad.start();
    assert.throws(() => bad.observe('item/completed', 'parent', { turnId: 'parent-turn', item: { ...item, ...additions } }), /검증 실패/);
  }
  const child = fixture(t); child.start();
  assert.throws(() => child.observe('item/completed', 'child-0', { turnId: 'child-turn-0', item }), /허용되지 않은 작업 증거 조회/);
  const wrongTurn = fixture(t); wrongTurn.start();
  assert.throws(() => wrongTurn.observe('item/completed', 'parent', { turnId: 'old-turn', item }), /턴 불일치/);
});

test('failed command-ID validation preserves the observed coordinator final for diagnosis without accepting chunk IDs', async t => {
  const f = fixture(t); f.parentValue.validation[0].commandItemId = 'chunk-from-tool-result'; f.complete();
  await assert.rejects(f.cast.validate(f.rpc), /실제로 성공한 부모 검증 명령/);
  assert.equal(f.cast.receipt.coordinatorResult, JSON.stringify(f.parentValue));
  assert.equal(f.cast.receipt.coordinatorFinalMessageId, 'final-parent');
  assert.equal(f.cast.receipt.coordinatorTurnId, 'parent-turn');
});

test('wrong root turns, duplicate character execution and failed native turns cannot validate', t => {
  const root = fixture(t); root.start();
  assert.throws(() => root.observe('turn/started', 'child-0', { turn: { id: 'child-turn-0', rootTurnId: 'unrelated-parent-turn' } }), /루트 턴/);
  const duplicate = fixture(t); duplicate.start();
  assert.throws(() => duplicate.observe('item/started', 'parent', { turnId: 'parent-turn', item: { type: 'subAgentActivity', id: 'second-spawn', kind: 'started', agentPath: '/root/work_0_doboo', agentThreadId: 'second-child', model, reasoningEffort: effort } }), /중복 실행/);
  const failed = fixture(t); failed.start();
  assert.throws(() => failed.observe('turn/completed', 'child-0', { turn: { id: 'child-turn-0', rootTurnId: 'parent-turn', status: 'failed', error: { message: 'child failed' } } }), /child failed/);
});

test('cancellation while native metadata reads are pending prevents a completed work record', async t => {
  const f = fixture(t); f.complete();
  await assert.rejects(f.cast.validate(async (method, params) => {
    f.task.cancelRequested = true; return f.rpc(method, params);
  }), /중단된 작업/);
});
