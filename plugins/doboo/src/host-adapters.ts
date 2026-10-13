import { constants } from 'node:fs';
import { lstat, mkdir, open, realpath, rename, link, unlink } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { join, resolve } from 'node:path';
import { MAX_JSON_BYTES, parseCharacter, serializeCharacter, validateCharacter } from '../../../character-kit/model.mjs';
import { renderCodex, renderDots } from '../../../character-kit/exporters.mjs';

export interface CharacterPack {
  format: 'doboo.character.v1'; id: string; version: number; name: string;
  description: string; creator: string;
  identity: { backstory: string; voice: string };
  personality: { traits: string[]; instructions: string[] };
  appearance: { renderer: 'native-doboo' | 'spritesheet'; tint: string;
    sprite?: { layout: 'pets-v1' | 'pets-v2'; mimeType: 'image/png'; base64: string } };
}
export interface CharacterReference { id: string; version: number; digest: string }
export type Host = 'codex' | 'pets' | 'dots';
export interface HostResult {
  host: Host; status: 'installed' | 'exported'; characterId: string; version: number;
  digest: string; path: string; changed: boolean; hostConfirmed: false;
}
export interface HostStatus {
  host: Host; status: 'installed' | 'exported' | 'not-installed' | 'not-exported' | 'unavailable' | 'conflict';
  characterId: string; version: number; digest: string; path?: string; hostConfirmed: false;
}
export interface HostAdapterOptions { libraryDirectory: string; projectDirectory: string }

const isMissing = (error: unknown) => (error as NodeJS.ErrnoException).code === 'ENOENT';
function checkId(id: string): void {
  if (typeof id !== 'string' || !/^[a-z0-9-]{1,64}$/.test(id)) throw new Error('Invalid character ID.');
}
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const object = value as Record<string, unknown>;
    return `{${Object.keys(object).sort().map(key => `${JSON.stringify(key)}:${canonical(object[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}
function reference(pack: CharacterPack): CharacterReference {
  return { id: pack.id, version: pack.version, digest: createHash('sha256').update(canonical(pack)).digest('hex') };
}
async function directory(path: string, create: boolean): Promise<string> {
  if (create) await mkdir(path, { recursive: true, mode: 0o700 });
  const stat = await lstat(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`Expected a real directory: ${path}`);
  return realpath(path);
}
async function childDirectory(parent: string, name: string, create: boolean): Promise<string> {
  const path = join(parent, name);
  if (create) await mkdir(path, { mode: 0o700 }).catch(error => {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
  });
  return directory(path, false);
}
async function boundedRead(path: string): Promise<Buffer> {
  const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > MAX_JSON_BYTES) throw new Error('Invalid or oversized character artifact.');
    // A concurrent writer cannot force an unbounded allocation after the stat.
    const data = Buffer.alloc(Math.min(stat.size + 1, MAX_JSON_BYTES + 1));
    let used = 0;
    while (used < data.length) {
      const result = await file.read(data, used, data.length - used, null);
      if (!result.bytesRead) break;
      used += result.bytesRead;
    }
    if (used > stat.size || used > MAX_JSON_BYTES) throw new Error('Character artifact changed while reading.');
    return data.subarray(0, used);
  } finally { await file.close(); }
}
async function existing(path: string): Promise<Buffer | undefined> {
  try { return await boundedRead(path); } catch (error) { if (isMissing(error)) return undefined; throw error; }
}
async function atomicWrite(parent: string, name: string, data: Buffer, replace: boolean): Promise<void> {
  const temporary = join(parent, `.doboo-${randomUUID()}.tmp`);
  const file = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    try { await file.writeFile(data); await file.sync(); }
    finally { await file.close(); }
    if (replace) await rename(temporary, join(parent, name));
    else await link(temporary, join(parent, name)); // Atomic publication without replacing an existing file.
  } finally { await unlink(temporary).catch(error => { if (!isMissing(error)) throw error; }); }
}

/** Files are host inputs, not evidence that the host loaded or ran a character.
 * No API in this adapter can manufacture a host-confirmed result.
 */
