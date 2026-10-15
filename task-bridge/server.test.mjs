import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { startBridge, TaskBridge } from './server.mjs';

function setup({ interrupt = 'accept', ignoreTermination = false, spawnCommand = false } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'doboo-bridge-test-'));
  const codex = join(directory, 'fake-codex');
  const command = `process.on('SIGTERM',()=>{}); require('node:fs').writeFileSync(${JSON.stringify(join(directory, 'command-ready'))},String(process.pid)); setInterval(()=>{},100);`;
  writeFileSync(codex, `#!/usr/bin/env node
const rl=require('node:readline').createInterface({input:process.stdin});
const send=x=>process.stdout.write(JSON.stringify(x)+'\\n');
const interrupt=${JSON.stringify(interrupt)};
if (${ignoreTermination}) { process.on('SIGTERM',()=>{}); setInterval(()=>{},100); }
rl.on('line',l=>{const m=JSON.parse(l);if(m.method==='initialize')send({id:m.id,result:{}});
if(m.method==='account/read')send({id:m.id,result:{account:{type:'chatgpt'}}});
if(m.method==='thread/start')send({id:m.id,result:{thread:{id:'test-thread'}}});
if(m.method==='turn/start'){
  if (${spawnCommand}) {
    const command=require('node:child_process').spawn(process.execPath,['-e',${JSON.stringify(command)}],{stdio:'ignore'});
    require('node:fs').writeFileSync(${JSON.stringify(join(directory, 'processes.json'))},JSON.stringify({parent:process.pid,child:command.pid}));
  }
  send({id:m.id,result:{turn:{id:'test-turn'}}});send({method:'item/commandExecution/requestApproval',id:501,params:{threadId:'test-thread',command:'echo test'}});
}
if(m.id===501&&m.result){send({method:'item/completed',params:{threadId:'test-thread',item:{type:'commandExecution',command:'echo test',exitCode:0,aggregatedOutput:'test'}}});send({method:'turn/completed',params:{threadId:'test-thread',turn:{status:'completed',error:null}}});}
if(m.method==='turn/interrupt'){
  if(interrupt.startsWith('complete')) {
    send({method:'item/completed',params:{threadId:'test-thread',item:{type:'agentMessage',text:'finished before cancellation'}}});
    send({method:'turn/completed',params:{threadId:'test-thread',turn:{status:'completed',error:null}}});
  }
  if(interrupt==='reject'||interrupt==='complete-reject')send({id:m.id,error:{message:'interrupt rejected'}});
  else if(interrupt!=='timeout')send({id:m.id,result:{}});
}
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
  const conflict=await request('/v1/tasks',{...payload,prompt:'different'});
  assert.equal(conflict.status,400);assert.equal((await conflict.json()).submissionRejected,undefined);
  const busy=await request('/v1/tasks',input());
  assert.equal(busy.status,400);assert.equal((await busy.json()).submissionRejected,true);
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

for (const interrupt of ['reject', 'timeout']) {
  test(`cancel stops the child when turn/interrupt ${interrupt === 'reject' ? 'is rejected' : 'times out'}`, async t => {
    const options = { ...setup({ interrupt, ignoreTermination: interrupt === 'timeout' }), interruptTimeoutMs: 50 };
    const bridge = new TaskBridge(options); t.after(() => bridge.close());
    const task = await bridge.submit(input()); await until(() => task.status === 'needsApproval');
    await bridge.cancel(task);
    assert.equal(task.status, 'interrupted');
    assert.equal(task.approvals.length, 0);
    assert.match(task.error, /실행기를 종료했습니다/);
    await until(() => !bridge.sessions.has(task.id));
    assert.equal(JSON.parse(readFileSync(join(options.directory, 'tasks.json')))[0].status, 'interrupted');
  });
}

for (const interrupt of ['complete', 'complete-reject']) {
  test(`cancel preserves completion received before the interrupt ${interrupt === 'complete' ? 'reply' : 'error'}`, async t => {
    const bridge = new TaskBridge({ ...setup({ interrupt }), interruptTimeoutMs: 100 });
    t.after(() => bridge.close());
    const task = await bridge.submit(input()); await until(() => task.status === 'needsApproval');
    await bridge.cancel(task);
    assert.equal(task.status, 'completed');
    assert.equal(task.result, 'finished before cancellation');
    assert.equal(task.error, null);
    const sequence = task.sequence;
    await bridge.cancel(task);
    assert.equal(task.sequence, sequence);
    await until(() => !bridge.sessions.has(task.id));
  });
}

for (const ignoreTermination of [false, true]) {
  test(`cancel stops command descendants when the app server ${ignoreTermination ? 'ignores TERM' : 'exits before them'}`, { skip: process.platform === 'win32' }, async t => {
    const options = { ...setup({ interrupt: 'timeout', ignoreTermination, spawnCommand: true }), interruptTimeoutMs: 40 };
    const bridge = new TaskBridge(options);
    const pidFile = join(options.directory, 'processes.json');
    const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
    t.after(async () => {
      bridge.close();
      if (!existsSync(pidFile)) return;
      const pids = JSON.parse(readFileSync(pidFile, 'utf8'));
      // This fixture owns exactly these PIDs. Clean them even if an assertion fails.
      for (const pid of [pids.child, pids.parent]) {
        try { process.kill(pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
      }
      await until(() => !alive(pids.parent) && !alive(pids.child));
    });
    const task = await bridge.submit(input());
    await until(() => task.status === 'needsApproval' && existsSync(join(options.directory, 'command-ready')));
    const pids = JSON.parse(readFileSync(pidFile, 'utf8'));
    assert.equal(alive(pids.parent), true); assert.equal(alive(pids.child), true);
    await bridge.cancel(task);
    await until(() => !bridge.sessions.has(task.id));
    await until(() => !alive(pids.parent) && !alive(pids.child));
    assert.equal(task.status, 'interrupted');
  });
}

test('a missing app-server executable releases its session and RPC timer', async t => {
  const options = setup();
  const bridge = new TaskBridge({ ...options, codex: join(options.directory, 'does-not-exist') });
  t.after(() => bridge.close());
  const task = await bridge.submit(input());
  await until(() => task.status === 'failed' && !bridge.sessions.has(task.id));
  assert.match(task.error, /ENOENT/);
});

test('CLI shutdown waits for app-server and command descendants to stop', { skip: process.platform === 'win32' }, async t => {
  const options = setup({ interrupt: 'timeout', ignoreTermination: true, spawnCommand: true });
  const cli = spawn(process.execPath, [fileURLToPath(new URL('./server.mjs', import.meta.url)), options.project, options.directory], {
    stdio: 'ignore', env: { ...process.env, DOBOO_CODEX_BINARY: options.codex },
  });
  const pidFile = join(options.directory, 'processes.json');
  const alive = pid => { try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; } };
  t.after(async () => {
    cli.kill('SIGKILL');
    if (!existsSync(pidFile)) return;
    const pids = JSON.parse(readFileSync(pidFile, 'utf8'));
    for (const pid of [pids.child, pids.parent]) {
      try { process.kill(pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
    await until(() => !alive(pids.parent) && !alive(pids.child));
  });
  const connectionFile = join(options.directory, 'connection.json');
  await until(() => existsSync(connectionFile));
  const connection = JSON.parse(readFileSync(connectionFile, 'utf8'));
  const response = await fetch(connection.url + '/v1/tasks', { method: 'POST',
    headers: { Authorization: `Bearer ${connection.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(input()) });
  assert.equal(response.status, 200); await response.json();
  await until(() => existsSync(join(options.directory, 'command-ready')));
  const pids = JSON.parse(readFileSync(pidFile, 'utf8'));
  cli.kill('SIGTERM');
  await until(() => cli.exitCode !== null || cli.signalCode !== null);
  assert.equal(cli.exitCode, 0);
  await until(() => !alive(pids.parent) && !alive(pids.child));
});

