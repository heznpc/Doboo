import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { CatalogClient, MAX_CATALOG_SEARCH_BYTES } from '../src/catalog-client.js';
import { PersistentCatalog, characterDigest } from '../src/catalog.js';
import { startCatalogServer } from '../src/catalog-service.js';
import { createHostAdapters } from '../src/host-adapters.js';
import type { CatalogImportInput, CatalogSummary, CharacterPack } from '../src/catalog-types.js';

const pack = JSON.parse(await readFile(new URL('../../../Characters/doboo.doboo.json', import.meta.url), 'utf8')) as CharacterPack;
const summary: CatalogSummary = { id: pack.id, version: pack.version, name: pack.name, description: pack.description,
  creatorId: 'fixture-maker', creatorName: 'Fixture maker', packCreator: pack.creator,
  traits: pack.personality.traits, appearance: { renderer: pack.appearance.renderer, tint: pack.appearance.tint },
  digest: characterDigest(pack), publishedAt: '2026-10-13T00:00:00.000Z' };
const reference = { id: pack.id, version: pack.version, creatorId: summary.creatorId };
const importInput: CatalogImportInput = { ...reference, digest: summary.digest };
const receipt = { ...importInput, receiptId: 'a'.repeat(64), importerId: 'fixture-reader',
  importedAt: '2026-10-13T00:00:00.000Z', confirmation: 'client-reported' };

async function withResponse(value: unknown, action: (client: CatalogClient) => Promise<void>, chunked = false): Promise<void> {
  const server = createServer(async (req, res) => {
    for await (const _chunk of req) { /* Consume test request without logging credentials. */ }
    const body = JSON.stringify(value);
    res.writeHead(200, { 'Content-Type': 'application/json', ...(chunked ? {} : { 'Content-Length': Buffer.byteLength(body) }) });
    if (chunked) res.write(body.slice(0, 128));
    res.end(chunked ? body.slice(128) : body);
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  try { await action(new CatalogClient(`http://127.0.0.1:${(server.address() as AddressInfo).port}`, 'fixture-token')); }
  finally { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
}

test('client exchanges a revision through authenticated HTTP and persists it before its exact import receipt', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'doboo-client-test-'));
  const catalog = new PersistentCatalog({ directory: join(directory, 'catalog') });
  const running = await startCatalogServer({ catalog, authenticate: token => token === 'fixture-maker-token'
    ? { subject: 'fixture-maker', displayName: 'Fixture maker' }
    : token === 'fixture-reader-token' ? { subject: 'fixture-reader', displayName: 'Fixture reader' } : null });
  try {
    const creator = new CatalogClient(running.url, 'fixture-maker-token');
    const reader = new CatalogClient(running.url, 'fixture-reader-token');
    const published = await creator.publish(pack);
    assert.equal(published.summary.creatorId, reference.creatorId);
    assert.equal(published.created, true);
    assert.equal((await creator.search({ excludeOwn: true })).total, 0);
    const found = await reader.search({ excludeOwn: true });
    assert.equal(found.characters[0].digest, summary.digest);
    assert.deepEqual(Object.keys(found).sort(), ['characters', 'total']);
    const download = await reader.download(reference);
    const local = createHostAdapters({ libraryDirectory: join(directory, 'library'), projectDirectory: directory });
    const saved = await local.saveCharacter(download.character);
    assert.equal(saved.reference.digest, download.summary.digest);
    const imported = await reader.recordImport({ ...reference, digest: saved.reference.digest });
    assert.equal(imported.confirmation, 'client-reported');
    assert.equal(imported.importerId, 'fixture-reader');
    assert.deepEqual(await local.readCharacter(pack.id), pack);
    assert.equal((await catalog.imports({ subject: 'fixture-reader', displayName: 'Fixture reader' }))[0].receiptId, imported.receiptId);
  } finally {
    await new Promise<void>((resolve, reject) => running.server.close(error => error ? reject(error) : resolve()));
    await rm(directory, { recursive: true, force: true });
  }
});