export function createHostAdapters(options: HostAdapterOptions) {
  const libraryPath = resolve(options.libraryDirectory);
  const projectPath = resolve(options.projectDirectory);

  async function readCharacter(id: string): Promise<CharacterPack> {
    checkId(id);
    const root = await directory(libraryPath, false);
    const pack = parseCharacter((await boundedRead(join(root, `${id}.doboo.json`))).toString('utf8')) as CharacterPack;
    if (pack.id !== id) throw new Error('Stored character ID does not match its library reference.');
    return pack;
  }

  async function saveCharacter(raw: unknown) {
    const character = validateCharacter(raw) as CharacterPack;
    const root = await directory(libraryPath, true);
    const name = `${character.id}.doboo.json`;
    const path = join(root, name);
    const lockPath = join(root, `.${character.id}.lock`);
    const lock = await open(lockPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600)
      .catch(error => { if ((error as NodeJS.ErrnoException).code === 'EEXIST') throw new Error('Character import is busy; retry after the current import.'); throw error; });
    try {
      const before = await existing(path);
      if (before) {
        const current = parseCharacter(before.toString('utf8')) as CharacterPack;
        if (current.id !== character.id) throw new Error('Stored character ID does not match its library reference.');
        if (canonical(current) === canonical(character)) return { character, reference: reference(character), path, changed: false };
        if (character.version <= current.version) throw new Error('Character version conflict. Import a higher version to update it.');
      }
      const data = Buffer.from(serializeCharacter(JSON.parse(canonical(character))));
      await atomicWrite(root, name, data, before !== undefined);
      return { character, reference: reference(character), path, changed: true };
    } finally { await lock.close(); await unlink(lockPath); }
  }

  async function agentDirectory(create: boolean) {
    const root = await directory(projectPath, false);
    const codex = await childDirectory(root, '.codex', create);
    return childDirectory(codex, 'agents', create);
  }

  async function publish(parent: string, name: string, data: Buffer): Promise<boolean> {
    const before = await existing(join(parent, name));
    if (before) {
      if (!before.equals(data)) throw new Error(`Existing file conflicts with this character: ${name}`);
      return false;
    }
    try { await atomicWrite(parent, name, data, false); return true; }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'EEXIST' && (await existing(join(parent, name)))?.equals(data)) return false;
      throw error;
    }
  }

  async function installCodexAgent(id: string): Promise<HostResult> {
    const pack = await readCharacter(id);
    // These names override host-provided execution roles, beyond character installation.
    if (['default', 'worker', 'explorer'].includes(id)) throw new Error('This character ID is reserved by the Codex host.');
    const parent = await agentDirectory(true);
    const name = `${id}.toml`;
    const changed = await publish(parent, name, Buffer.from(renderCodex(pack)));
    return { host: 'codex', status: 'installed', characterId: id, version: pack.version,
      digest: reference(pack).digest, path: join(parent, name), changed, hostConfirmed: false };
  }

  function exportData(pack: CharacterPack, kind: 'pets' | 'dots') {
    if (kind === 'dots') return { name: `${pack.id}-dots.md`, data: Buffer.from(renderDots(pack)) };
    if (kind !== 'pets') throw new Error('Unsupported export kind.');
    const sprite = pack.appearance.sprite;
    if (!sprite) throw new Error('This character has no Pets sprite sheet.');
    return { name: `${pack.id}-${sprite.layout}.png`, data: Buffer.from(sprite.base64, 'base64') };
  }

  async function exportCharacter(id: string, kind: 'pets' | 'dots'): Promise<HostResult> {
    const pack = await readCharacter(id);
    const artifact = exportData(pack, kind);
    const root = await directory(libraryPath, false);
    const exports = await childDirectory(root, 'exports', true);
    const parent = await childDirectory(exports, `${id}-v${pack.version}`, true);
    const changed = await publish(parent, artifact.name, artifact.data);
    return { host: kind, status: 'exported', characterId: id, version: pack.version,
      digest: reference(pack).digest, path: join(parent, artifact.name), changed, hostConfirmed: false };
  }

  async function readHostStatus(id: string): Promise<HostStatus[]> {
    const pack = await readCharacter(id);
    const base = { characterId: id, version: pack.version, digest: reference(pack).digest, hostConfirmed: false as const };
    const results: HostStatus[] = [];
    for (const host of ['codex', 'pets', 'dots'] as const) {
      if (host === 'pets' && !pack.appearance.sprite) { results.push({ ...base, host, status: 'unavailable' }); continue; }
      const missing = host === 'codex' ? 'not-installed' : 'not-exported';
      try {
        let path: string, data: Buffer;
        if (host === 'codex') { path = join(await agentDirectory(false), `${id}.toml`); data = Buffer.from(renderCodex(pack)); }
        else {
          const exports = await childDirectory(await directory(libraryPath, false), 'exports', false);
          const parent = await childDirectory(exports, `${id}-v${pack.version}`, false);
          const artifact = exportData(pack, host);
          path = join(parent, artifact.name); data = artifact.data;
        }
        const bytes = await existing(path);
        results.push({ ...base, host, path, status: !bytes ? missing : bytes.equals(data) ? host === 'codex' ? 'installed' : 'exported' : 'conflict' });
      } catch (error) {
        if (isMissing(error)) results.push({ ...base, host, status: missing });
        else throw error;
      }
    }
    return results;
  }

  return { saveCharacter, readCharacter, installCodexAgent, exportCharacter, readHostStatus };
}
