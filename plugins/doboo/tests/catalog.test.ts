import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm, mkdir, writeFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deflateSync } from 'node:zlib';
import { randomBytes } from 'node:crypto';
import { PersistentCatalog, CatalogError, characterDigest, type CharacterPack } from '../src/catalog.js';
import { startCatalogServer } from '../src/catalog-service.js';
import { loadCatalogConfiguration, startConfiguredCatalog } from '../src/catalog-main.js';
import { validateCharacter } from '../../../character-kit/model.mjs';
import { crc32 } from '../../../character-kit/png.mjs';

// These are explicit test identities, never presented as real external users.
const alice = { subject: 'fixture-maker-a', displayName: 'Fixture Maker A' };
const bob = { subject: 'fixture-maker-b', displayName: 'Fixture Maker B' };
const seed = JSON.parse(await readFile(new URL('../../../Characters/doboo.doboo.json', import.meta.url), 'utf8')) as CharacterPack;
const pack = (id: string, name = 'Fixture character'): CharacterPack => ({ ...structuredClone(seed), id, name, creator: 'Fixture credit' });
const status = (expected: number) => (error: unknown): boolean => error instanceof CatalogError && error.status === expected;

function transparentFixtureSheet(): string {
  const chunk = (type: string, bytes: Buffer): Buffer => {
    const name = Buffer.from(type), length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(bytes.length); checksum.writeUInt32BE(crc32(Buffer.concat([name, bytes])));
    return Buffer.concat([length, name, bytes, checksum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(1536); header.writeUInt32BE(1872, 4); header[8] = 8; header[9] = 6;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', header),
    chunk('IDAT', deflateSync(Buffer.alloc(1872 * (1536 * 4 + 1)))), chunk('IEND', Buffer.alloc(0))]).toString('base64');
}

test('catalog persists immutable revisions and keeps authenticated ownership independent of display credits', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'doboo-catalog-test-'));
  try {
    const catalog = new PersistentCatalog({ directory });
    const original = pack('fixture-soft');
    const first = await catalog.publish(alice, original);
    assert.equal(first.summary.creatorId, alice.subject);
    assert.equal(first.summary.packCreator, original.creator);
    assert.equal((await catalog.publish(alice, original)).created, false);
    await assert.rejects(catalog.publish(bob, { ...original, version: 999, creator: alice.displayName }), status(409));
    await assert.rejects(catalog.publish(alice, { ...original, name: 'Changed without version' }), status(409));
    await catalog.publish(alice, { ...original, version: 3, name: 'New revision' });
    await assert.rejects(catalog.publish(alice, { ...original, version: 2 }), status(409));
    const reopened = new PersistentCatalog({ directory });
    assert.deepEqual((await reopened.download(bob, { id: original.id, version: 1 })).character, original);
    assert.equal((await reopened.download(bob, { id: original.id })).character.version, 3);
    await assert.rejects(reopened.download(bob, { id: original.id, creatorId: bob.subject }), status(404));
    // A partial pre-commit file is ignored and cannot poison the published catalog.
    await writeFile(join(directory, 'characters', original.id, '4.json.interrupted.pending'), '{');
    assert.equal((await reopened.search(bob)).characters.length, 1);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('two writers cannot reserve the same ID, including across catalog instances', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'doboo-catalog-test-'));
  try {
    const a = new PersistentCatalog({ directory });
    const b = new PersistentCatalog({ directory });
    const results = await Promise.allSettled([a.publish(alice, pack('fixture-race')), b.publish(bob, { ...pack('fixture-race'), version: 2 })]);
    assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
    const failure = results.find(result => result.status === 'rejected') as PromiseRejectedResult;
    assert.equal(failure.reason.code, 'owner_conflict');
    assert.equal((await a.search(alice)).characters.length, 1);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('search omits full sprite artwork while a versioned download preserves every field and image byte', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'doboo-catalog-test-'));
  try {
    const catalog = new PersistentCatalog({ directory });
    const original = pack('fixture-sprite');
    original.appearance = { renderer: 'spritesheet', tint: '#FF8F62',
      sprite: { layout: 'pets-v1', mimeType: 'image/png', base64: transparentFixtureSheet() } };
    await catalog.publish(alice, original);
    const results = await catalog.search(bob, { excludeOwn: true });
    assert.equal(results.characters[0].appearance.layout, 'pets-v1');
    assert.equal(JSON.stringify(results).includes('base64'), false);
    const downloaded = await new PersistentCatalog({ directory }).download(bob, { id: original.id, version: 1 });
    assert.deepEqual(downloaded.character, original);
    assert.deepEqual(Buffer.from(downloaded.character.appearance.sprite!.base64, 'base64'), Buffer.from(original.appearance.sprite!.base64, 'base64'));
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('authenticated HTTP publish → another fixture creator searches → downloads → persists private library → reports import', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'doboo-http-test-'));
  const catalog = new PersistentCatalog({ directory: join(directory, 'shared-catalog') });
  const running = await startCatalogServer({ catalog, authenticate: token => token === 'fixture-token-a' ? alice : token === 'fixture-token-b' ? bob : null });
  const request = (path: string, token?: string, value?: unknown) => fetch(`${running.url}${path}`, {
    method: value === undefined ? 'GET' : 'POST',
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(value === undefined ? {} : { 'Content-Type': 'application/json' }) },
    ...(value === undefined ? {} : { body: JSON.stringify(value) }),
  });
  try {
    assert.equal((await request('/v1/characters')).status, 401);
    assert.equal((await request('/v1/characters', 'invalid-token')).status, 401);
    const original = pack('fixture-from-a', 'Fixture lantern companion');
    assert.equal((await request('/v1/characters', 'fixture-token-a', { character: original })).status, 201);
    assert.equal((await request('/v1/characters', 'fixture-token-b', { character: { ...original, version: 2 } })).status, 409);
    // Neither owner nor importer identities can be supplied through API bodies.
    assert.equal((await request('/v1/characters', 'fixture-token-b', { character: pack('fixture-spoof'), creatorId: alice.subject })).status, 400);
    assert.equal((await request('/v1/characters', 'fixture-token-b', { character: pack('fixture-from-b') })).status, 201);
    const results = await (await request('/v1/characters?query=lantern&excludeOwn=true', 'fixture-token-b')).json();
    assert.equal(results.total, 1);
    assert.equal(results.characters[0].creatorId, alice.subject);
    assert.equal('identity' in results.characters[0], false);
    assert.equal('sprite' in results.characters[0].appearance, false);
    const downloadResponse = await request(`/v1/characters/${original.id}/download?version=1&creatorId=${alice.subject}`, 'fixture-token-b');
    assert.equal(downloadResponse.status, 200);
    const download = await downloadResponse.json();
    assert.deepEqual(download.character, original);
    // An independent client's actual persisted private copy precedes its receipt.
    const library = join(directory, 'fixture-b-private-library');
    await mkdir(library);
    await writeFile(join(library, `${original.id}.doboo.json`), JSON.stringify(validateCharacter(download.character)), { flag: 'wx' });
    const imported = JSON.parse(await readFile(join(library, `${original.id}.doboo.json`), 'utf8')) as CharacterPack;
    assert.deepEqual(imported, original);
    const input = { id: imported.id, version: imported.version, creatorId: download.summary.creatorId, digest: characterDigest(imported) };
    const receiptResponse = await request('/v1/imports', 'fixture-token-b', input);
    assert.equal(receiptResponse.status, 200);
    const receipt = await receiptResponse.json();
    assert.equal(receipt.importerId, bob.subject);
    assert.equal(receipt.confirmation, 'client-reported');
    assert.equal((await (await request('/v1/imports', 'fixture-token-b', input)).json()).receiptId, receipt.receiptId);
    assert.equal((await request('/v1/imports', 'fixture-token-b', { ...input, digest: '0'.repeat(64) })).status, 409);
    assert.equal((await request('/v1/imports', 'fixture-token-b', { ...input, importerId: alice.subject })).status, 400);
    assert.equal((await (await request('/v1/imports', 'fixture-token-a')).json()).receipts.length, 0);
    const reopened = new PersistentCatalog({ directory: join(directory, 'shared-catalog') });
    assert.equal((await reopened.imports(bob))[0].receiptId, receipt.receiptId);
    assert.equal((await reopened.search(bob, { excludeOwn: true })).characters[0].id, original.id);
  } finally {
    await new Promise<void>((resolve, reject) => running.server.close(error => error ? reject(error) : resolve()));
    await rm(directory, { recursive: true, force: true });
  }
});

test('configured local service requires private credentials and binds only to loopback', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'doboo-service-config-test-'));
  const source = join(directory, 'catalog.config.json');
  const token = randomBytes(32).toString('hex');
  try {
    await writeFile(source, JSON.stringify({ directory: 'catalog-data', port: 0, credentials: { [token]: alice } }), { mode: 0o600 });
    const config = await loadCatalogConfiguration(source);
    assert.equal(config.directory, join(directory, 'catalog-data'));
    const running = await startConfiguredCatalog(source);
    try {
      assert.match(running.url, /^http:\/\/127\.0\.0\.1:\d+$/);
      assert.equal((await fetch(`${running.url}/v1/characters`)).status, 401);
      assert.equal((await fetch(`${running.url}/v1/characters`, { headers: { Authorization: `Bearer ${token}` } })).status, 200);
    } finally { await new Promise<void>((resolve, reject) => running.server.close(error => error ? reject(error) : resolve())); }
    await chmod(source, 0o644);
    await assert.rejects(loadCatalogConfiguration(source), /0600/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
