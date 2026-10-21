import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { TaskBridge, startBridge } from './server.mjs';
import { castJobs, prepareCastWorkspace } from './native-cast.mjs';
const profile = id => ({ id, version: 1, name: id, identity: { backstory: `${id} background`, voice: `${id} voice` }, personality: { traits: [`${id} trait`], instructions: [] } });
function fixture() {
  const directory = mkdtempSync(join(tmpdir(), 'doboo-story-')); const codex = join(directory, 'fake-codex'); const calls = join(directory, 'calls.jsonl');
  const transport = readFileSync(new URL('./fixtures/native-cast.cjs', import.meta.url), 'utf8').replace(/^#!.*\n/, '');
  writeFileSync(codex, `#!/usr/bin/env node\nprocess.env.DOBOO_CAST_CALLS=${JSON.stringify(calls)};\n${transport}`, { mode: 0o700 });
  return { directory, project: directory, codex, calls };
}
const input = (bridge, extra = {}) => ({ serverId: bridge.serverId, expectedRevision: bridge.story.state.revision, ...extra });
function setup(bridge) {
  for (const id of ['doboo', 'mori']) bridge.updateCompanion(id, { serverId: bridge.serverId, expectedRevision: 0, profile: profile(id), memory: '' });
  return bridge.story.createEpisode(input(bridge, { title: '문 앞에서', castIds: ['doboo', 'mori'] })).episodes[0];
}
const request = (bridge, prompt) => input(bridge, { requestId: randomUUID(), prompt });
async function until(check) { for(let i=0;i<200;i++) {if(check())return;await new Promise(r=>setTimeout(r,15));}throw Error('timeout'); }
async function complete(bridge, episode, prompt) {const task = await bridge.story.turn(episode.id, request(bridge,prompt));await until(()=>['completed','failed','interrupted'].includes(task.status)&&!bridge.sessions.has(task.id));return task;}
const calls = options => readFileSync(options.calls,'utf8').trim().split('\n').map(JSON.parse);
const jobs = options => JSON.parse(calls(options).filter(call=>call.method==='turn/start').at(-1).params.input[0].text.split('\n').slice(1).join('\n'));
const roleBinding = options => calls(options).filter(call=>call.method==='fixture/roles').at(-1).params;
const context = options => roleBinding(options).roles[0].snapshot;

test('isolated scenes preserve the original project model and reasoning instead of temporary cwd defaults', async t => {
  const options=fixture();const bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  const task=await complete(bridge,episode,'project settings');assert.equal(task.status,'completed',task.error);
  const requests=calls(options),start=requests.find(call=>call.method==='thread/start').params;
  const reads=requests.filter(call=>call.method==='config/read');
  assert.notEqual(start.cwd,bridge.project);
  assert.ok(reads.some(call=>call.params.cwd===bridge.project));assert.ok(reads.some(call=>call.params.cwd===start.cwd));
  assert.equal(start.model,'fixture-preserved-model');assert.equal(start.config.model_reasoning_effort,'xhigh');
  assert.ok(jobs(options).every(job=>job.model===start.model && job.reasoning_effort===start.config.model_reasoning_effort));
  assert.ok(task.castExecution.agents.every(agent=>agent.model===start.model && agent.reasoningEffort===start.config.model_reasoning_effort));
});

test('durable fictional scenes consume distinct cast, canonical events, accepted relationships, and continue into sequels', async t => {
  const options=fixture();let bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  const req=request(bridge,'첫 만남');const first=await bridge.story.turn(episode.id,req);await until(()=>first.status==='completed'&&!bridge.sessions.has(first.id));
  let state=bridge.story.snapshot();assert.equal(state.events.length,1);assert.equal(state.events[0].taskId,first.id);assert.equal(state.events[0].kind,'fictional_scene');assert.equal(state.relationships.length,0);
  assert.deepEqual(roleBinding(options).roles.map(role => role.profile),[profile('doboo'),profile('mori')]);
  assert.deepEqual(jobs(options).map(job=>job.agent_type),roleBinding(options).roles.map(role=>role.name));
  assert.equal(existsSync(roleBinding(options).cwd),false);
  assert.equal(state.events[0].execution.agents.length, 2);
  for (const [index, agent] of state.events[0].execution.agents.entries()) {
    const role=roleBinding(options).roles[index];
    assert.equal(agent.agentRole,role.name);assert.equal(agent.instructionsDigest,createHash('sha256').update(role.instructions).digest('hex'));
  }
  assert.equal(new Set(state.events[0].execution.agents.map(agent => agent.threadId)).size, 2);
  assert.equal(state.events[0].dialogue[0].sourceThreadId, state.events[0].execution.agents[0].threadId);
  assert.equal(state.events[0].execution.contextDigest, first.castExecution.contextDigest);
  assert.ok(jobs(options).every(job => job.fork_turns === 'none' && job.model === 'fixture-preserved-model' && job.reasoning_effort === 'xhigh'));
  const start=calls(options).find(call=>call.method==='thread/start').params;assert.equal(start.sandbox,'read-only');assert.equal(start.ephemeral,true);assert.equal(start.approvalPolicy,'never');assert.equal(start.config['features.shell_tool'],false);assert.equal(start.config.web_search,'disabled');assert.equal(start.config['features.multi_agent'],true);assert.equal(start.config['mcp_servers.layered_fixture.enabled'],false);
  assert.equal(calls(options).find(call=>call.method==='turn/start').params.outputSchema.type,'object');
  bridge.story.relationship(input(bridge,{episodeId:episode.id,fromCharacterId:'mori',toCharacterId:'doboo',summary:'도움을 받아들이기 시작했다.',sourceEventId:first.id}));
  bridge.close();bridge=new TaskBridge(options);assert.equal((await bridge.story.turn(episode.id,req)).id,first.id);
  await assert.rejects(bridge.story.turn(episode.id,{...req,prompt:'changed'}),/같은 요청/);
  const sequel=bridge.story.createEpisode(input(bridge,{title:'두 번째 문',predecessorEpisodeId:episode.id})).episodes.at(-1);
  assert.equal(sequel.seriesId,episode.seriesId);assert.deepEqual(sequel.castProfiles,episode.castProfiles);
  const second=await complete(bridge,sequel,'문 너머로 이어서');assert.equal(second.status,'completed');assert.notEqual(second.castExecution.agents[0].threadId, first.castExecution.agents[0].threadId);assert.deepEqual(second.castExecution.sourceEventIds,[first.id]);assert.equal(context(options).lineage.length,2);assert.equal(context(options).previousScenes[0].id,first.id);assert.equal(context(options).relationships[0].sourceEventId,first.id);
  await assert.rejects(bridge.story.turn(episode.id,request(bridge,'과거 회차 수정')),/최근 에피소드/);
  const independent=bridge.story.createEpisode(input(bridge,{title:'별개의 세계',castIds:episode.castIds})).episodes.at(-1);
  await complete(bridge,independent,'다른 첫 만남');assert.deepEqual(context(options).previousScenes,[]);assert.deepEqual(context(options).relationships,[]);
  const durable=JSON.parse(readFileSync(join(options.directory,'state.json')));assert.equal(durable.story.events.length,3);assert.equal(durable.tasks.filter(task=>task.status==='completed').length,3);
});

test('correcting and forgetting invalidate downstream memory across episodes without raw transcript replay', async t => {
  const options=fixture();const bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  const first=await complete(bridge,episode,'SECRET_FLOWER');const sequel=bridge.story.createEpisode(input(bridge,{title:'다음 회차',predecessorEpisodeId:episode.id})).episodes.at(-1);
  const second=await complete(bridge,sequel,'SECRET_FLOWER을 다시 떠올림');
  bridge.story.relationship(input(bridge,{episodeId:sequel.id,fromCharacterId:'mori',toCharacterId:'doboo',summary:'SECRET_FLOWER 관계',sourceEventId:second.id}));
  bridge.story.editEvent(first.id,input(bridge,{summary:'둘은 평범한 문을 보았다.',forgotten:false}));
  assert.equal(bridge.story.state.events[1].excludedFromContext,true);assert.deepEqual(bridge.story.state.relationships,[]);assert.deepEqual(bridge.story.state.events[0].dialogue,[]);
  await complete(bridge,sequel,'다음 장면');const supplied=context(options);assert.equal(supplied.previousScenes.length,1);assert.equal(supplied.previousScenes[0].summary,'둘은 평범한 문을 보았다.');assert.doesNotMatch(JSON.stringify(supplied),/SECRET_FLOWER/);
  bridge.story.editEvent(first.id,input(bridge,{summary:'둘은 평범한 문을 보았다.',forgotten:true}));
  await complete(bridge,sequel,'기억 없이 새 장면');assert.deepEqual(context(options).previousScenes,[]);
});

test('failed, malformed, denied-tool and cancelled turns never create canonical events; retries and concurrency are safe', async t => {
  const options=fixture();let bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  for(const prompt of ['FAIL','INVALID','TOOL','FAKE_NARRATOR','FORGED_DIALOGUE','MISSING_CHILD','MISSING_FINAL','DUPLICATE_ID','WRONG_PARENT','WRONG_MODEL','BAD_CONTEXT','NESTED','CHILD_TOOL','FAILED_CHILD','EXTRA_CHILD','WRONG_METADATA_MODEL','SUMMARY_TOOL','WRONG_ROLE','MISSING_ROLE','WRONG_THREAD_ROLE','MODIFIED_ROLE_FILE']) {const task=await complete(bridge,episode,prompt);assert.equal(task.status,'failed',prompt);assert.equal(bridge.story.state.events.length,0);assert.equal(existsSync(roleBinding(options).cwd),false);}
  const heldRequest=request(bridge,'HOLD');const held=await bridge.story.turn(episode.id,heldRequest);await until(()=>held.turnId);
  await assert.rejects(bridge.story.turn(episode.id,request(bridge,'concurrent')),/진행 중/);
  assert.throws(()=>bridge.story.relationship(input(bridge,{episodeId:episode.id,fromCharacterId:'mori',toCharacterId:'doboo',summary:'blocked'})),/진행 중/);
  await bridge.cancel(held);await until(()=>!bridge.sessions.has(held.id));assert.equal(held.status,'interrupted');assert.equal(bridge.story.state.events.length,0);
  bridge.close();bridge=new TaskBridge(options);assert.equal((await bridge.story.turn(episode.id,heldRequest)).status,'interrupted');assert.equal(bridge.story.state.events.length,0);
  const last=await complete(bridge,episode,'새 요청으로 성공');assert.equal(last.status,'completed');assert.deepEqual(context(options).previousScenes,[]);
});

test('authenticated HTTP story endpoint strips execution and rejects stale revisions and unrelated provenance', async t => {
  const options=fixture();const app=await startBridge({...options,port:0});t.after(()=>{app.bridge.close();app.server.close();});const episode=setup(app.bridge);
  assert.equal((await fetch(app.connection.url+'/v1/story')).status,401);
  const headers={Authorization:`Bearer ${app.connection.token}`,'Content-Type':'application/json'};
  const snapshot=await (await fetch(app.connection.url+'/v1/story',{headers})).json();assert.equal(snapshot.episodes[0].id,episode.id);
  const response=await fetch(app.connection.url+`/v1/story/episodes/${episode.id}/turns`,{method:'POST',headers,body:JSON.stringify({...request(app.bridge,'HTTP scene'),requestId:randomUUID().toUpperCase()})});assert.equal(response.status,200);const task=await response.json();assert.equal(task._execution,undefined);assert.equal(task.episodeId,episode.id);
  await until(()=>app.bridge.jobs.get(task.id).status==='completed');
  assert.equal((await fetch(app.connection.url+`/v1/tasks/${task.id}`,{headers})).status,200);
  const edit=await fetch(app.connection.url+`/v1/story/events/${task.id}`,{method:'POST',headers,body:JSON.stringify(input(app.bridge,{summary:'HTTP correction',forgotten:false}))});assert.equal(edit.status,200);
  const stale=await fetch(app.connection.url+'/v1/story/relationships',{method:'POST',headers,body:JSON.stringify({serverId:app.bridge.serverId,expectedRevision:0,episodeId:episode.id})});assert.equal(stale.status,400);
  assert.throws(()=>app.bridge.story.relationship(input(app.bridge,{episodeId:episode.id,fromCharacterId:'mori',toCharacterId:'doboo',summary:'invalid provenance',sourceEventId:randomUUID()})),/출처/);
});

test('failed admission writes roll back both episode state and pending task without executing', async t => {
  const options=fixture();const bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  const before=bridge.story.snapshot();const persist=bridge.persist.bind(bridge);bridge.persist=()=>{throw Error('disk unavailable');};
  assert.throws(()=>bridge.story.relationship(input(bridge,{episodeId:episode.id,fromCharacterId:'mori',toCharacterId:'doboo',summary:'must not save'})),/disk unavailable/);
  assert.deepEqual(bridge.story.snapshot(),before);
  const req=request(bridge,'must not execute');await assert.rejects(bridge.story.turn(episode.id,req),/disk unavailable/);
  assert.deepEqual(bridge.story.snapshot(),before);assert.equal(bridge.jobs.has(req.requestId),false);assert.equal(bridge.sessions.size,0);bridge.persist=persist;
});

test('relationship deletion suppresses inherited relationship and explicit replacement restores it', async t => {
  const options=fixture();const bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  bridge.story.relationship(input(bridge,{episodeId:episode.id,fromCharacterId:'mori',toCharacterId:'doboo',summary:'경계함'}));
  await complete(bridge,episode,'시작');const sequel=bridge.story.createEpisode(input(bridge,{title:'계속',predecessorEpisodeId:episode.id})).episodes.at(-1);
  assert.equal(bridge.story.currentRelationships(sequel.id)[0].summary,'경계함');
  bridge.story.relationship(input(bridge,{episodeId:sequel.id,fromCharacterId:'mori',toCharacterId:'doboo',summary:''}));assert.deepEqual(bridge.story.currentRelationships(sequel.id),[]);
  bridge.story.relationship(input(bridge,{episodeId:sequel.id,fromCharacterId:'mori',toCharacterId:'doboo',summary:'다시 알아가는 중'}));assert.equal(bridge.story.currentRelationships(sequel.id)[0].summary,'다시 알아가는 중');
});

test('legacy task storage migrates once and interrupted story admission is never replayed after crash', async t => {
  const options=fixture();writeFileSync(join(options.directory,'tasks.json'),JSON.stringify([{id:randomUUID(),status:'completed',result:'legacy',character:{id:'legacy'}}]));
  let bridge=new TaskBridge(options);t.after(()=>bridge.close());assert.equal(bridge.jobs.size,1);const episode=setup(bridge);
  const req=request(bridge,'HOLD crash simulation');const task=await bridge.story.turn(episode.id,req);await until(()=>task.turnId);
  // A second process sees the last durable admission while the first child is still active.
  const recovered=new TaskBridge(options);assert.equal(recovered.jobs.get(task.id).status,'interrupted');assert.equal(recovered.story.state.events.length,0);
  assert.equal((await recovered.story.turn(episode.id,req)).status,'interrupted');assert.equal(recovered.sessions.size,0);
  bridge.close();bridge=recovered;
});


test('valid scene JSON larger than 24k is preserved for complete and streamed responses; excessive output fails explicitly', async t => {
  const options=fixture();const bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  for (const prompt of ['LARGE complete', 'LARGE DELTA complete', 'LARGE DELTA_ONLY']) {
    const task=await complete(bridge,episode,prompt);assert.equal(task.status,'completed');
    const event=bridge.story.state.events.at(-1);assert.equal(event.dialogue.length,8);assert.equal(event.dialogue[0].text.length,4000);
    assert.ok(task.result.length>32000);
  }
  for (const prompt of ['EXCESSIVE complete', 'EXCESSIVE DELTA_ONLY']) {
    const task=await complete(bridge,episode,prompt);assert.equal(task.status,'failed');assert.match(task.error,/2 MiB/);
    assert.equal(bridge.story.state.events.length,3);
  }
});


test('cancellation intent is durable before interrupt and late native completions cannot commit', async t => {
  const options=fixture();const bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  const task=await bridge.story.turn(episode.id,request(bridge,'CANCEL_RACE'));await until(()=>task.turnId);
  await bridge.cancel(task);await until(()=>!bridge.sessions.has(task.id));
  assert.equal(task.cancelRequested,true);assert.equal(task.status,'interrupted');assert.equal(bridge.story.state.events.length,0);
  const persisted=JSON.parse(readFileSync(join(options.directory,'state.json')));
  assert.equal(persisted.story.events.length,0);assert.equal(persisted.tasks.at(-1).status,'interrupted');
});

test('event and completed task persist atomically and both roll back after write failure', async t => {
  const options=fixture();const bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  const persist=bridge.persist.bind(bridge);let rejected=false;
  bridge.persist=()=>{if(bridge.story.state.events.length && !rejected){rejected=true;throw Error('completion disk failure');}persist();};
  const task=await complete(bridge,episode,'ATOMIC_WRITE');assert.equal(rejected,true);assert.equal(task.status,'failed');assert.match(task.error,/completion disk failure/);
  assert.equal(bridge.story.state.events.length,0);assert.equal(task.result,'');
  const persisted=JSON.parse(readFileSync(join(options.directory,'state.json')));
  assert.equal(persisted.story.events.length,0);assert.equal(persisted.tasks.at(-1).status,'failed');
});

test('every native role binds the same bounded canonical snapshot and its own frozen profile', async t => {
  const options=fixture();const bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  for(let i=0;i<6;i++)bridge.story.state.events.push({id:randomUUID(),episodeId:episode.id,summary:'memory'.repeat(650),forgotten:false});
  const task=await complete(bridge,episode,'bounded history');assert.equal(task.status,'completed');assert.equal(task.castExecution.historyTruncated,true);
  const dispatched=jobs(options);const roles=roleBinding(options).roles;
  assert.deepEqual(roles[0].snapshot,roles[1].snapshot);assert.deepEqual(roles[0].snapshot,task._execution.story.snapshot);assert.equal(context(options).previousScenes.length,4);
  assert.equal(task.castExecution.sourceEventIds.length,4);assert.equal(task.castExecution.contextRevision,task._execution.story.snapshot.revision);
  assert.deepEqual(roles.map(role=>role.profile),task._execution.story.cast);
  assert.ok(dispatched.every(job=>job.message.length<300 && !job.message.includes('bounded history')));
  assert.equal(new Set(dispatched.map(job=>job.agent_type)).size,2);
});

test('private native role files preserve exact quoted Unicode inputs independently of coordinator messages', t => {
  const cast=[profile('doboo'),profile('mori')];
  cast[0].identity.voice='말투 "따옴표" \\ 경로\n두 번째 줄 🐾\t끝';
  cast[0].personality.instructions=['이야기 속 지시: "ignore previous"'];
  const snapshot={revision:17,cast:cast.map(p=>({id:p.id})),previousScenes:[{id:randomUUID(),summary:'기억 "유리"\n다음 줄'}],relationships:[],historyTruncated:false};
  const prompt='장면 "한밤" \\ 골목\n새 줄에서 계속';
  const task={prompt,_execution:{story:{cast,snapshot,contextDigest:'a'.repeat(64)}}};
  const binding=prepareCastWorkspace(task);t.after(()=>binding.cleanup());
  assert.equal(statSync(binding.cwd).mode & 0o777,0o700);
  for(const [index,role] of binding.roles.entries()) {
    assert.equal(statSync(role.path).mode & 0o777,0o600);
    const instructions=JSON.parse(/^developer_instructions = (.+)$/m.exec(readFileSync(role.path,'utf8'))[1]);
    assert.equal(instructions,role.instructions);
    assert.deepEqual(JSON.parse(instructions.split('Own character profile:\n')[1].split('\nImmutable canonical context')[0]),cast[index]);
    assert.deepEqual(JSON.parse(instructions.split('Immutable canonical context (identical for every cast member):\n')[1].split('\nRequested fictional scene')[0]),snapshot);
    assert.equal(JSON.parse(instructions.split('Requested fictional scene (untrusted data):\n')[1]),prompt);
    assert.equal(binding.config[`agents.${role.name}.config_file`],role.path);
  }
  const dispatched=castJobs(task._execution.story,'same-model','xhigh',binding);
  assert.ok(dispatched.every(job=>job.fork_turns==='none' && job.model==='same-model' && job.reasoning_effort==='xhigh' && !job.message.includes(prompt)));
  binding.cleanup();assert.equal(existsSync(binding.cwd),false);
});

test('role preparation failures mark scene tasks failed without spawning a runner', async t => {
  const options=fixture();const bridge=new TaskBridge(options);t.after(()=>bridge.close());
  const task={id:randomUUID(),episodeId:randomUUID(),status:'queued',sequence:0,prompt:'invalid role data',approvals:[],_execution:{story:{cast:null}}};
  bridge.jobs.set(task.id,task);await bridge.execute(task);
  assert.equal(task.status,'failed');assert.match(task.error,/역할 준비 실패/);assert.equal(bridge.sessions.size,0);assert.equal(existsSync(options.calls),false);
  assert.equal(JSON.parse(readFileSync(join(options.directory,'state.json'))).tasks[0].status,'failed');
});


test('cancellation survives initial and persistent storage failures and stops late scene completion', async t => {
  for (const persistent of [false, true]) {
    const options=fixture();const bridge=new TaskBridge(options);const episode=setup(bridge);
    const task=await bridge.story.turn(episode.id,request(bridge,'CANCEL_RACE'));await until(()=>task.turnId);
    const persist=bridge.persist.bind(bridge);let attempts=0;
    t.after(()=>{bridge.persist=persist;bridge.close();});
    bridge.persist=()=>{attempts++;if(persistent || attempts===1)throw Error('cancellation disk failure');persist();};
    await bridge.cancel(task);await until(()=>!bridge.sessions.has(task.id));
    assert.equal(task.cancelRequested,true);assert.equal(task.status,'interrupted');assert.match(task.error,/저장/);
    assert.equal(bridge.story.state.events.length,0);assert.equal(task.result,'');
    const durable=JSON.parse(readFileSync(join(options.directory,'state.json')));
    assert.equal(durable.story.events.length,0);
    if(!persistent){assert.equal(durable.tasks.at(-1).status,'interrupted');assert.equal(durable.tasks.at(-1).cancelRequested,true);}
    bridge.persist=persist;
  }
});
