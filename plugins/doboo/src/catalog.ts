import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readdir, readFile, link, rm, open, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { validateCharacter, MAX_JSON_BYTES } from '../../../character-kit/model.mjs';
import type { CatalogPrincipal, CatalogRef, CatalogSummary, CatalogDownload, CatalogSearch,
  CatalogImportInput, CatalogImportReceipt, CharacterPack } from './catalog-types.js';
export type * from './catalog-types.js';

export class CatalogError extends Error {
  constructor(message: string, public status = 400, public code = 'invalid_request') { super(message); }
}
interface StoredRevision {
  format: 'doboo.catalog-revision.v1'; creatorId: string; creatorName: string;
  publishedAt: string; digest: string; character: CharacterPack;
}
const canonical = (value: unknown): string => JSON.stringify(value, (_, entry) => entry && typeof entry === 'object' && !Array.isArray(entry)
  ? Object.fromEntries(Object.keys(entry).sort().map(key => [key, entry[key]])) : entry);
export const characterDigest = (character: CharacterPack): string => createHash('sha256').update(canonical(character)).digest('hex');
function principal(value: CatalogPrincipal): CatalogPrincipal {
  if (!value || typeof value.subject !== 'string' || !value.subject.trim() || value.subject.length > 200 || /[\x00-\x1f\x7f]/.test(value.subject)
    || typeof value.displayName !== 'string' || !value.displayName.trim() || [...value.displayName].length > 80 || /[\x00-\x1f\x7f]/.test(value.displayName)) {
    throw new CatalogError('An authenticated catalog identity is required.', 401, 'unauthorized');
  }
  return { subject: value.subject, displayName: value.displayName };
}
function ref(value: CatalogRef): void {
  if (!value || typeof value.id !== 'string' || !/^[a-z0-9-]{1,64}$/.test(value.id)
    || value.version !== undefined && (!Number.isSafeInteger(value.version) || value.version < 1)
    || value.creatorId !== undefined && (typeof value.creatorId !== 'string' || !value.creatorId)) {
    throw new CatalogError('Invalid character reference.');
  }
}
function summary(revision: StoredRevision): CatalogSummary {
  const c = revision.character;
  return { id: c.id, version: c.version, name: c.name, description: c.description,
    creatorId: revision.creatorId, creatorName: revision.creatorName, packCreator: c.creator,
    traits: [...c.personality.traits], appearance: { renderer: c.appearance.renderer, tint: c.appearance.tint,
      ...(c.appearance.sprite ? { layout: c.appearance.sprite.layout } : {}) },
    digest: revision.digest, publishedAt: revision.publishedAt };
}

/** One shared catalog, separate from every client's private library.
 * V1 globally reserves pack.id to its first authenticated owner because native
 * libraries currently key by pack.id. A same-ID higher version from another
 * principal must never masquerade as an update.
 */
export class PersistentCatalog {
  readonly directory: string;
  constructor({ directory }: { directory: string }) { this.directory = resolve(directory); }

