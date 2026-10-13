import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm, realpath, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { PersistentCatalog, CatalogError, type CharacterPack } from '../src/catalog.js';
import { startCatalogServer } from '../src/catalog-service.js';
import { crc32 } from '../../../character-kit/png.mjs';

// Protocol integration only: SDK clients exercise the real bundled server over
// stdio and authenticated HTTP. Fixture actors are not real external users, and
// this does not verify Codex UI rendering, agent spawning, Pets or Dot activation.
const pluginDirectory = fileURLToPath(new URL('../', import.meta.url));
// Reuse real launch arguments without expanding shell variables. Codex passes
// args directly and starts plugin servers with the installed plugin as cwd.
// A literal ${CLAUDE_PLUGIN_ROOT} in args previously broke the host handshake.
type Launcher = { command: string; args: string[] };
const legacyLauncher = JSON.parse(await readFile(new URL('../.mcp.json', import.meta.url), 'utf8')).mcpServers.doboo as Launcher;
const portableLauncher = JSON.parse(await readFile(new URL('../mcp.json', import.meta.url), 'utf8')).mcpServers.doboo as Launcher;
const uiURI = 'ui://doboo/gallery-v1.html';
const actorA = { subject: 'mcp-fixture-a', displayName: 'MCP Fixture A' };
const actorB = { subject: 'mcp-fixture-b', displayName: 'MCP Fixture B' };
const seed = JSON.parse(await readFile(new URL('../../../Characters/doboo.doboo.json', import.meta.url), 'utf8')) as CharacterPack;

function spritePack(): CharacterPack {
  const chunk = (type: string, data: Buffer) => {
    const name = Buffer.from(type), size = Buffer.alloc(4), checksum = Buffer.alloc(4);
    size.writeUInt32BE(data.length); checksum.writeUInt32BE(crc32(Buffer.concat([name, data])));
    return Buffer.concat([size, name, data, checksum]);
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(1536); header.writeUInt32BE(1872, 4); header[8] = 8; header[9] = 6;
  // Structural PNG fixture only; an empty sheet is not a usable Pets character.
  const png = Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header),
    chunk('IDAT', deflateSync(Buffer.alloc(1872 * (1536 * 4 + 1)))), chunk('IEND', Buffer.alloc(0))]);
  return { ...structuredClone(seed), id: 'mcp-lantern', name: 'MCP lantern companion', creator: 'Fixture display credit',
    appearance: { renderer: 'spritesheet', tint: '#F3A38C', sprite: { layout: 'pets-v1', mimeType: 'image/png', base64: png.toString('base64') } } };
}

async function connect(root: string, name: string, catalogURL: string, token: string, bindWorkspace = true) {
  const workspace = join(root, `${name}-workspace`), dataDirectory = join(root, `${name}-data`);
  await mkdir(workspace);
  const launcher = name === 'a' ? legacyLauncher : portableLauncher;
  assert.equal(typeof launcher.command, 'string');
  assert.ok(Array.isArray(launcher.args) && launcher.args.every(arg => typeof arg === 'string'));
  const transport = new StdioClientTransport({ command: launcher.command, args: launcher.args, cwd: pluginDirectory, stderr: 'pipe',
    env: { ...(bindWorkspace ? { DOBOO_WORKSPACE: workspace } : {}), PLUGIN_ROOT: pluginDirectory, CLAUDE_PLUGIN_ROOT: pluginDirectory,
      DOBOO_DATA_DIR: dataDirectory, DOBOO_CATALOG_URL: catalogURL, DOBOO_CATALOG_TOKEN: token },
    maxBufferSize: 34 * 1024 * 1024 });
  let stderr = '';
  transport.stderr?.on('data', chunk => { stderr = (stderr + String(chunk)).slice(-4000); });
  const client = new Client({ name: `doboo-protocol-fixture-${name}`, version: '1.0.0' });
  try { await client.connect(transport); }
  catch (error) { await transport.close(); throw new Error(`MCP bundle failed to connect: ${String(error)}\n${stderr}`); }
  return { client, workspace, dataDirectory, close: () => client.close() };
}