test('submission limits reject before admission with an explicit recovery marker', async t => {
  const app = await startBridge(setup()); t.after(() => { app.bridge.close(); app.server.close(); });
  const request = payload => fetch(app.connection.url + '/v1/tasks', { method: 'POST',
    headers: { Authorization: `Bearer ${app.connection.token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
  for (const [prompt, status] of [['😀'.repeat(4001), 400], ['가'.repeat(8000), 413]]) {
    const payload = { ...input(), prompt };
    const response = await request(payload);
    assert.equal(response.status, status);
    assert.equal((await response.json()).submissionRejected, status === 400 ? true : undefined);
    assert.equal(app.bridge.jobs.has(payload.id), false);
  }
  assert.equal(app.bridge.sessions.size, 0);
  const payload = input();
  const available = 20000 - Buffer.byteLength(JSON.stringify({ ...payload, prompt: '' }));
  payload.prompt = '가'.repeat(Math.floor(available / 3)) + 'a'.repeat(available % 3);
  assert.equal(Buffer.byteLength(JSON.stringify(payload)), 20000);
  assert.equal((await request({ ...payload, prompt: payload.prompt + 'a' })).status, 413);
  assert.equal(app.bridge.jobs.size, 0);
  assert.equal((await request(payload)).status, 200);
  assert.equal(app.bridge.jobs.size, 1);
  const oversizedRetry = await request({ ...payload, padding: 'x'.repeat(21000) });
  assert.equal(oversizedRetry.status, 413);
  assert.equal((await oversizedRetry.json()).submissionRejected, undefined);
  assert.equal(app.bridge.jobs.has(payload.id), true);
});

test('server restart retains the paired address and key', async () => {
  const options = setup(); const a = await startBridge(options); const original = a.connection;
  a.bridge.close(); await new Promise(resolve => a.server.close(resolve));
  const b = await startBridge(options);
  try { assert.deepEqual(b.connection, original); } finally { b.bridge.close(); await new Promise(resolve => b.server.close(resolve)); }
});