  private async prepare(): Promise<void> { await mkdir(this.directory, { recursive: true, mode: 0o700 }); }
  private async readRevision(path: string): Promise<StoredRevision> {
    const size = await stat(path);
    if (!size.isFile() || size.size > MAX_JSON_BYTES + 4096) throw new CatalogError('Stored catalog file is invalid.', 500, 'storage_invalid');
    let raw: StoredRevision;
    let character: CharacterPack;
    try {
      raw = JSON.parse(await readFile(path, 'utf8')) as StoredRevision;
      character = validateCharacter(raw.character) as CharacterPack;
    } catch { throw new CatalogError('Stored catalog revision is invalid; the source file has been kept.', 500, 'storage_invalid'); }
    if (raw.format !== 'doboo.catalog-revision.v1' || !raw.creatorId || !raw.creatorName
      || raw.digest !== characterDigest(character) || !Number.isFinite(Date.parse(raw.publishedAt))) {
      throw new CatalogError('Stored catalog revision failed integrity verification.', 500, 'storage_invalid');
    }
    return { ...raw, character };
  }
  private async revisions(id: string): Promise<StoredRevision[]> {
    const directory = join(this.directory, 'characters', id);
    let names: string[];
    try { names = await readdir(directory); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []; throw error; }
    const entries: StoredRevision[] = [];
    for (const name of names) {
      if (!/^[1-9][0-9]*\.json$/.test(name)) continue;
      const entry = await this.readRevision(join(directory, name));
      if (entry.character.id !== id || name !== `${entry.character.version}.json`
        || entries.some(old => old.creatorId !== entry.creatorId)) {
        throw new CatalogError('Stored ownership or version conflict.', 500, 'storage_invalid');
      }
      entries.push(entry);
    }
    return entries.sort((a, b) => b.character.version - a.character.version);
  }
  /** Serialize writes across service instances; an interrupted lock fails closed.
   * A stale lock requires an operator to verify the old service has stopped before
   * removing catalog.write-lock. Published revisions are never overwritten.
   */
  private async transaction<T>(action: () => Promise<T>): Promise<T> {
    await this.prepare();
    const lock = join(this.directory, 'catalog.write-lock');
    let acquired = false;
    for (let attempt = 0; attempt < 200; attempt++) {
      try { await mkdir(lock, { mode: 0o700 }); acquired = true; break; }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; await delay(25); }
    }
    if (!acquired) throw new CatalogError('Catalog storage is locked. Check the previous writer before retrying.', 503, 'storage_locked');
    try { return await action(); }
    finally { await rm(lock, { recursive: true }); }
  }
  private async createImmutable(path: string, value: unknown): Promise<void> {
    const temporary = `${path}.${randomUUID()}.pending`;
    try {
      const handle = await open(temporary, 'wx', 0o600);
      try { await handle.writeFile(`${JSON.stringify(value)}\n`); await handle.sync(); }
      finally { await handle.close(); }
      // Linking commits only a fully written file and refuses to replace a revision.
      await link(temporary, path);
    } finally { await rm(temporary, { force: true }); }
  }

  async publish(actor: CatalogPrincipal, raw: unknown): Promise<{ character: CharacterPack; summary: CatalogSummary; created: boolean }> {
    const owner = principal(actor);
    const character = validateCharacter(raw) as CharacterPack;
    const digest = characterDigest(character);
    return this.transaction(async () => {
      const entries = await this.revisions(character.id);
      if (entries.length && entries[0].creatorId !== owner.subject) {
        throw new CatalogError('This character ID belongs to another catalog creator. Choose a new ID.', 409, 'owner_conflict');
      }
      const same = entries.find(entry => entry.character.version === character.version);
      if (same) {
        if (same.digest !== digest) throw new CatalogError('A published version is immutable. Publish a higher version.', 409, 'version_conflict');
        return { character: same.character, summary: summary(same), created: false };
      }
      if (entries.length && character.version <= entries[0].character.version) {
        throw new CatalogError('New publications must have a higher version.', 409, 'version_conflict');
      }
      const entry: StoredRevision = { format: 'doboo.catalog-revision.v1', creatorId: owner.subject,
        creatorName: owner.displayName, digest, publishedAt: new Date().toISOString(), character };
      const directory = join(this.directory, 'characters', character.id);
      await mkdir(directory, { recursive: true, mode: 0o700 });
      await this.createImmutable(join(directory, `${character.version}.json`), entry);
      return { character, summary: summary(entry), created: true };
    });
  }

  async search(actor: CatalogPrincipal, options: CatalogSearch = {}): Promise<{ characters: CatalogSummary[]; total: number }> {
    const viewer = principal(actor);
    const { query = '', creatorId, excludeOwn = false, limit = 50, offset = 0 } = options;
    if (typeof query !== 'string' || query.length > 200 || creatorId !== undefined && typeof creatorId !== 'string'
      || typeof excludeOwn !== 'boolean' || !Number.isInteger(limit) || limit < 1 || limit > 100
      || !Number.isInteger(offset) || offset < 0) throw new CatalogError('Invalid catalog search.');
    await this.prepare();
    let ids: string[];
    try { ids = await readdir(join(this.directory, 'characters')); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return { characters: [], total: 0 }; throw error; }
    const needle = query.trim().toLocaleLowerCase();
    const characters: CatalogSummary[] = [];
    for (const id of ids.filter(id => /^[a-z0-9-]{1,64}$/.test(id))) {
      const entry = (await this.revisions(id))[0];
      if (!entry || creatorId !== undefined && creatorId !== entry.creatorId || excludeOwn && entry.creatorId === viewer.subject) continue;
      const item = summary(entry);
      const haystack = [item.name, item.description, item.creatorName, item.packCreator, ...item.traits].join('\n').toLocaleLowerCase();
      if (!needle || haystack.includes(needle)) characters.push(item);
    }
    characters.sort((a, b) => a.name.localeCompare(b.name) || a.id.localeCompare(b.id));
    return { characters: characters.slice(offset, offset + limit), total: characters.length };
  }

  async download(actor: CatalogPrincipal, reference: CatalogRef): Promise<CatalogDownload> {
    principal(actor); ref(reference);
    const entries = await this.revisions(reference.id);
    const entry = reference.version === undefined ? entries[0] : entries.find(value => value.character.version === reference.version);
    if (!entry || reference.creatorId !== undefined && entry.creatorId !== reference.creatorId) {
      throw new CatalogError('Character revision was not found.', 404, 'not_found');
    }
    return { character: entry.character, summary: summary(entry) };
  }

  async recordImport(actor: CatalogPrincipal, input: CatalogImportInput): Promise<CatalogImportReceipt> {
    const importer = principal(actor);
    if (!input || !input.creatorId || !Number.isSafeInteger(input.version) || input.version < 1
      || typeof input.digest !== 'string' || !/^[a-f0-9]{64}$/.test(input.digest)) throw new CatalogError('An exact downloaded revision and digest are required.');
    const download = await this.download(importer, input);
    if (download.summary.digest !== input.digest) throw new CatalogError('The imported bytes do not match the published revision.', 409, 'digest_conflict');
    return this.transaction(async () => {
      const receiptId = createHash('sha256').update(canonical([importer.subject, input.creatorId, input.id, input.version, input.digest])).digest('hex');
      const directory = join(this.directory, 'imports', createHash('sha256').update(importer.subject).digest('hex'));
      const path = join(directory, `${receiptId}.json`);
      try { return JSON.parse(await readFile(path, 'utf8')) as CatalogImportReceipt; }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
      const receipt: CatalogImportReceipt = { receiptId, importerId: importer.subject,
        creatorId: download.summary.creatorId, id: input.id, version: input.version, digest: input.digest,
        importedAt: new Date().toISOString(), confirmation: 'client-reported' };
      await mkdir(directory, { recursive: true, mode: 0o700 });
      await this.createImmutable(path, receipt);
      return receipt;
    });
  }

  async imports(actor: CatalogPrincipal): Promise<CatalogImportReceipt[]> {
    const importer = principal(actor);
    const directory = join(this.directory, 'imports', createHash('sha256').update(importer.subject).digest('hex'));
    let names: string[];
    try { names = await readdir(directory); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []; throw error; }
    return Promise.all(names.filter(name => /^[a-f0-9]{64}\.json$/.test(name)).map(async name => {
      const receipt = JSON.parse(await readFile(join(directory, name), 'utf8')) as CatalogImportReceipt;
      if (receipt.importerId !== importer.subject) throw new CatalogError('Stored receipt ownership is invalid.', 500, 'storage_invalid');
      return receipt;
    }));
  }
}
