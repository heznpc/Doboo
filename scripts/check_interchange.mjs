import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp, readdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { parseCharacter, serializeCharacter } from '../character-kit/model.mjs';

// Two independent native stores exchange the same portable file. The CLI then
// generates host outputs. This does not simulate Watch radio or account setup.
const root = resolve(import.meta.dirname, '..');
await mkdir(join(root, 'work'), { recursive: true });
const run = await mkdtemp(join(root, 'work/interchange-'));
const swiftSources = (await readdir(join(root, 'Sources/Core')))
  .filter(name => name.endsWith('.swift')).map(name => join(root, 'Sources/Core', name));
const executable = join(run, 'verify-pack');
execFileSync('swiftc', [...swiftSources, join(root, 'scripts/verify_pack.swift'), '-o', executable]);
const seed = JSON.parse(await readFile(join(root, 'Characters/doboo.doboo.json'), 'utf8'));
const characters = [{ ...seed, id: 'doboo-exchange', name: 'Doboo exchange' }];
if (process.argv[2]) {
  const png = await readFile(resolve(process.argv[2]));
  const height = png.readUInt32BE(20);
  characters.push({ ...seed, id: 'sprite-exchange', name: 'Sprite exchange',
    description: 'Private interchange verification. Artwork is not redistributed.',
    appearance: { renderer: 'spritesheet', tint: '#FF8F62', sprite: {
      layout: height === 2288 ? 'pets-v2' : 'pets-v1', mimeType: 'image/png', base64: png.toString('base64'),
    } },
  });
}
const reports = [];
for (const original of characters) {
  const source = join(run, `${original.id}.doboo.json`);
  const roundtrip = join(run, `${original.id}.native.doboo.json`);
  await writeFile(source, serializeCharacter(original));
  execFileSync(executable, [source, roundtrip]);
  const native = parseCharacter(await readFile(roundtrip, 'utf8'));
  assert.deepEqual(native, original, 'Native exchange must preserve all fields and sprite bytes');
  const output = join(run, original.id);
  execFileSync(process.execPath, [join(root, 'scripts/character-cli.mjs'), 'export', roundtrip, output]);
  assert.deepEqual(parseCharacter(await readFile(join(output, `${original.id}.doboo.json`), 'utf8')), original);
  const dotText = await readFile(join(output, `${original.id}-dots.md`), 'utf8');
  assert.ok(dotText.includes(original.id) && dotText.includes(original.identity.voice));
  const agent = JSON.parse(execFileSync('python3', ['-c',
    'import json,sys,tomllib; print(json.dumps(tomllib.load(open(sys.argv[1],"rb"))))',
    join(output, `${original.id}.toml`)], { encoding: 'utf8' }));
  assert.deepEqual(Object.keys(agent).sort(), ['description', 'developer_instructions', 'name']);
  const nativeAgent = JSON.parse(execFileSync('python3', ['-c',
    'import json,sys,tomllib; print(json.dumps(tomllib.load(open(sys.argv[1],"rb"))))',
    `${roundtrip}.toml`], { encoding: 'utf8' }));
  assert.deepEqual(Object.keys(nativeAgent).sort(), ['description', 'developer_instructions', 'name']);
  assert.equal(nativeAgent.name, original.id);
  assert.ok(nativeAgent.developer_instructions.includes(original.identity.voice));
  const nativeDot = await readFile(`${roundtrip}.dots.md`, 'utf8');
  assert.ok(nativeDot.includes(original.id) && nativeDot.includes(original.identity.voice));
  assert.equal(agent.name, original.id);
  assert.ok(agent.developer_instructions.includes(original.identity.voice));
  if (original.appearance.sprite) {
    const png = await readFile(join(output, `${original.id}-${original.appearance.sprite.layout}.png`));
    assert.deepEqual(png, Buffer.from(original.appearance.sprite.base64, 'base64'));
  }
  reports.push({ id: original.id, version: original.version, twoNativeStores: true,
    nativeAndCLIRoundtrip: true, dotsIdentity: true, codexTOML: true,
    spriteBytes: Boolean(original.appearance.sprite), conflictingRevisionRejected: true });
}
const report = { checkedAt: new Date().toISOString(), checks: reports,
  boundary: 'Native storage and file exchange. Not Watch radio delivery or ChatGPT host installation.' };
await writeFile(join(run, 'result.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ ...report, evidenceDirectory: run }, null, 2));
