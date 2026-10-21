import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { parseArgs } from 'node:util';
import { resolve } from 'node:path';
import { startBridge } from '../task-bridge/server.mjs';

// Explicit live integration test: uses the signed-in Codex model and writes local evidence.
const { values } = parseArgs({ options: { roster: { type: 'string' }, evidence: { type: 'string' } } });
if (!values.roster || !values.evidence) throw Error('Required: --roster <innercast.roles.json> --evidence <new directory>');
const root = resolve(values.evidence);
mkdirSync(root, { mode: 0o700 });
const project = root + '/project';
execFileSync('git', ['init', '-q', project]);
let app = await startBridge({project, directory:root+'/state', port:0});
const proof = {startedAt:new Date().toISOString(), scenes:[], checks:[], calls:[]};
const save=()=>writeFileSync(root+'/proof.json',JSON.stringify(proof,null,2));
async function api(path,body) {
 const response=await fetch(app.connection.url+path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+app.connection.token,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
 const result=await response.json();
 if(!response.ok)throw Error(path+': '+JSON.stringify(result));
 if(body)proof.calls.push({path,body});
 return result;
}
const state=()=>api('/v1/story');
async function mutate(path,body) {const s=await state();return api(path,{serverId:s.serverId,expectedRevision:s.revision,...body});}
async function scene(episode,prompt) {
 const task=await mutate('/v1/story/episodes/'+episode.id+'/turns',{requestId:randomUUID(),prompt});
 console.log('START',episode.title,task.id);
 const deadline=Date.now()+600000;
 let last='';
 while(Date.now()<deadline){
  const current=await api('/v1/tasks/'+task.id);
  const status=JSON.stringify({status:current.status,activity:current.activity,agents:current.castExecution?.agents?.map(a=>({character:a.characterId,status:a.status,threadId:a.threadId}))});
  if(status!==last){console.log(status);last=status;}
  if(['completed','failed','interrupted'].includes(current.status)){
   if(current.status!=='completed'){proof.failedTask=current;throw Error(current.error??current.status);}
   const s=await state();const event=s.events.find(x=>x.taskId===task.id);
   assert(event,'completed task must have canonical event');
   const execution=event.execution;
   assert.equal(execution.mode,'native_subagents');
   assert.equal(execution.agents.length,3);
   assert.equal(new Set(execution.agents.map(x=>x.threadId)).size,3);
   for(const a of execution.agents){
    assert.equal(a.status,'completed');
    assert.equal(a.parentThreadId,current.threadId);
    assert(a.turnId&&a.finalMessageId&&a.rawResult&&a.model&&a.reasoningEffort);
    assert(a.agentRole && /^[a-f0-9]{64}$/.test(a.instructionsDigest), "Host-authored role binding was not verified");
    const line=event.dialogue.find(x=>x.speakerId===a.characterId);
    assert(line);
    assert.equal(line.sourceThreadId,a.threadId);
    assert.equal(line.sourceTurnId,a.turnId);
    assert.equal(line.sourceMessageId,a.finalMessageId);
   }
   assert.equal(current.commands.length,0);
   assert.equal(current.approvals.length,0);
   const record={title:episode.title,prompt,taskId:task.id,threadId:current.threadId,turnId:current.turnId,status:current.status,context:app.bridge.jobs.get(task.id)._execution.story,event,renderedTaskResult:current.result};
   proof.scenes.push(record);save();
   console.log('SCENE_COMPLETE',JSON.stringify({title:record.title,dialogue:event.dialogue,summary:event.summary,relationshipChanges:event.relationshipChanges}));
   return record;
  }
  await new Promise(r=>setTimeout(r,1000));
 }
 throw Error('Scene timed out');
}
async function close(){app.bridge.close();await new Promise(resolve=>app.server.close(resolve));}
try {
 const roster=JSON.parse(readFileSync(values.roster,'utf8'));
 proof.characterSource={path:resolve(values.roster),version:roster.version};
 for(const c of roster.characters){
  const profile={id:c.id,version:1,name:c.displayName,identity:{backstory:c.description,voice:c.oneLine},personality:{traits:[c.archetype,...c.focus],instructions:c.rules}};
  await api('/v1/companions/'+c.id,{serverId:app.bridge.serverId,expectedRevision:0,profile,memory:''});
 }
 let s=await mutate('/v1/story/episodes',{title:'종이별 전시 · 첫날',castIds:roster.characters.map(c=>c.id)});
 const episode=s.episodes.at(-1);
 await mutate('/v1/story/relationships',{episodeId:episode.id,fromCharacterId:'doubt',toCharacterId:'spark',summary:'Doubt는 Spark가 검증을 건너뛸까 걱정하여 아직 판단을 신뢰하지 않는다.'});
 const first=await scene(episode,'작은 밤하늘 전시의 개장 40분 전. 예산 3만원, 예약 방문객 5명이다. 유리별은 배송이 지연됐고 종이와 손전등만 있다. Spark는 전시를 지키되 먼저 열과 고정 상태를 확인하는 소규모 시험을 제안했다. Doubt는 검증을 먼저 하겠다는 제안에 경계를 조금 푼다. 셋은 표식 별문-913을 시험 기록에 쓰기로 했다. 각자 자기 성격에 맞게 판단과 실행 제안을 2~3문장으로 말하라. 실제 외부 작업은 하지 않는다. 사건 요약에는 시험 표식과 달라진 판단을 기록하고, 대사에서 뒷받침되면 Doubt→Spark의 관계 변화를 제안하라.');
 const proposal=first.event.relationshipChanges.find(c=>c.fromCharacterId==='doubt'&&c.toCharacterId==='spark');
 assert(proposal,'Need an actual proposed relationship change from the scene');
 s=await mutate('/v1/story/relationships',{episodeId:episode.id,...proposal,sourceEventId:first.event.id});
 proof.acceptedRelationship=s.relationships.find(r=>r.fromCharacterId==='doubt'&&r.toCharacterId==='spark');
 proof.acceptance='The local demonstration client explicitly accepted the scene proposal through the same API as the UI.';
 await close();
 app=await startBridge({project,directory:root+'/state',port:0});
 s=await mutate('/v1/story/episodes',{title:'종이별 전시 · 둘째 날',predecessorEpisodeId:episode.id});
 const second=await scene(s.episodes.at(-1),'다음 날 같은 전시를 이어서 준비한다. 어제 기록한 시험 표식과 동료에 대한 판단이 오늘 제안에 어떤 영향을 주는지 각자 자기 관점으로 2~3문장 말하라. 이전 기억에 없는 사실은 만들지 말고, 없다면 모른다고 하라.');
 assert(second.event.execution.sourceEventIds.includes(first.event.id),'sequel must use persisted event');
 assert(second.event.execution.relationshipIds.includes(proof.acceptedRelationship.id),'sequel must use accepted relationship');
 assert(second.event.execution.agents.every(a=>second.event.dialogue.some(x=>x.speakerId===a.characterId && x.text.includes('별문-913'))),'every independent child must recall the marker absent from current prompt');
 const firstIds=new Set(first.event.execution.agents.map(x=>x.threadId));
 assert(second.event.execution.agents.every(x=>!firstIds.has(x.threadId)),'fresh child execution per episode');
 proof.checks=['Three distinct native child agents per scene','Actual child turn/message IDs linked to dialogue','All agents retain model and reasoning effort','Event memory and accepted relationship persist across bridge restart','Three new children recall the event fact absent from sequel prompt','No shell command or approval executed'];
 proof.completedAt=new Date().toISOString();save();console.log('PASS',JSON.stringify(proof.checks));
} catch(error){proof.error=String(error);save();console.error(error);process.exitCode=1;}
finally {await close();}