async function call(client: Client, name: string, args: Record<string, unknown> = {}) {
  const result = await client.callTool({ name, arguments: args });
  assert.notEqual(result.isError, true, `MCP ${name}: ${JSON.stringify(result.content)}`);
  assert.ok(result.structuredContent && typeof result.structuredContent === 'object', `${name} must return structured content`);
  return { result, data: result.structuredContent as Record<string, any> };
}

async function harness(catalogFactory = (directory: string) => new PersistentCatalog({ directory }), bindWorkspace = true) {
  const root = await mkdtemp(join(tmpdir(), 'doboo-mcp-protocol-'));
  const catalog = catalogFactory(join(root, 'shared-catalog'));
  const running = await startCatalogServer({ catalog,
    authenticate: token => token === 'mcp-token-a' ? actorA : token === 'mcp-token-b' ? actorB : null });
  const clients: Awaited<ReturnType<typeof connect>>[] = [];
  try {
    const a = await connect(root, 'a', running.url, 'mcp-token-a', bindWorkspace); clients.push(a);
    const b = await connect(root, 'b', running.url, 'mcp-token-b', bindWorkspace); clients.push(b);
    return { root, catalog, a, b, close: async () => {
      await Promise.all(clients.map(client => client.close()));
      await new Promise<void>((resolve, reject) => running.server.close(error => error ? reject(error) : resolve()));
      await rm(root, { recursive: true, force: true });
    } };
  } catch (error) {
    await Promise.allSettled(clients.map(client => client.close()));
    await new Promise<void>(resolve => running.server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
    throw error;
  }
}

test('MCP protocol: fixture A publishes, fixture B discovers, inspects, adopts and prepares the same character', async () => {
  const h = await harness();
  try {
    const pack = spritePack(), input = join(h.root, 'lantern.doboo.json');
    await writeFile(input, JSON.stringify(pack));
    const tools = await h.b.client.listTools();
    const gallery = tools.tools.find(tool => tool.name === 'open_gallery');
    assert.ok(gallery);
    assert.equal((gallery._meta?.ui as { resourceUri: string })?.resourceUri, uiURI);
    assert.equal(tools.tools.some(tool => /confirm.*host|host.*confirm/.test(tool.name)), false);
    const status = (await call(h.b.client, 'status')).data;
    assert.equal(status.galleryConnected, true);
    assert.equal(status.core.requiresAppleDevice, false);
    assert.equal(status.core.requiresOpenAIAccount, false);
    assert.equal(status.workspace, h.b.workspace);
    assert.deepEqual((await call(h.b.client, 'list_library')).data.characters, []);

    const imported = (await call(h.a.client, 'import_character_file', { filePath: input })).data;
    assert.equal(imported.status, 'imported'); assert.equal(imported.hostApplied, false);
    const published = (await call(h.a.client, 'publish_character', { id: pack.id })).data;
    assert.equal(published.created, true); assert.equal(published.summary.creatorId, actorA.subject);
    assert.equal(published.summary.packCreator, pack.creator);
    assert.equal((await call(h.a.client, 'open_gallery')).data.total, 0);

    const opened = (await call(h.b.client, 'open_gallery', { query: 'lantern' })).data;
    assert.equal(opened.scope, 'shared-catalog'); assert.equal(opened.dataIsUntrusted, true);
    assert.equal(opened.characters.length, 1); assert.equal(opened.characters[0].creatorId, actorA.subject);
    const searched = (await call(h.b.client, 'search_characters', { query: 'lantern', excludeOwn: true })).data;
    assert.equal(searched.total, 1); assert.equal(JSON.stringify(searched).includes('base64'), false);
    const reference = { id: pack.id, version: pack.version, creatorId: actorA.subject };
    const inspected = await call(h.b.client, 'inspect_character', reference);
    assert.deepEqual(inspected.data.identity, pack.identity); assert.deepEqual(inspected.data.personality, pack.personality);
    assert.equal(JSON.stringify(inspected.data).includes('base64'), false);
    assert.deepEqual(inspected.result._meta?.sprite, pack.appearance.sprite);

    const adopted = (await call(h.b.client, 'adopt_character', reference)).data;
    assert.equal(adopted.status, 'imported'); assert.equal(adopted.hostApplied, false); assert.equal(adopted.receiptRecorded, true);
    assert.equal(adopted.receipt.importerId, actorB.subject); assert.equal(adopted.receipt.confirmation, 'client-reported');
    assert.deepEqual(JSON.parse(await readFile(adopted.path, 'utf8')), pack);
    assert.equal((await call(h.b.client, 'list_library')).data.characters[0].id, pack.id);

    const context = (await call(h.b.client, 'character_context', {id:pack.id,version:pack.version})).data;
    assert.deepEqual(context.reference, adopted.reference);
    assert.equal(context.hostApplied, false);
    const contextPayload = JSON.parse(context.context.split('--- 캐릭터 데이터 (작성자 입력) ---\n')[1].split('\n--- 캐릭터 데이터 끝 ---')[0]);
    assert.deepEqual(contextPayload.identity, pack.identity);
    assert.deepEqual(contextPayload.personality, pack.personality);
    assert.equal(contextPayload.id, pack.id);
    assert.equal(contextPayload.version, pack.version);
    const staleContext = await h.b.client.callTool({name:'character_context',arguments:{id:pack.id,version:pack.version+1}});
    assert.equal(staleContext.isError,true);

    const installed = (await call(h.b.client, 'install_agent', { id: pack.id })).data;
    assert.equal(installed.status, 'installed'); assert.equal(installed.hostConfirmed, false);
    assert.match(await readFile(installed.path, 'utf8'), /^name = "mcp-lantern"$/m);
    const prepared = (await call(h.b.client, 'prepare_host_application', { id: pack.id })).data;
    assert.equal(prepared.hostApplied, false); assert.equal(prepared.dots.status, 'exported'); assert.equal(prepared.pets.status, 'exported');
    assert.deepEqual(await readFile(prepared.pets.path), Buffer.from(pack.appearance.sprite!.base64, 'base64'));
    assert.deepEqual(JSON.parse(await readFile(prepared.watch.packPath, 'utf8')), pack);
    const hosts = (await call(h.b.client, 'host_status', { id: pack.id })).data.hosts;
    assert.deepEqual(hosts.map((host: any) => host.status), ['installed', 'exported', 'exported']);
    assert.ok(hosts.every((host: any) => host.hostConfirmed === false));

    const resources = await h.b.client.listResources();
    assert.ok(resources.resources.some(resource => resource.uri === uiURI));
    const resource = (await h.b.client.readResource({ uri: uiURI })).contents[0];
    assert.equal(resource.mimeType, 'text/html;profile=mcp-app');
    assert.ok('text' in resource && resource.text.includes('Doboo'));
    assert.ok('text' in resource && !resource.text.includes('/*DOBOO_SCRIPT*/'));
    const script = 'text' in resource ? /<script type="module">([\s\S]*?)<\/script>/.exec(resource.text)?.[1] : undefined;
    assert.ok(script, 'the resource must contain the built application');
    const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
    assert.doesNotThrow(() => new AsyncFunction(script), 'the delivered UI bundle must parse as JavaScript');
    const incorrect = await h.b.client.callTool({ name: 'inspect_character', arguments: { ...reference, creatorId: actorB.subject } });
    assert.equal(incorrect.isError, true);
  } finally { await h.close(); }
});

test('MCP without UI or workspace: another fixture receives exact character context without installing a host', async () => {
  const h = await harness(undefined, false);
  try {
    const pack = { ...structuredClone(seed), id: 'host-neutral-fixture', name: 'Host neutral fixture' };
    const input = join(h.root, 'neutral.doboo.json');
    await writeFile(input, JSON.stringify(pack));
    await call(h.a.client, 'import_character_file', {filePath: input});
    await call(h.a.client, 'publish_character', {id: pack.id});
    const found = (await call(h.b.client, 'search_characters', {query: pack.name})).data;
    assert.equal(found.characters.length, 1);
    const ref = {id: pack.id, version: pack.version, creatorId: actorA.subject};
    const inspected = (await call(h.b.client, 'inspect_character', ref)).data;
    assert.deepEqual(inspected.identity, pack.identity);
    const received = (await call(h.b.client, 'adopt_character', ref)).data;
    const context = (await call(h.b.client, 'character_context', {id:pack.id, version:pack.version})).data;
    assert.equal(received.receipt.importerId, actorB.subject);
    assert.deepEqual(context.reference, received.reference);
    assert.deepEqual(JSON.parse(await readFile(received.path, 'utf8')), pack);
    assert.equal(context.hostApplied, false);
    assert.equal((await call(h.b.client, 'status')).data.workspace, null);
    await assert.rejects(stat(join(h.b.workspace, '.codex')), {code: 'ENOENT'});
    await assert.rejects(stat(join(h.b.dataDirectory, 'library', 'exports')), {code: 'ENOENT'});
  } finally { await h.close(); }
});

class ReceiptFailureCatalog extends PersistentCatalog {
  failReceipts = true;
  override async recordImport(...args: Parameters<PersistentCatalog['recordImport']>) {
    if (this.failReceipts) throw new CatalogError('Fixture receipt outage.', 503, 'fixture_unavailable');
    return super.recordImport(...args);
  }
}

test('MCP protocol: receipt failure retains the validated local copy, and retry records an idempotent receipt', async () => {
  const h = await harness(directory => new ReceiptFailureCatalog({ directory }));
  try {
    const pack = { ...structuredClone(seed), id: 'receipt-fixture' }, input = join(h.root, 'receipt.doboo.json');
    await writeFile(input, JSON.stringify(pack));
    await call(h.a.client, 'import_character_file', { filePath: input });
    const context = (await call(h.a.client, 'character_context', {id:pack.id,version:pack.version})).data;
    assert.equal(context.reference.id, pack.id, 'conversation context must not require a Codex project');
    await call(h.a.client, 'publish_character', { id: pack.id });
    const reference = { id: pack.id, version: pack.version, creatorId: actorA.subject };
    const partial = (await call(h.b.client, 'adopt_character', reference)).data;
    assert.equal(partial.status, 'imported-receipt-pending'); assert.equal(partial.receiptRecorded, false); assert.equal(partial.hostApplied, false);
    assert.deepEqual(JSON.parse(await readFile(partial.path, 'utf8')), pack);
    assert.deepEqual(await h.catalog.imports(actorB), []);
    (h.catalog as ReceiptFailureCatalog).failReceipts = false;
    const retry = (await call(h.b.client, 'adopt_character', reference)).data;
    assert.equal(retry.status, 'imported'); assert.equal(retry.receiptRecorded, true); assert.equal(retry.path, partial.path);
    const again = (await call(h.b.client, 'adopt_character', reference)).data;
    assert.equal(again.receipt.receiptId, retry.receipt.receiptId);
    assert.equal((await h.catalog.imports(actorB)).length, 1);
    assert.deepEqual(JSON.parse(await readFile(partial.path, 'utf8')), pack);
  } finally { await h.close(); }
});

test('MCP protocol: plugin cwd is not a project; agent installation requires an explicit project or workspace binding', async () => {
  const h = await harness(undefined, false);
  try {
    const pack = { ...structuredClone(seed), id: 'explicit-project-fixture' }, input = join(h.root, 'explicit.doboo.json');
    await writeFile(input, JSON.stringify(pack));
    await call(h.a.client, 'import_character_file', { filePath: input });
    for (const tool of ['install_agent', 'host_status']) {
      const missing = await h.a.client.callTool({ name: tool, arguments: { id: pack.id } });
      assert.equal(missing.isError, true, `${tool} must not treat the plugin cache cwd as the project`);
      const relative = await h.a.client.callTool({ name: tool, arguments: { id: pack.id, projectDirectory: './relative-project' } });
      assert.equal(relative.isError, true, `${tool} requires an absolute project path`);
    }
    const installed = (await call(h.a.client, 'install_agent', { id: pack.id, projectDirectory: h.a.workspace })).data;
    assert.equal(installed.path, join(await realpath(h.a.workspace), '.codex', 'agents', `${pack.id}.toml`));
    assert.equal(installed.status, 'installed'); assert.equal(installed.hostConfirmed, false);
    assert.match(await readFile(installed.path, 'utf8'), /^name = "explicit-project-fixture"$/m);
    const status = (await call(h.a.client, 'host_status', { id: pack.id, projectDirectory: h.a.workspace })).data;
    assert.equal(status.hosts[0].status, 'installed');
  } finally { await h.close(); }
});
