import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { TaskBridge, startBridge } from './server.mjs';
const profile = id => ({ id, version: 1, name: id, identity: { backstory: `${id} background`, voice: `${id} voice` }, personality: { traits: [`${id} trait`], instructions: [] } });
function fixture() {
  const directory = mkdtempSync(join(tmpdir(), 'doboo-story-')); const codex = join(directory, 'fake-codex'); const calls = join(directory, 'calls.jsonl');
  writeFileSync(codex, `#!/usr/bin/env node
const fs=require('node:fs');const send=x=>process.stdout.write(JSON.stringify(x)+'\\n');
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
const m=JSON.parse(line);if(m.method)fs.appendFileSync(${JSON.stringify(calls)},JSON.stringify(m)+'\\n');
if(m.method==='initialize')send({id:m.id,result:{}});
if(m.method==='account/read')send({id:m.id,result:{account:{type:'chatgpt'}}});
if(m.method==='thread/start')send({id:m.id,result:{thread:{id:'thread-'+process.pid}}});
if(m.method==='turn/start'){
send({id:m.id,result:{turn:{id:'turn-'+process.pid}}});const prompt=m.params.input.at(-1).text;
if(prompt.includes('HOLD'))return;
if(prompt.includes('TOOL')){send({id:99,method:'item/commandExecution/requestApproval',params:{command:'touch unwanted'}});return;}
let result=prompt.includes('INVALID')?'not json':JSON.stringify({dialogue:[{speakerId:'doboo',text:'같이 문을 열까요?'},{speakerId:'mori',text:'이번에는 제가 먼저 해 볼게요.'}],summary:'모리가 두부를 믿고 함께 문을 열었다. '+prompt,relationshipChanges:[{fromCharacterId:'mori',toCharacterId:'doboo',summary:'문을 함께 열며 도움을 받아들이기 시작했다.'}]});
if(prompt.includes('LARGE'))result=JSON.stringify({dialogue:Array.from({length:40},(_,i)=>({speakerId:i%2?'mori':'doboo',text:'가'.repeat(4000)})),summary:'큰 장면',relationshipChanges:[]});
if(prompt.includes('EXCESSIVE'))result='x'.repeat(2*1024*1024+1);
if(prompt.includes('DELTA')){for(let i=0;i<result.length;i+=10000)send({method:'item/agentMessage/delta',params:{delta:result.slice(i,i+10000)}});}
if(!prompt.includes('DELTA_ONLY'))send({method:'item/completed',params:{item:{type:'agentMessage',text:result}}});send({method:'turn/completed',params:{turn:{status:prompt.includes('FAIL')?'failed':'completed'}}});}
if(m.method==='turn/interrupt')send({id:m.id,result:{}});
});`, { mode: 0o700 });
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
const context = options => JSON.parse(calls(options).filter(call=>call.method==='turn/start').at(-1).params.input[0].text.split('\n').slice(1).join('\n'));

test('durable fictional scenes consume distinct cast, canonical events, accepted relationships, and continue into sequels', async t => {
  const options=fixture();let bridge=new TaskBridge(options);t.after(()=>bridge.close());const episode=setup(bridge);
  const req=request(bridge,'첫 만남');const first=await bridge.story.turn(episode.id,req);await until(()=>first.status==='completed'&&!bridge.sessions.has(first.id));
  let state=bridge.story.snapshot();assert.equal(state.events.length,1);assert.equal(state.events[0].taskId,first.id);assert.equal(state.events[0].kind,'fictional_scene');assert.equal(state.relationships.length,0);
  assert.deepEqual(context(options).cast,[profile('doboo'),profile('mori')]);
  const start=calls(options).find(call=>call.method==='thread/start').params;assert.equal(start.sandbox,'read-only');assert.equal(start.ephemeral,true);assert.equal(start.approvalPolicy,'never');assert.equal(start.config['features.shell_tool'],false);assert.equal(start.config.web_search,'disabled');
  assert.equal(calls(options).find(call=>call.method==='turn/start').params.outputSchema.type,'object');
  bridge.story.relationship(input(bridge,{episodeId:episode.id,fromCharacterId:'mori',toCharacterId:'doboo',summary:'도움을 받아들이기 시작했다.',sourceEventId:first.id}));
  bridge.close();bridge=new TaskBridge(options);assert.equal((await bridge.story.turn(episode.id,req)).id,first.id);
  await assert.rejects(bridge.story.turn(episode.id,{...req,prompt:'changed'}),/같은 요청/);
  const sequel=bridge.story.createEpisode(input(bridge,{title:'두 번째 문',predecessorEpisodeId:episode.id})).episodes.at(-1);
  assert.equal(sequel.seriesId,episode.seriesId);assert.deepEqual(sequel.castProfiles,episode.castProfiles);
  const second=await complete(bridge,sequel,'문 너머로 이어서');assert.equal(second.status,'completed');assert.equal(context(options).previousScenes[0].id,first.id);assert.equal(context(options).relationships[0].sourceEventId,first.id);
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
  for(const prompt of ['FAIL','INVALID','TOOL']) {const task=await complete(bridge,episode,prompt);assert.equal(task.status,'failed');assert.equal(bridge.story.state.events.length,0);}
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
    const event=bridge.story.state.events.at(-1);assert.equal(event.dialogue.length,40);assert.equal(event.dialogue[0].text.length,4000);
    assert.ok(task.result.length>160000);
  }
  for (const prompt of ['EXCESSIVE complete', 'EXCESSIVE DELTA_ONLY']) {
    const task=await complete(bridge,episode,prompt);assert.equal(task.status,'failed');assert.match(task.error,/2 MiB/);
    assert.equal(bridge.story.state.events.length,3);
  }
});
