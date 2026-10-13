import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { characterReference, createCharacterLibrary, readCharacterFile, type CharacterPack } from '../src/character-library.js';

test('character storage works without a host, credentials or project and preserves exact revisions after reopening', async t => {
  const root = await mkdtemp(join(tmpdir(), 'doboo-library-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const libraryDirectory = join(root, 'library');
  const library = createCharacterLibrary({ libraryDirectory });
  const pack = JSON.parse(await readFile(new URL('../../../Characters/doboo.doboo.json', import.meta.url), 'utf8')) as CharacterPack;
  // A host-reserved role name remains a valid character ID in the shared library.
  pack.id = 'worker';
  pack.identity.voice = '  A voice with preserved whitespace.\r\n말투  ';
  const first = await library.saveCharacter(pack);
  assert.deepEqual(first.reference, characterReference(pack));
  assert.equal(first.changed, true);
  assert.deepEqual(await readdir(root), ['library']);
  assert.deepEqual(await readdir(libraryDirectory), ['worker.doboo.json']);

  const reopened = createCharacterLibrary({ libraryDirectory });
  assert.deepEqual(await reopened.readCharacter(pack.id), pack);
  assert.equal((await reopened.saveCharacter(pack)).changed, false);
  const conflicting = { ...pack, name: 'Different same-version content' };
  await assert.rejects(reopened.saveCharacter(conflicting), /version conflict/);
  assert.deepEqual(await library.readCharacter(pack.id), pack);

  const updated = { ...conflicting, version: pack.version + 1 };
  const savedUpdate = await reopened.saveCharacter(updated);
  assert.notEqual(savedUpdate.reference.digest, first.reference.digest);
  assert.deepEqual(await library.readCharacter(pack.id), updated);
});

test('external character file reader rejects symbolic links while retaining the target', async t => {
  const root = await mkdtemp(join(tmpdir(), 'doboo-library-links-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const library = createCharacterLibrary({ libraryDirectory: join(root, 'library') });
  const pack = JSON.parse(await readFile(new URL('../../../Characters/doboo.doboo.json', import.meta.url), 'utf8')) as CharacterPack;
  const saved = await library.saveCharacter(pack);
  assert.deepEqual(await readCharacterFile(saved.path), pack);
  const alias = join(root, 'alias.doboo.json');
  try { await symlink(saved.path, alias, 'file'); }
  catch (error) {
    if (process.platform === 'win32' && (error as NodeJS.ErrnoException).code === 'EPERM') {
      t.skip('Windows denied creation of the test symlink (EPERM); production link protection remains enabled.');
      return;
    }
    throw error;
  }
  await assert.rejects(readCharacterFile(alias), /Invalid or oversized character artifact/);
  assert.deepEqual(await readCharacterFile(saved.path), pack);
});
