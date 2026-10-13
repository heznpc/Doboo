import { join, resolve } from 'node:path';
import { renderCodex, renderDots } from '../../../character-kit/exporters.mjs';
import { characterFiles, characterReference, createCharacterLibrary, type CharacterPack } from './character-library.js';
export type { CharacterPack, CharacterReference } from './character-library.js';

const { directory, childDirectory, existing, atomicWrite, isMissing } = characterFiles;

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

/** Files are host inputs, not evidence that the host loaded or ran a character.
 * No API in this adapter can manufacture a host-confirmed result.
 */
export function createHostAdapters(options: HostAdapterOptions) {
  const libraryPath = resolve(options.libraryDirectory);
  const projectPath = resolve(options.projectDirectory);

  const { readCharacter, saveCharacter } = createCharacterLibrary({ libraryDirectory: libraryPath });

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
      digest: characterReference(pack).digest, path: join(parent, name), changed, hostConfirmed: false };
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
      digest: characterReference(pack).digest, path: join(parent, artifact.name), changed, hostConfirmed: false };
  }

  async function readHostStatus(id: string): Promise<HostStatus[]> {
    const pack = await readCharacter(id);
    const base = { characterId: id, version: pack.version, digest: characterReference(pack).digest, hostConfirmed: false as const };
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
