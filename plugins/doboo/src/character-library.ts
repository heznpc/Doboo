import { constants } from 'node:fs';
import { lstat, mkdir, open, realpath, rename, link, unlink } from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { join, resolve } from 'node:path';
import { MAX_JSON_BYTES, parseCharacter, serializeCharacter, validateCharacter } from '../../../character-kit/model.mjs';

export interface CharacterPack {
  format: 'doboo.character.v1'; id: string; version: number; name: string;
  description: string; creator: string;
  identity: { backstory: string; voice: string };
  personality: { traits: string[]; instructions: string[] };
  appearance: { renderer: 'native-doboo' | 'spritesheet'; tint: string;
    watch?: { renderer: 'native-doboo' | 'spritesheet'; tint: string; sprite?: { layout: 'pets-v1' | 'pets-v2'; mimeType: 'image/png'; base64: string } };
    sprite?: { layout: 'pets-v1' | 'pets-v2'; mimeType: 'image/png'; base64: string } };
}
export interface CharacterReference { id: string; version: number; digest: string }
export interface CharacterLibraryOptions { libraryDirectory: string }

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
export function characterReference(pack: CharacterPack): CharacterReference {
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
  // Windows does not expose O_NOFOLLOW. Check both the path and the opened
  // identity so a link or a replacement between lstat and open is rejected.
  const before = await lstat(path);
  if (!before.isFile() || before.isSymbolicLink() || before.size > MAX_JSON_BYTES) {
    throw new Error('Invalid or oversized character artifact.');
  }
  const file = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > MAX_JSON_BYTES) throw new Error('Invalid or oversized character artifact.');
    if (stat.dev !== before.dev || stat.ino !== before.ino) throw new Error('Character artifact changed before reading.');
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
export async function readCharacterFile(path: string): Promise<CharacterPack> {
  return parseCharacter((await boundedRead(path)).toString('utf8')) as CharacterPack;
}
async function existing(path: string): Promise<Buffer | undefined> {
  try { return await boundedRead(path); } catch (error) { if (isMissing(error)) return undefined; throw error; }
}
async function atomicWrite(parent: string, name: string, data: Buffer, replace: boolean): Promise<void> {
  const temporary = join(parent, `.doboo-${randomUUID()}.tmp`);
  const file = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | (constants.O_NOFOLLOW ?? 0), 0o600);
  try {
    try { await file.writeFile(data); await file.sync(); }
    finally { await file.close(); }
    if (replace) await rename(temporary, join(parent, name));
    else await link(temporary, join(parent, name)); // Atomic publication without replacing an existing file.
  } finally { await unlink(temporary).catch(error => { if (!isMissing(error)) throw error; }); }
}

/** Internal file operations shared by library persistence and host artifact adapters. */
export const characterFiles = { directory, childDirectory, existing, atomicWrite, isMissing };

/** Character ownership and persistence do not require a host or a project directory. */
export function createCharacterLibrary(options: CharacterLibraryOptions) {
  const libraryPath = resolve(options.libraryDirectory);

  async function readCharacter(id: string): Promise<CharacterPack> {
    checkId(id);
    const root = await directory(libraryPath, false);
    const pack = await readCharacterFile(join(root, `${id}.doboo.json`));
    if (pack.id !== id) throw new Error('Stored character ID does not match its library reference.');
    return pack;
  }

  async function saveCharacter(raw: unknown) {
    const character = validateCharacter(raw) as CharacterPack;
    const root = await directory(libraryPath, true);
    const name = `${character.id}.doboo.json`;
    const path = join(root, name);
    const lockPath = join(root, `.${character.id}.lock`);
    const lock = await open(lockPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | (constants.O_NOFOLLOW ?? 0), 0o600)
      .catch(error => { if ((error as NodeJS.ErrnoException).code === 'EEXIST') throw new Error('Character import is busy; retry after the current import.'); throw error; });
    try {
      const before = await existing(path);
      if (before) {
        const current = parseCharacter(before.toString('utf8')) as CharacterPack;
        if (current.id !== character.id) throw new Error('Stored character ID does not match its library reference.');
        if (canonical(current) === canonical(character)) return { character, reference: characterReference(character), path, changed: false };
        if (character.version <= current.version) throw new Error('Character version conflict. Import a higher version to update it.');
      }
      const data = Buffer.from(serializeCharacter(JSON.parse(canonical(character))));
      await atomicWrite(root, name, data, before !== undefined);
      return { character, reference: characterReference(character), path, changed: true };
    } finally { await lock.close(); await unlink(lockPath); }
  }

  return { readCharacter, saveCharacter };
}
