import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { startBridge, TaskBridge } from './server.mjs';

function setup() {
  const directory = mkdtempSync(join(tmpdir(), 'doboo-bridge-test-'));
  const codex = join(directory, 'fake-codex');
  writeFileSync(codex, `#!/usr/bin/env node
const rl=require('node:readline').createInterface({input:process.stdin});
const send=x=>process.stdout.write(JSON.stringify(x)+'\\n');
rl.on('line',l=>{const m=JSON.parse(l);if(m.method==='initialize')send({id:m.id,result:{}});
if(m.method==='account/read')send({id:m.id,result:{account:{type:'chatgpt'}}});
if(m.method==='thread/start')send({id:m.id,result:{thread:{id:'test-thread'}}});
if(m.method==='turn/start'){send({id:m.id,result:{turn:{id:'test-turn'}}});send({method:'item/commandExecution/requestApproval',id:501,params:{threadId:'test-thread',command:'echo test'}});}
if(m.id===501&&m.result){send({method:'item/completed',params:{threadId:'test-thread',item:{type:'commandExecution',command:'echo test',exitCode:0,aggregatedOutput:'test'}}});send({method:'turn/completed',params:{threadId:'test-thread',turn:{status:'completed',error:null}}});}
if(m.method==='turn/interrupt')send({id:m.id,result:{}});
});`, { mode: 0o700 });
  return { directory, project: directory, codex };
}
const input = () => ({ id: randomUUID(), prompt: 'run a test', character: { id: 'doboo', version: 4, name: 'Doboo' } });
async function until(fn) { for(let i=0;i<100;i++){if(fn())return;await new Promise(r=>setTimeout(r,20));}throw new Error('timed out'); }

test('authenticated submit is idempotent, approval is explicit, stale receipt is rejected', async t => {
  const app = await startBridge(setup()); t.after(()=>{app.bridge.close();app.server.close();});
  const request = async (path, data, auth=true) => fetch(app.connection.url+path, {method:data?'POST':'GET',headers:{...(auth?{Authorization:`Bearer ${app.connection.token}`} : {}), ...(data?{'Content-Type':'application/json'}:{})},body:data?JSON.stringify(data):undefined});
  assert.equal((await request('/v1/tasks', null, false)).status,401);
  const payload=input();assert.equal((await request('/v1/tasks',payload)).status,200);
  assert.equal((await request('/v1/tasks',payload)).status,200);assert.equal(app.bridge.jobs.size,1);
  assert.equal((await request('/v1/tasks',{...payload,character:{name:payload.character.name,version:payload.character.version,id:payload.character.id}})).status,200);
  assert.equal((await request('/v1/tasks',{...payload,prompt:'different'})).status,400);
  const task=app.bridge.jobs.get(payload.id);await until(()=>task.status==='needsApproval');
  assert.equal(task.commands.length,0);
  assert.equal((await request(`/v1/tasks/${task.id}/approval`,{id:'501',decision:'acceptForSession'})).status,400);
  assert.equal((await request(`/v1/tasks/${task.id}/approval`,{id:'501',decision:'accept'})).status,200);
  await until(()=>task.status==='completed');assert.equal(task.commands[0].exitCode,0);
  assert.equal((await request(`/v1/tasks/${task.id}/receipt`,{surface:'watch',sequence:task.sequence-1})).status,400);
  assert.equal((await request(`/v1/tasks/${task.id}/receipt`,{surface:'watch',sequence:task.sequence})).status,200);
  assert.equal(task.receipts.watch.status,'completed');
});
test('restart marks unfinished tasks interrupted without replay', async () => {
  const options=setup();const a=new TaskBridge(options);const task=await a.submit(input());await until(()=>task.status==='needsApproval');
  const b=new TaskBridge(options);assert.equal(b.jobs.get(task.id).status,'interrupted');assert.equal(b.sessions.size,0);a.close();
});
test('cancel persists interrupted and keeps actual result separate from success', async () => {
  const options=setup();const a=new TaskBridge(options);const task=await a.submit(input());await until(()=>task.turnId);await a.cancel(task);
  assert.equal(task.status,'interrupted');assert.equal(JSON.parse(readFileSync(join(options.directory,'tasks.json')))[0].status,'interrupted');a.close();
});

test('server restart retains the paired address and key', async () => {
  const options = setup(); const a = await startBridge(options); const original = a.connection;
  a.bridge.close(); await new Promise(resolve => a.server.close(resolve));
  const b = await startBridge(options);
  try { assert.deepEqual(b.connection, original); } finally { b.bridge.close(); await new Promise(resolve => b.server.close(resolve)); }
});
