import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { startBridge } from '../task-bridge/server.mjs';
import { resolveCodexBinary } from '../task-bridge/runtime.mjs';

// Explicit, billable live integration proof. All agent edits happen in a new
// fixture repository; the source project supplies configuration only.
const { values } = parseArgs({ options: {
  roster: { type: 'string' }, directory: { type: 'string' }, evidence: { type: 'string' },
  'source-project': { type: 'string' }, codex: { type: 'string' }, 'timeout-ms': { type: 'string' },
} });
assert(values.roster && (values.directory || values.evidence),
  'Required: --roster <innercast.roles.json> --directory <new evidence directory> (--evidence is an alias)');
assert(!(values.directory && values.evidence), 'Use only one of --directory and --evidence');
const timeoutMs = Number(values['timeout-ms'] ?? 900000);
assert(Number.isSafeInteger(timeoutMs) && timeoutMs >= 1000 && timeoutMs <= 3600000, 'Invalid --timeout-ms');
const root = resolve(values.directory ?? values.evidence);
const sourceProject = realpathSync(values['source-project'] ?? resolve(dirname(fileURLToPath(import.meta.url)), '..'));
mkdirSync(root, { mode: 0o700 }); // Refuse to reuse evidence or an existing checkout.
const project = join(root, 'project');
mkdirSync(project, { mode: 0o700 });
const codex = resolveCodexBinary({ explicit: values.codex });
const proof = { startedAt: new Date().toISOString(), sourceProject, project, tasks: [], checks: [], calls: [] };
const digest = value => createHash('sha256').update(value).digest('hex');
const fileDigest = path => digest(readFileSync(path));
const terminal = new Set(['completed', 'failed', 'interrupted']);
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
let app;

function bounded(value) {
  if (typeof value === 'string' && value.length > 12000)
    return { truncated: true, characters: value.length, sha256: digest(value), preview: value.slice(0, 12000) };
  if (Array.isArray(value)) return value.map(bounded);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, bounded(item)]));
  return value;
}
function save() {
  const output = JSON.stringify(bounded(proof), null, 2);
  if (Buffer.byteLength(output) > 4 * 1024 * 1024) {
    writeFileSync(join(root, 'proof.json'), JSON.stringify({ startedAt: proof.startedAt, project,
      error: 'Proof exceeded the 4 MiB evidence limit; this run did not pass.',
      originalSHA256: digest(output), taskIds: proof.tasks.map(task => task.taskId) }, null, 2));
    throw Error('Proof exceeded 4 MiB; bounded failure manifest saved');
  }
  writeFileSync(join(root, 'proof.json'), output);
}
function command(executable, args, cwd = project) {
  const result = spawnSync(executable, args, { cwd, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 });
  if (result.error) throw result.error;
  return { executable, args, cwd, exitCode: result.status, signal: result.signal,
    stdout: result.stdout, stderr: result.stderr };
}
function checked(executable, args, cwd) {
  const result = command(executable, args, cwd);
  assert.equal(result.exitCode, 0, `${executable} ${args.join(' ')} failed: ${result.stderr}`);
  return result;
}