test('search rejects unknown status claims, hidden image payloads and malformed catalog summaries', async () => {
  const cases = [
    { characters: [summary], total: 1, hostApplied: true },
    { characters: [{ ...summary, hostApplied: true }], total: 1 },
    { characters: [{ ...summary, appearance: { ...summary.appearance, sprite: { base64: 'untrusted image' } } }], total: 1 },
    { characters: [{ ...summary, traits: ['x'.repeat(161)] }], total: 1 },
    { characters: [{ ...summary, creatorId: 'x'.repeat(201) }], total: 1 },
    { characters: [{ ...summary, version: Number.MAX_SAFE_INTEGER + 1 }], total: 1 },
    { characters: [{ ...summary, appearance: { renderer: 'spritesheet', tint: '#123456' } }], total: 1 },
    { characters: [{ ...summary, publishedAt: 'not-a-date' }], total: 1 },
    { characters: [summary], total: 0 },
    { characters: [summary, summary], total: 2 },
  ];
  for (const value of cases) await withResponse(value, async client => { await assert.rejects(client.search(), /Invalid catalog metadata/); });
});

test('search bounds count and bytes including a chunked response without Content-Length', async () => {
  const excessive = { characters: Array.from({ length: 101 }, (_, i) => ({ ...summary, id: `fixture-${i}` })), total: 101 };
  await withResponse(excessive, async client => { await assert.rejects(client.search({ limit: 100 }), /Invalid catalog metadata/); });
  await withResponse({ characters: [summary], total: 1 }, async client => { await assert.rejects(client.search({ limit: 0 })); });
  for (const chunked of [false, true]) {
    await withResponse({ characters: [summary], total: 1, padding: 'x'.repeat(MAX_CATALOG_SEARCH_BYTES) }, async client => {
      await assert.rejects(client.search(), /size limit/);
    }, chunked);
  }
  const fullPage = { characters: Array.from({ length: 100 }, (_, i) => ({ ...summary, id: `fixture-${i}`,
    name: '🙂'.repeat(80), description: '🙂'.repeat(500), creatorName: '🙂'.repeat(80), packCreator: '🙂'.repeat(80),
    traits: Array.from({ length: 20 }, () => '🙂'.repeat(160)) })), total: 100 };
  await withResponse(fullPage, async client => { assert.equal((await client.search({ limit: 100 })).characters.length, 100); });
});

test('publish accepts only bounded metadata that describes the submitted character', async () => {
  await withResponse({ summary, created: true, hostApplied: true }, async client => {
    await assert.rejects(client.publish(pack), /Invalid catalog metadata/);
  });
  for (const changed of [{ ...summary, digest: '0'.repeat(64) }, { ...summary, name: 'Wrong display name' }]) {
    await withResponse({ summary: changed, created: true }, async client => { await assert.rejects(client.publish(pack), /different character revision/); });
  }
  await withResponse({ summary: { ...summary, description: 'x'.repeat(40_000) }, created: true }, async client => {
    await assert.rejects(client.publish(pack), /size limit/);
  });
});

test('download rejects forged owner, digest, display metadata and activation claims', async () => {
  for (const changed of [{ ...summary, creatorId: 'fixture-other-maker' }, { ...summary, digest: '0'.repeat(64) }, { ...summary, traits: ['forged trait'] }]) {
    await withResponse({ character: pack, summary: changed }, async client => { await assert.rejects(client.download(reference), /different character revision/); });
  }
  await withResponse({ character: pack, summary, hostApplied: true }, async client => { await assert.rejects(client.download(reference), /Invalid catalog metadata/); });
});

test('receipt remains client-reported and must match the imported reference and digest', async () => {
  for (const changed of [{ ...receipt, confirmation: 'host-confirmed' }, { ...receipt, hostApplied: true }]) {
    await withResponse(changed, async client => { await assert.rejects(client.recordImport(importInput), /Invalid catalog metadata/); });
  }
  for (const changed of [{ ...receipt, version: pack.version + 1 }, { ...receipt, digest: '0'.repeat(64) }, { ...receipt, creatorId: 'fixture-other-maker' }]) {
    await withResponse(changed, async client => { await assert.rejects(client.recordImport(importInput), /different character revision/); });
  }
  await withResponse({ ...receipt, padding: 'x'.repeat(40_000) }, async client => { await assert.rejects(client.recordImport(importInput), /size limit/); });
});
