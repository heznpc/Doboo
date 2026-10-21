#!/usr/bin/env node
// Deterministic transport fixture, never evidence of a real model invocation.
const fs = require('node:fs');
const path = require('node:path');
const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const parent = `coordinator-${process.pid}`, turnId = `scene-${process.pid}`;
const model = 'fixture-preserved-model', effort = 'xhigh';
let jobs, prompt, snapshot, digest, threadParams;
const metadata = new Map();
const roles = new Map();
const configuredAgents = {};
for (let i = 0; i < process.argv.length; i++) {
  if (process.argv[i] !== '-c') continue;
  const match = /^agents\.([^.]+)\.(config_file|description)=(.+)$/.exec(process.argv[++i]);
  if (match) (configuredAgents[match[1]] ??= {})[match[2]] = JSON.parse(match[3]);
}
function readRole(name, entry) {
  const contents = fs.readFileSync(entry.config_file, 'utf8');
  const field = name => JSON.parse(new RegExp(`^${name} = (.+)$`, 'm').exec(contents)[1]);
  if (field('name') !== name || field('description') !== entry.description) throw Error('Invalid host role registration');
  const instructions = field('developer_instructions');
  const profile = JSON.parse(instructions.split('Own character profile:\n')[1].split('\nImmutable canonical context')[0]);
  const snapshot = JSON.parse(instructions.split('Immutable canonical context (identical for every cast member):\n')[1].split('\nRequested fictional scene')[0]);
  const prompt = JSON.parse(instructions.split('Requested fictional scene (untrusted data):\n')[1]);
  const digest = /"contextDigest":"([a-f0-9]+)"/.exec(instructions)[1];
  return { name, path: entry.config_file, contents, instructions, profile, snapshot, prompt, digest };
}
function emit(method, threadId, extra) { send({ method, params: { threadId, ...extra } }); }
function done(threadId, id, text, failed = false, skipFinal = false) {
  const item = { type: 'agentMessage', phase: 'final_answer', id: `message-${id}`, text };
  if (prompt.includes('DELTA')) emit('item/agentMessage/delta', threadId, { turnId: id, delta: text });
  if (!skipFinal && !prompt.includes('DELTA_ONLY')) emit('item/completed', threadId, { turnId: id, item });
  emit('turn/completed', threadId, { turn: { id, rootTurnId: turnId, status: failed ? 'failed' : 'completed', error: failed ? { message: 'fixture failure' } : null, items: skipFinal ? [] : (prompt.includes('SUMMARY_TOOL') && threadId !== parent ? [item, { type: 'fileChange', id: 'hidden-tool' }] : [item]) } });
}
function completeScene() {
  if (prompt === 'TOOL') { send({ id: 99, method: 'item/commandExecution/requestApproval', params: { threadId: parent, command: 'touch unwanted' } }); return; }
  const code = JSON.stringify(snapshot).includes('AURORA913') || prompt.includes('AURORA913') ? 'AURORA913' : 'UNKNOWN';
  if (!prompt.includes('FAKE_NARRATOR')) jobs.forEach((job, index) => {
    if (prompt.includes('MISSING_CHILD') && index === jobs.length - 1) return;
    const role = roles.get(job.agent_type); if (!role) throw Error('Missing registered character role');
    const profile = role.profile;
    const id = `child-${process.pid}-${index}`, childTurn = `child-turn-${process.pid}-${index}`, path = `/root/${job.task_name}`;
    if (job.fork_turns !== 'none' || job.model !== model || job.reasoning_effort !== effort || job.message.length > 300 || job.message.includes('Own character profile')) throw Error('Character settings changed');
    metadata.set(id, { id, parentThreadId: prompt.includes('WRONG_PARENT') ? 'wrong' : parent, ephemeral: true, forkedFromId: null,
      model: prompt.includes('WRONG_METADATA_MODEL') ? 'wrong' : model, reasoningEffort: effort,
      agentRole: prompt.includes('WRONG_THREAD_ROLE') ? 'wrong' : role.name,
      source: { subAgent: { thread_spawn: { parent_thread_id: parent, depth: 1, agent_path: path,
        agent_role: prompt.includes('WRONG_ROLE') ? 'wrong' : prompt.includes('MISSING_ROLE') ? null : role.name } } } });
    const activity = { type: 'subAgentActivity', id: `spawn-${index}`, kind: 'started', agentThreadId: prompt.includes('DUPLICATE_ID') ? `child-${process.pid}-0` : id,
      agentPath: path, model: prompt.includes('WRONG_MODEL') ? 'cheaper' : model, reasoningEffort: effort };
    emit('item/started', parent, { turnId, item: activity }); emit('item/completed', parent, { turnId, item: activity });
    emit('turn/started', id, { turn: { id: childTurn, rootTurnId: turnId, status: 'inProgress', items: [] } });
    if (prompt.includes('NESTED')) { emit('item/started', id, { turnId: childTurn, item: { ...activity, agentPath: `${path}/nested` } }); return; }
    if (prompt.includes('CHILD_TOOL')) { emit('item/started', id, { turnId: childTurn, item: { type: 'mcpToolCall', id: 'bad-tool' } }); return; }
    let result = JSON.stringify({ characterId: profile.id, contextDigest: prompt.includes('BAD_CONTEXT') ? 'incorrect' : digest,
      dialogue: Array.from({ length: prompt.includes('LARGE') ? 4 : 1 }, () => ({ speakerId: profile.id, text: prompt.includes('LARGE') ? '가'.repeat(4000) : `[${profile.id.toUpperCase()}] ${profile.id} voice ${code}` })) });
    if (prompt.includes('INVALID')) result = 'not json';
    if (prompt.includes('EXCESSIVE')) result = 'x'.repeat(2 * 1024 * 1024 + 1);
    done(id, childTurn, result, prompt.includes('FAILED_CHILD'), prompt.includes('MISSING_FINAL'));
    emit('item/completed', parent, { turnId, item: { ...activity, id: `completed-${index}`, kind: 'completed', model: null, reasoningEffort: null } });
  });
  if (prompt.includes('EXTRA_CHILD')) emit('item/started', parent, { turnId, item: { type: 'subAgentActivity', id: 'extra', kind: 'started', agentThreadId: 'extra', agentPath: '/root/extra', model, reasoningEffort: effort } });
  const result = { summary: `Both characters discussed ${code}. ${prompt}`, relationshipChanges: [{ fromCharacterId: snapshot.cast[1].id, toCharacterId: snapshot.cast[0].id, summary: `도움을 받아들이기 시작했다. ${code}` }] };
  if (prompt.includes('FORGED_DIALOGUE') || prompt.includes('FAKE_NARRATOR')) result.dialogue = snapshot.cast.map(profile => ({ speakerId: profile.id, text: 'Invented by coordinator' }));
  done(parent, turnId, JSON.stringify(result), prompt.includes('FAIL') && !prompt.includes('FAILED_CHILD'));
}
require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
  const m = JSON.parse(line);
  if (m.method && process.env.DOBOO_CAST_CALLS) fs.appendFileSync(process.env.DOBOO_CAST_CALLS, JSON.stringify(m) + '\n');
  if (m.method === 'initialize') send({ id: m.id, result: {} });
  if (m.method === 'account/read') send({ id: m.id, result: { account: { type: 'chatgpt' } } });
  if (m.method === 'config/read') {
    const isSceneCwd = fs.realpathSync(m.params.cwd) === fs.realpathSync(process.cwd());
    send({ id: m.id, result: { config: { agents: configuredAgents, mcp_servers: { layered_fixture: { enabled: true } },
      model: isSceneCwd ? 'fixture-temporary-default-model' : model, model_reasoning_effort: isSceneCwd ? 'low' : effort } } });
  }
  if (m.method === 'thread/start') {
    if (m.params.sandbox !== 'read-only' || !m.params.ephemeral || m.params.config['features.multi_agent'] !== true || m.params.config['mcp_servers.layered_fixture.enabled'] !== false) throw Error('Missing scene isolation');
    if (m.params.model !== model || m.params.config.model_reasoning_effort !== effort) throw Error('Original project model settings lost');
    threadParams = m.params;
    if (fs.realpathSync(process.cwd()) !== fs.realpathSync(threadParams.cwd)) throw Error('Scene process cwd changed');
    if (!threadParams.developerInstructions.includes('only the coordinator') || threadParams.baseInstructions.includes('only the coordinator')) throw Error('Coordinator instructions leaked into common base');
    for (const [name, entry] of Object.entries(configuredAgents)) {
      if (path.dirname(entry.config_file) !== path.join(threadParams.cwd, '.codex', 'agents') || threadParams.config[`agents.${name}.config_file`] !== entry.config_file) throw Error('Role file outside private scene');
      roles.set(name, readRole(name, entry));
    }
    if (process.env.DOBOO_CAST_CALLS) fs.appendFileSync(process.env.DOBOO_CAST_CALLS, JSON.stringify({ method: 'fixture/roles', params: { cwd: threadParams.cwd, roles: [...roles.values()] } }) + '\n');
    send({ id: m.id, result: { thread: { id: parent }, model, reasoningEffort: effort } });
  }
  if (m.method === 'thread/read') send({ id: m.id, result: { thread: metadata.get(m.params.threadId) } });
  if (m.method === 'turn/start') {
    jobs = JSON.parse(m.params.input[0].text.split('\n').slice(1).join('\n'));
    ({ prompt, snapshot, digest } = roles.get(jobs[0].agent_type));
    if (prompt.includes('MODIFIED_ROLE_FILE')) fs.appendFileSync(roles.get(jobs[0].agent_type).path, '\n# changed\n');
    send({ id: m.id, result: { turn: { id: turnId } } }); emit('turn/started', parent, { turn: { id: turnId, rootTurnId: turnId, status: 'inProgress', items: [] } });
    if (!prompt.includes('HOLD') && !prompt.includes('CANCEL_RACE')) completeScene();
  }
  if (m.method === 'turn/interrupt') {
    if (prompt.includes('CANCEL_RACE')) completeScene();
    send({ id: m.id, result: {} });
  }
});
