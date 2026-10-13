import { z } from 'zod';
import { MAX_JSON_BYTES, validateCharacter } from '../../../character-kit/model.mjs';
import { characterDigest } from './catalog.js';
import type { CatalogDownload, CatalogImportInput, CatalogImportReceipt, CatalogSearch, CatalogSummary, CharacterPack } from './catalog-types.js';

// A page may contain 100 maximum-length Unicode summaries. It never contains PNGs.
export const MAX_CATALOG_SEARCH_BYTES = 2 * 1024 * 1024;
const MAX_METADATA_BYTES = 32 * 1024;
const MAX_ERROR_BYTES = 8 * 1024;
const invalidText = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]|[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u;
const text = (max: number, required = false, singleLine = false) => z.string().refine(value =>
  [...value].length <= max && !invalidText.test(value) && (!required || !!value.trim()) &&
  (!singleLine || !/[\r\n\t\u0085\u2028\u2029]/.test(value)));
const id = z.string().regex(/^[a-z0-9-]{1,64}$/);
const version = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const principalId = z.string().min(1).max(200).refine(value => !!value.trim() && !/[\x00-\x1f\x7f]/.test(value));
const digest = z.string().regex(/^[a-f0-9]{64}$/);
const timestamp = z.string().max(30).refine(value => Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value);
const referenceSchema = z.strictObject({ id, version, creatorId: principalId });
const summarySchema = z.strictObject({
  id, version, name: text(80, true, true), description: text(500),
  creatorId: principalId, creatorName: text(80, true).refine(value => !/[\x00-\x1f\x7f]/.test(value)),
  packCreator: text(80, true, true), traits: z.array(text(160, true)).max(20),
  appearance: z.strictObject({ renderer: z.enum(['native-doboo', 'spritesheet']),
    tint: z.string().regex(/^#[0-9a-fA-F]{6}$/), layout: z.enum(['pets-v1', 'pets-v2']).optional(),
  }).refine(value => value.renderer === 'spritesheet' ? value.layout !== undefined : value.layout === undefined),
  digest, publishedAt: timestamp,
});
const searchSchema = z.strictObject({ characters: z.array(summarySchema).max(100), total: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER) })
  .refine(value => value.total >= value.characters.length && new Set(value.characters.map(c => c.id)).size === value.characters.length);
const searchInputSchema = z.strictObject({ query: z.string().max(200).optional(), creatorId: principalId.optional(),
  excludeOwn: z.boolean().optional(), limit: z.number().int().min(1).max(100).optional(),
  offset: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional() });
const publishSchema = z.strictObject({ summary: summarySchema, created: z.boolean() });
const downloadSchema = z.strictObject({ summary: summarySchema, character: z.unknown() });
const importInputSchema = referenceSchema.extend({ digest });
const receiptSchema = importInputSchema.extend({ receiptId: digest, importerId: principalId,
  importedAt: timestamp, confirmation: z.literal('client-reported') });

function parseResponse<T extends z.ZodType>(schema: T, value: unknown): z.output<T> {
  const parsed = schema.safeParse(value);
  if (!parsed.success) throw new Error('Invalid catalog metadata response.');
  return parsed.data;
}
function checkSummary(summary: CatalogSummary, pack: CharacterPack): void {
  const appearance = { renderer: pack.appearance.renderer, tint: pack.appearance.tint,
    ...(pack.appearance.sprite ? { layout: pack.appearance.sprite.layout } : {}) };
  if (summary.id !== pack.id || summary.version !== pack.version || summary.digest !== characterDigest(pack) ||
    summary.name !== pack.name || summary.description !== pack.description || summary.packCreator !== pack.creator ||
    JSON.stringify(summary.traits) !== JSON.stringify(pack.personality.traits) ||
    JSON.stringify(summary.appearance) !== JSON.stringify(appearance)) {
    throw new Error('Catalog returned a different character revision.');
  }
}

export class CatalogClient {
  private base: URL;
  constructor(url: string, private token: string) {
    this.base = new URL(url);
    if (this.base.username || this.base.password || this.base.search || this.base.hash ||
      (this.base.protocol !== 'https:' && !(this.base.protocol === 'http:' && ['127.0.0.1','localhost'].includes(this.base.hostname)))) {
      throw new Error('Catalog requires HTTPS, or loopback HTTP for a local verification.');
    }
    if (!token || /\s/.test(token)) throw new Error('A catalog credential is required.');
  }
  private async request(path: string, limit: number, data?: unknown): Promise<unknown> {
    const response = await fetch(new URL(path, this.base), {
      method: data === undefined ? 'GET' : 'POST', redirect: 'error', signal: AbortSignal.timeout(30_000),
      headers: { Authorization: `Bearer ${this.token}`, ...(data === undefined ? {} : {'Content-Type':'application/json'}) },
      body: data === undefined ? undefined : JSON.stringify(data),
    });
    const maximum = response.ok ? limit : MAX_ERROR_BYTES;
    const chunks: Uint8Array[] = []; let bytes = 0;
    if (!response.body) throw new Error('Empty catalog response.');
    if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type') ?? '')) {
      await response.body.cancel();
      throw new Error('Catalog response must be JSON.');
    }
    const length = response.headers.get('content-length');
    if (length !== null && Number(length) > maximum) {
      await response.body.cancel();
      throw new Error('Catalog response exceeds the size limit.');
    }
    for await (const chunk of response.body) {
      bytes += chunk.length;
      if (bytes > maximum) throw new Error('Catalog response exceeds the size limit.');
      chunks.push(chunk);
    }
    let result: unknown;
    try { result = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { throw new Error('Catalog response must be valid JSON.'); }
    // Error bodies are not trusted instructions and do not become tool output fields.
    if (!response.ok) throw new Error(`Catalog request failed (HTTP ${response.status}).`);
    return result;
  }
  async search(options: CatalogSearch = {}): Promise<{ characters: CatalogSummary[]; total: number }> {
    const query = searchInputSchema.parse(options);
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(query)) if (value !== undefined) params.set(key, String(value));
    const result = parseResponse(searchSchema, await this.request(`/v1/characters?${params}`, MAX_CATALOG_SEARCH_BYTES));
    if (result.characters.length > (query.limit ?? 50)) throw new Error('Catalog returned more characters than requested.');
    return { characters: result.characters, total: result.total };
  }
  async publish(character: unknown): Promise<{ summary: CatalogSummary; created: boolean }> {
    const pack = validateCharacter(character) as CharacterPack;
    const result = parseResponse(publishSchema, await this.request('/v1/characters', MAX_METADATA_BYTES, { character: pack }));
    checkSummary(result.summary, pack);
    return { summary: result.summary, created: result.created };
  }
  async download(ref: { id: string; version: number; creatorId: string }): Promise<CatalogDownload> {
    const reference = referenceSchema.parse(ref);
    const params = new URLSearchParams({ version: String(reference.version), creatorId: reference.creatorId });
    const result = parseResponse(downloadSchema, await this.request(`/v1/characters/${reference.id}/download?${params}`, MAX_JSON_BYTES + MAX_METADATA_BYTES));
    const pack = validateCharacter(result.character) as CharacterPack;
    if (pack.id !== reference.id || pack.version !== reference.version || result.summary.creatorId !== reference.creatorId) {
      throw new Error('Catalog returned a different character revision.');
    }
    checkSummary(result.summary, pack);
    return { summary: result.summary, character: pack };
  }
  async recordImport(receipt: CatalogImportInput): Promise<CatalogImportReceipt> {
    const input = importInputSchema.parse(receipt);
    const result = parseResponse(receiptSchema, await this.request('/v1/imports', MAX_METADATA_BYTES, input));
    if (result.id !== input.id || result.version !== input.version || result.creatorId !== input.creatorId || result.digest !== input.digest) {
      throw new Error('Catalog returned a receipt for a different character revision.');
    }
    return result;
  }
}
