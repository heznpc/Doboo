import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { repositorySnapshot, repositoryEvidence } from './work-evidence.mjs';

function fixture(t) {
  const directory = fs.mkdtempSync(join(tmpdir(), 'doboo-work-evidence-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  assert.equal(spawnSync('git', ['init', '-q', directory]).status, 0);
  const file = join(directory, 'code.mjs'); fs.writeFileSync(file, 'original code\n');
  assert.equal(spawnSync('git', ['-C', directory, 'add', '.']).status, 0);
  return { directory, file };
}

test('a read error is incomplete evidence, never a deletion or a later creation', t => {
  const { directory, file } = fixture(t), before = repositorySnapshot(directory);
  const original = fs.readFileSync;
  const mocked = t.mock.method(fs, 'readFileSync', function(path, ...args) {
    if (path === file) throw Object.assign(new Error('permission denied'), { code: 'EACCES' });
    return original.call(this, path, ...args);
  });
  syncBuiltinESMExports();
  let unreadable;
  try { unreadable = repositorySnapshot(directory); }
  finally { mocked.mock.restore(); syncBuiltinESMExports(); }
  assert.equal(unreadable.truncated, true);
  assert.equal(Object.hasOwn(unreadable.files, 'code.mjs'), false);
  for (const [left, right] of [[before, unreadable], [unreadable, before]]) {
    const evidence = repositoryEvidence(left, right);
    assert.equal(evidence.available, true); assert.equal(evidence.truncated, true);
    assert.deepEqual(evidence.changes, []);
  }
});

test('a file exceeding the hash limit is unknown instead of deleted, while ENOENT is a deletion', t => {
  const { directory, file } = fixture(t), before = repositorySnapshot(directory);
  fs.writeFileSync(file, Buffer.alloc(2 * 1024 * 1024 + 1));
  const skipped = repositoryEvidence(before, repositorySnapshot(directory));
  assert.equal(skipped.truncated, true); assert.deepEqual(skipped.changes, []);
  fs.rmSync(file);
  const deleted = repositoryEvidence(before, repositorySnapshot(directory));
  assert.equal(deleted.truncated, false);
  assert.deepEqual(deleted.changes, [{ path: 'code.mjs', beforeSHA256: before.files['code.mjs'], afterSHA256: null }]);
});

test('an unavailable repository listing cannot report every previous file as deleted', t => {
  const { directory } = fixture(t), before = repositorySnapshot(directory);
  fs.rmSync(join(directory, '.git'), { recursive: true, force: true });
  const evidence = repositoryEvidence(before, repositorySnapshot(directory));
  assert.equal(evidence.available, false); assert.equal(evidence.truncated, true);
  assert.deepEqual(evidence.changes, []);
});