// config/read does not create a thread or start a model turn. Compare effective
// settings instead of copying or weakening the user's configuration.
async function inspectSettings() {
  const child = spawn(codex, ['app-server', '--listen', 'stdio://'], { cwd: sourceProject, stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map(); let nextId = 0, stderr = '';
  const lines = createInterface({ input: child.stdout });
  const rejectAll = error => { for (const item of pending.values()) { clearTimeout(item.timer); item.reject(error); } pending.clear(); };
  child.on('error', rejectAll);
  child.stdin.on('error', rejectAll);
  child.on('exit', () => rejectAll(Error(`Configuration reader exited: ${stderr}`)));
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-2000); });
  lines.on('line', line => {
    let message; try { message = JSON.parse(line); } catch { rejectAll(Error('Invalid configuration-reader response')); return; }
    const item = pending.get(message.id); if (!item) return;
    clearTimeout(item.timer); pending.delete(message.id);
    if (message.error) item.reject(Error(message.error.message)); else item.resolve(message.result);
  });
  const rpc = (method, params) => new Promise((resolve, reject) => {
    const id = ++nextId;
    const timer = setTimeout(() => { pending.delete(id); reject(Error(`${method}: timed out`)); }, 30000);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
  try {
    await rpc('initialize', { clientInfo: { name: 'doboo-work-cast-proof', version: '1.0.0' } });
    child.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');
    const results = await Promise.all([sourceProject, project].map(cwd => rpc('config/read', { cwd, includeLayers: false })));
    const selected = results.map(({ config }) => ({ model: config?.model ?? null, reasoningEffort: config?.model_reasoning_effort ?? null }));
    assert.deepEqual(selected[1], selected[0], 'Fixture model/effort differs from the source project; no model turn was started');
    return { source: selected[0], fixture: selected[1], nullMeansRuntimeDefault: true };
  } finally {
    lines.close(); child.stdin.end(); child.kill();
    const kill = setTimeout(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); }, 3000);
    kill.unref();
  }
}
async function api(path, body) {
  const response = await fetch(app.connection.url + path, { method: body === undefined ? 'GET' : 'POST',
    headers: { Authorization: 'Bearer ' + app.connection.token, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(15000) });
  const value = await response.json();
  if (!response.ok) throw Error(`${path}: ${JSON.stringify(value)}`);
  if (body !== undefined) proof.calls.push({ path, body });
  return value;
}
async function close() {
  if (!app) return;
  const current = app; app = null;
  current.bridge.close();
  await new Promise((resolve, reject) => current.server.close(error => error ? reject(error) : resolve()));
}
function receiptProof(receipt) {
  return { ...receipt, agents: receipt.agents.map(({ rawResult, ...agent }) => ({ ...agent,
    rawResultSHA256: typeof rawResult === 'string' ? digest(rawResult) : null })) };
}
function verifyTask(task, cast, previousTaskId) {
  assert.equal(task.status, 'completed', task.error ?? 'Work failed');
  const receipt = task.castExecution, record = task.workRecord;
  assert(receipt && record, 'Completed work requires both native receipts and a persisted work record');
  assert.equal(receipt.mode, 'native_subagents');
  assert.equal(receipt.coordinatorThreadId, task.threadId);
  assert.equal(receipt.agents.length, cast.length);
  assert.equal(new Set(receipt.agents.map(agent => agent.threadId)).size, cast.length);
  assert.deepEqual(receipt.agents.map(agent => agent.characterId).sort(), cast.map(item => item.character.id).sort());
  assert.equal(record.taskId, task.id);
  assert.equal(record.project, realpathSync(project));
  assert(record.recordedAt && record.summary && record.contextDigest);
  assert.equal(record.contextDigest, receipt.contextDigest);
  assert.equal(record.contributions.length, cast.length);
  assert.equal(new Set(record.contributions.map(item => item.characterId)).size, cast.length);
  const settings = new Set();
  for (const agent of receipt.agents) {
    assert.equal(agent.status, 'completed');
    assert.equal(agent.parentThreadId, task.threadId);
    assert(agent.threadId !== task.threadId && agent.turnId && agent.finalMessageId && agent.rawResult);
    assert(agent.agentRole && /^[a-f0-9]{64}$/.test(agent.instructionsDigest), 'Missing host-authored role provenance');
    assert(agent.model && agent.reasoningEffort, 'Missing actual model/effort');
    settings.add(JSON.stringify([agent.model, agent.reasoningEffort]));
    if (proof.settings.source.model !== null) assert.equal(agent.model, proof.settings.source.model);
    if (proof.settings.source.reasoningEffort !== null) assert.equal(agent.reasoningEffort, proof.settings.source.reasoningEffort);
    const contribution = record.contributions.find(item => item.characterId === agent.characterId);
    assert(contribution?.proposals?.length, `${agent.characterId} made no reviewable contribution`);
    assert(contribution.commands?.some(item => item.exitCode === 0), `${agent.characterId} has no successful code inspection receipt`);
    for (const proposal of contribution.proposals) {
      assert(proposal.id && proposal.summary && proposal.rationale && Array.isArray(proposal.paths));
      assert(record.decisions.some(decision => decision.characterId === agent.characterId && decision.proposalId === proposal.id), 'A proposal has no adoption decision');
    }
    if (previousTaskId) assert(contribution.rememberedTaskIds?.includes(previousTaskId), `${agent.characterId} did not reference the persisted prior task`);
  }
  assert.equal(settings.size, 1, 'Cast model/effort diverged');
  for (const decision of record.decisions) {
    assert(['adopted', 'rejected', 'deferred'].includes(decision.disposition) && decision.rationale);
    assert(record.contributions.some(item => item.characterId === decision.characterId && item.proposals.some(proposal => proposal.id === decision.proposalId)), 'Decision references an invented proposal');
  }
  assert(record.decisions.some(decision => decision.disposition === 'adopted'), 'No proposal was adopted');
  const checks = record.evidence?.commands?.filter(item => item.itemId && item.exitCode === 0 && item.status === 'completed'
    && /\bnode\b/.test(item.command) && /--test\b/.test(item.command));
  assert(checks?.length, 'No successful runtime node --test receipt');
  assert(checks.every(item => item.purpose), 'Verification receipts need an explicit purpose');
  assert(record.evidence.repository?.available && !record.evidence.repository.truncated, 'Repository observations are unavailable or incomplete');
  const sourceChange = record.evidence.repository.changes.find(change => change.path === 'pricing.mjs');
  assert(sourceChange && sourceChange.beforeSHA256 !== sourceChange.afterSHA256, 'No host-observed source change');
  assert.equal(sourceChange.afterSHA256, fileDigest(join(project, 'pricing.mjs')), 'Source observation does not match actual resulting bytes');
  if (previousTaskId) assert(record.sourceTaskIds.includes(previousTaskId), 'Prior work was not supplied as canonical context');
  else assert.deepEqual(record.sourceTaskIds, []);
  return { record, receipt: receiptProof(receipt), settings: [...settings][0] };
}
async function runWork(label, prompt, cast, previousTaskId) {
  const main = cast[0];
  const submitted = await api('/v1/tasks', { id: randomUUID(), prompt, character: main.character,
    continuity: { serverId: app.bridge.serverId, companionRevision: main.companionRevision,
      ...(previousTaskId ? { parentTaskId: previousTaskId } : {}) }, work: { cast } });
  console.log('START', label, submitted.id);
  const deadline = Date.now() + timeoutMs; let last = '';
  while (Date.now() < deadline) {
    const task = await api('/v1/tasks/' + submitted.id);
    const status = JSON.stringify({ task: task.id, status: task.status, activity: task.activity,
      agents: task.castExecution?.agents?.map(agent => ({ character: agent.characterId, status: agent.status })) });
    if (status !== last) { console.log(status); last = status; }
    if (task.approvals?.length) { proof.failedTask = task; throw Error('Live proof requires user approval; no approval was synthesized'); }
    if (terminal.has(task.status)) {
      if (task.status !== 'completed') { proof.failedTask = task; throw Error(task.error ?? task.status); }
      // Preserve the actual response before assertions, so failed verification is inspectable.
      const result = { label, prompt, taskId: task.id, threadId: task.threadId, turnId: task.turnId,
        status: task.status, workRecord: task.workRecord, castExecution: task.castExecution ? receiptProof(task.castExecution) : null };
      proof.tasks.push(result); save();
      const verified = verifyTask(task, cast, previousTaskId);
      result.effectiveSettings = verified.settings;
      console.log('WORK_COMPLETE', JSON.stringify({ label, taskId: task.id, decisions: verified.record.decisions,
        verificationCount: verified.record.evidence.commands.length }));
      save(); return result;
    }
    await wait(1000);
  }
  proof.timedOutTask = await api('/v1/tasks/' + submitted.id);
  throw Error(`${label} timed out; closing the bridge will interrupt this task`);
}

const initialSource = `// Monetary amounts are integer cents; quantities and discounts are integers.\nexport function lineTotalCents(unitCents, quantity, discountBps = 0) {\n  return Math.round(unitCents * (10000 - discountBps) / 10000) * quantity;\n}\n`;
const baselineTests = `import test from 'node:test';\nimport assert from 'node:assert/strict';\nimport { lineTotalCents } from './pricing.mjs';\ntest('discount rounding happens once at the line boundary', () => {\n  assert.equal(lineTotalCents(105, 3, 1000), 284);\n  assert.equal(lineTotalCents(99, 3, 500), 282);\n  assert.equal(lineTotalCents(125, 4, 0), 500);\n  assert.equal(lineTotalCents(105, 0, 1000), 0);\n});\n`;
try {
  const roster = JSON.parse(readFileSync(resolve(values.roster), 'utf8'));
  assert(Array.isArray(roster.characters) && roster.characters.length >= 2 && roster.characters.length <= 6, 'Roster must contain 2–6 characters');
  assert.equal(new Set(roster.characters.map(character => character.id)).size, roster.characters.length, 'Roster has duplicate IDs');
  proof.characterSource = { path: resolve(values.roster), version: roster.version, sha256: fileDigest(resolve(values.roster)) };
  checked('git', ['init', '-q']);
  writeFileSync(join(project, 'pricing.mjs'), initialSource);
  writeFileSync(join(project, 'pricing.test.mjs'), baselineTests);
  checked('git', ['add', 'pricing.mjs', 'pricing.test.mjs']);
  proof.baseline = { sourceSHA256: fileDigest(join(project, 'pricing.mjs')), testsSHA256: fileDigest(join(project, 'pricing.test.mjs')),
    execution: command(process.execPath, ['--test', 'pricing.test.mjs']) };
  assert.notEqual(proof.baseline.execution.exitCode, 0, 'Baseline must expose the real rounding defect');
  proof.settings = await inspectSettings(); save();
  app = await startBridge({ project, directory: join(root, 'state'), port: 0, codex });
  const cast = [];
  for (const character of roster.characters) {
    const profile = { id: character.id, version: 1, name: character.displayName,
      identity: { backstory: character.description, voice: character.oneLine },
      personality: { traits: [character.archetype, ...character.focus], instructions: character.rules } };
    const saved = await api('/v1/companions/' + character.id, { serverId: app.bridge.serverId, expectedRevision: 0, profile, memory: '' });
    cast.push({ character: { id: profile.id, name: profile.name, version: profile.version }, companionRevision: saved.revision });
  }
  const first = await runWork('fix line rounding',
    '이 임시 저장소의 pricing.mjs에서 lineTotalCents의 할인 계산 오류를 실제로 고쳐 주세요. 입력은 음이 아닌 정수 cents·quantity이고 discountBps는 0~10000의 정수입니다. 할인한 단가를 먼저 반올림하지 말고 수량을 포함한 각 항목의 합계에서 Math.round로 딱 한 번 반올림하는 규칙을 채택하세요. 예: 105 cents × 3개, 1000 bps 할인은 284 cents입니다. 캐릭터별 native 검토자의 근거와 제안을 받고 각 제안의 채택·기각·보류 이유를 기록하세요. 조정자가 실제 코드를 수정하고 node --test pricing.test.mjs를 실행하세요. 기존 pricing.test.mjs는 수정하지 마세요. 커밋·push·외부 서비스·게시·기기 접근은 하지 마세요.', cast);
  assert.notEqual(fileDigest(join(project, 'pricing.mjs')), proof.baseline.sourceSHA256, 'First task made no real code change');
  assert.equal(fileDigest(join(project, 'pricing.test.mjs')), proof.baseline.testsSHA256, 'Original regression test was changed');
  first.hostVerification = checked(process.execPath, ['--test', 'pricing.test.mjs']);
  first.sourceSHA256 = fileDigest(join(project, 'pricing.mjs'));
  first.diff = checked('git', ['diff', '--', 'pricing.mjs']).stdout;
  assert(first.diff.trim(), 'First task has no inspectable diff');
  const policyDecision = first.workRecord.decisions.find(decision => {
    if (decision.disposition !== 'adopted') return false;
    const proposal = first.workRecord.contributions.find(item => item.characterId === decision.characterId)?.proposals.find(item => item.id === decision.proposalId);
    return proposal?.paths.some(path => /(?:^|\/)pricing\.mjs$/.test(path)) && /반올림|round/i.test(proposal.summary + ' ' + proposal.rationale);
  });
  assert(policyDecision, 'No adopted proposal records the calculation policy used by the next task');
  proof.policyDecision = { taskId: first.taskId, ...policyDecision };
  const beforeRestart = structuredClone(first.workRecord);
  const serverId = app.bridge.serverId;
  save(); await close();
  app = await startBridge({ project, directory: join(root, 'state'), port: 0, codex });
  assert.equal(app.bridge.serverId, serverId, 'Project identity changed across restart');
  const restored = await api('/v1/tasks/' + first.taskId);
  assert.deepEqual(restored.workRecord, beforeRestart, 'Structured work record did not persist across restart');
  const second = await runWork('extend the agreed calculation',
    '같은 프로젝트의 다음 실제 작업입니다. pricing.mjs에 cartTotalCents(lines)를 export하세요. lines의 원소는 {unitCents, quantity, discountBps}이며 빈 배열도 지원해야 합니다. 계산 정책은 앞서 채택하고 검증한 작업 기록을 이어서 적용하고 각 캐릭터는 실제로 사용한 이전 작업 ID를 rememberedTaskIds에 남기세요. 이전 기억이 제공되지 않았다면 추측하지 마세요. 캐릭터별 검토와 제안의 채택 이유를 기록한 뒤 실제 코드를 수정하세요. cart.test.mjs에 의미 있는 회귀 테스트를 추가하고 node --test pricing.test.mjs cart.test.mjs를 실행하세요. 기존 pricing.test.mjs는 수정하지 말고 커밋·push하지 마세요.', cast, first.taskId);
  assert.equal(fileDigest(join(project, 'pricing.test.mjs')), proof.baseline.testsSHA256, 'Original regression test was changed');
  assert.notEqual(fileDigest(join(project, 'pricing.mjs')), first.sourceSHA256, 'Second task made no additional code change');
  assert.equal(second.effectiveSettings, first.effectiveSettings, 'Model/effort changed after restart');
  const oldChildren = new Set(first.castExecution.agents.map(agent => agent.threadId));
  assert(second.castExecution.agents.every(agent => !oldChildren.has(agent.threadId)), 'Follow-up reused a prior child execution');
  assert.notEqual(second.threadId, first.threadId, 'Follow-up reused the coordinator thread');
  const remembered = app.bridge.jobs.get(second.taskId)._execution.work.snapshot.history.find(entry => entry.taskId === first.taskId)?.workRecord;
  assert(remembered?.decisions.some(decision => decision.characterId === policyDecision.characterId
    && decision.proposalId === policyDecision.proposalId && decision.disposition === 'adopted'), 'The actual follow-up context omitted the adopted policy');
  assert(remembered.verification.some(check => check.exitCode === 0 && check.status === 'completed'), 'The actual follow-up context omitted the previous verification result');
  second.rememberedWork = remembered;
  second.hostVerification = checked(process.execPath, ['--test', 'pricing.test.mjs', 'cart.test.mjs']);
  // These assertions are outside the agent-editable project and are created
  // after both turns. They check behavior, without prescribing an implementation.
  const semanticVerifier = join(root, 'verify-semantics.mjs');
  writeFileSync(semanticVerifier, `import assert from 'node:assert/strict';\nimport { lineTotalCents, cartTotalCents } from './project/pricing.mjs';\nassert.equal(lineTotalCents(105, 3, 1000), 284);\nassert.equal(cartTotalCents([]), 0);\nassert.equal(cartTotalCents([{unitCents:105,quantity:3,discountBps:1000},{unitCents:105,quantity:3,discountBps:1000}]), 568);\nassert.equal(cartTotalCents([{unitCents:99,quantity:3,discountBps:500},{unitCents:125,quantity:4,discountBps:0}]), 782);\nconsole.log('PASS: persisted per-line calculation policy also governs cart totals');\n`);
  second.semanticVerification = checked(process.execPath, [semanticVerifier]);
  second.sourceSHA256 = fileDigest(join(project, 'pricing.mjs'));
  second.diff = checked('git', ['diff', '--', 'pricing.mjs']).stdout;
  proof.checks = [
    'Each task used one distinct native child per registered character with host-authored role provenance',
    'Each child inspected code and contributed proposals linked to coordinator adoption decisions',
    'Both tasks produced actual code changes and successful runtime test-command receipts',
    'The original failing regression test remained byte-identical and passed after the fix',
    'The structured first work record survived a bridge restart unchanged',
    'Fresh follow-up children referenced the first task in rememberedTaskIds',
    'Follow-up code preserved the prior per-line calculation policy without restating it in the follow-up prompt',
    'Independent semantic checks passed outside the agent-editable repository',
    'Model and reasoning settings were preserved across the fixture, cast, and restart',
  ];
  proof.completedAt = new Date().toISOString(); save();
  console.log('PASS', JSON.stringify({ proof: join(root, 'proof.json'), checks: proof.checks }));
} catch (error) {
  proof.error = String(error);
  try { save(); } catch (saveError) { console.error(String(saveError)); }
  console.error(String(error)); process.exitCode = 1;
} finally {
  await close();
}
