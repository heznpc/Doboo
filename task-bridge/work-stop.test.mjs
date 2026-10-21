import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { TaskBridge } from './server.mjs';
import { workMemory } from './work-evidence.mjs';

const hash = text => createHash('sha256').update(text).digest('hex');
const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
async function until(check) {
  for (let i = 0; i < 300; i++) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 20)); }
  assert.fail('Timed out waiting for fixture state');
}

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'doboo-work-stop-'));
  const project = join(root, 'project'); mkdirSync(project);
  const changedFile = join(project, 'code.mjs');
  const initial = 'export const value = 1;\n', delayed = 'export const value = 2;\n';
  writeFileSync(changedFile, initial);
  assert.equal(spawnSync('git', ['init', '-q', project]).status, 0);
  assert.equal(spawnSync('git', ['-C', project, 'add', '.']).status, 0);
  const pidFile = join(root, 'pids.json'), failFile = join(root, 'fail');
  const codex = join(root, 'fake-codex');
  const descendant = `const fs=require('node:fs');process.on('SIGTERM',()=>setTimeout(()=>fs.writeFileSync(${JSON.stringify(changedFile)},${JSON.stringify(delayed)}),150));setInterval(()=>{},100);process.send('ready');`;
  writeFileSync(codex, `#!/usr/bin/env node
const fs=require('node:fs'),spawn=require('node:child_process').spawn;
const send=value=>process.stdout.write(JSON.stringify(value)+'\\n');
const config={model:'fixture-model',model_reasoning_effort:'high',agents:{}};
for(let i=2;i<process.argv.length;i++)if(process.argv[i]==='-c'){
  const entry=process.argv[++i],at=entry.indexOf('='),key=entry.slice(0,at).split('.'),value=JSON.parse(entry.slice(at+1));
  if(key[0]==='agents'&&key.length===3)(config.agents[key[1]]??={})[key[2]]=value;
}
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
  const m=JSON.parse(line);
  if(m.method==='initialize')send({id:m.id,result:{}});
  if(m.method==='account/read')send({id:m.id,result:{account:{type:'chatgpt'}}});
  if(m.method==='config/read')send({id:m.id,result:{config}});
  if(m.method==='thread/start')send({id:m.id,result:{thread:{id:'parent'},model:'fixture-model',reasoningEffort:'high'}});
  if(m.method==='turn/start'){
    const child=spawn(process.execPath,['-e',${JSON.stringify(descendant)}],{stdio:['ignore','ignore','ignore','ipc']});
    child.once('message',()=>{
      fs.writeFileSync(${JSON.stringify(pidFile)},JSON.stringify({parent:process.pid,child:child.pid}));
      send({id:m.id,result:{turn:{id:'turn'}}});
      send({method:'turn/started',params:{threadId:'parent',turn:{id:'turn'}}});
      const timer=setInterval(()=>{if(fs.existsSync(${JSON.stringify(failFile)})){
        clearInterval(timer);send({method:'error',params:{threadId:'parent',willRetry:false,error:{message:'fixture runtime failed'}}});
      }},10);
    });
  }
  if(m.method==='turn/interrupt')send({id:m.id,result:{}});
});
`, { mode: 0o700 });
  const options = { project, directory: join(root, 'state'), codex };
  const bridge = new TaskBridge(options);
  const cast = ['doubt', 'forge'];
  for (const id of cast) bridge.updateCompanion(id, { serverId: bridge.serverId, expectedRevision: 0, memory: '',
    profile: { id, name: id, version: 1, identity: { backstory: id, voice: id }, personality: { traits: [id], instructions: [] } } });
  const request = parentTaskId => ({ id: randomUUID(), prompt: 'Change code and validate it.', character: { id: 'doubt', name: 'doubt', version: 1 },
    continuity: { serverId: bridge.serverId, companionRevision: 1, ...(parentTaskId ? { parentTaskId } : {}) },
    work: { cast: cast.map(id => ({ character: { id, name: id, version: 1 }, companionRevision: 1 })) } });
  t.after(async () => {
    await bridge.close();
    if (existsSync(pidFile)) for (const pid of Object.values(JSON.parse(readFileSync(pidFile, 'utf8')))) {
      try { process.kill(pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
    rmSync(root, { recursive: true, force: true });
  });
  return { bridge, options, request, changedFile, initial, delayed, pidFile, failFile };
}

for (const cause of ['cancel', 'runtime failure', 'shutdown']) {
  test(`${cause} persists changes made by a TERM-resistant descendant before it is killed`, { skip: process.platform === 'win32' }, async t => {
    const f = fixture(t), task = await f.bridge.submit(f.request());
    await until(() => task.turnId && existsSync(f.pidFile));
    const pids = JSON.parse(readFileSync(f.pidFile, 'utf8'));
    assert.equal(alive(pids.child), true);
    let stopped;
    if (cause === 'cancel') stopped = f.bridge.cancel(task);
    else if (cause === 'shutdown') stopped = f.bridge.close();
    else {
      writeFileSync(f.failFile, 'fail');
      stopped = until(() => task.status === 'failed' && !f.bridge.sessions.has(task.id));
    }
    await until(() => readFileSync(f.changedFile, 'utf8') === f.delayed);
    assert.equal(alive(pids.child), true);
    assert.equal(['failed', 'interrupted', 'completed'].includes(task.status), false);
    assert.equal(task.partialRepositoryEvidence, undefined);
    await assert.rejects(f.bridge.submit(f.request()), /진행 중/);
    await stopped;
    assert.equal(alive(pids.parent), false); assert.equal(alive(pids.child), false);
    assert.equal(readFileSync(f.changedFile, 'utf8'), f.delayed);
    assert.equal(task.status, cause === 'runtime failure' ? 'failed' : 'interrupted');
    assert.equal(task.workRecord, undefined); assert.equal(workMemory(task), null);
    assert.deepEqual(task.partialRepositoryEvidence.changes, [{ path: 'code.mjs', beforeSHA256: hash(f.initial), afterSHA256: hash(f.delayed) }]);
    assert.equal(task.partialRepositoryEvidence.truncated, false);
    const durable = JSON.parse(readFileSync(join(f.options.directory, 'state.json'), 'utf8')).tasks.find(value => value.id === task.id);
    assert.equal(durable.status, task.status); assert.equal(durable.workRecord, undefined);
    assert.deepEqual(durable.partialRepositoryEvidence, task.partialRepositoryEvidence);
    const restarted = new TaskBridge(f.options); t.after(() => restarted.close());
    assert.equal(workMemory(restarted.jobs.get(task.id)), null);
    await assert.rejects(restarted.submit(f.request(task.id)), /맥락/);
  });
}
