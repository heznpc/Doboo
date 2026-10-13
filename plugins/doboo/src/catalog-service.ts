import { createServer, type IncomingMessage, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { MAX_JSON_BYTES } from '../../../character-kit/model.mjs';
import { CatalogError, PersistentCatalog, type CatalogPrincipal } from './catalog.js';

export interface CatalogServerOptions {
  catalog: PersistentCatalog;
  /** Authentication belongs to the service, never to a caller-supplied creator field. */
  authenticate: (bearerToken: string) => CatalogPrincipal | null | Promise<CatalogPrincipal | null>;
}
async function body(req: IncomingMessage): Promise<Record<string, unknown>> {
  if (!/^application\/json(?:\s*;|$)/i.test(req.headers['content-type'] ?? '')) throw new CatalogError('JSON content is required.', 415);
  const chunks: Buffer[] = [];
  let bytes = 0;
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > MAX_JSON_BYTES + 1024) throw new CatalogError('Request exceeds the character size limit.', 413);
    chunks.push(chunk);
  }
  let value: unknown;
  try { value = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new CatalogError('Invalid JSON request.'); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new CatalogError('A JSON object is required.');
  return value as Record<string, unknown>;
}
function allowedKeys(value: Record<string, unknown>, keys: string[]): void {
  if (Object.keys(value).some(key => !keys.includes(key))) throw new CatalogError('Unexpected request field.');
}

/** Internal authenticated service. startCatalogServer binds only to loopback;
 * there is deliberately no public deployment or account-provisioning endpoint.
 */
export function createCatalogServer({ catalog, authenticate }: CatalogServerOptions): Server {
  const server = createServer(async (req, res) => {
    const send = (status: number, value: unknown) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff' });
      res.end(JSON.stringify(value));
    };
    try {
      const allowedHosts = new Set([`127.0.0.1:${req.socket.localPort}`, `localhost:${req.socket.localPort}`]);
      if (!allowedHosts.has(req.headers.host ?? '')) throw new CatalogError('Use the local catalog address.', 403);
      if (req.headers.origin && req.headers.origin !== `http://${req.headers.host}`) throw new CatalogError('Cross-origin catalog requests are not allowed.', 403);
      const match = /^Bearer ([^\s]+)$/i.exec(req.headers.authorization ?? '');
      const actor = match ? await authenticate(match[1]) : null;
      if (!actor) throw new CatalogError('A valid catalog credential is required.', 401, 'unauthorized');
      const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
      if (req.method === 'GET' && url.pathname === '/v1/characters') {
        const exclude = url.searchParams.get('excludeOwn');
        if (exclude !== null && !['true','false'].includes(exclude)) throw new CatalogError('Invalid excludeOwn value.');
        return send(200, await catalog.search(actor, {
          query: url.searchParams.get('query') ?? '', creatorId: url.searchParams.get('creatorId') ?? undefined,
          excludeOwn: exclude === 'true', limit: url.searchParams.has('limit') ? Number(url.searchParams.get('limit')) : 50,
          offset: url.searchParams.has('offset') ? Number(url.searchParams.get('offset')) : 0,
        }));
      }
      if (req.method === 'POST' && url.pathname === '/v1/characters') {
        const value = await body(req);
        allowedKeys(value, ['character']);
        const published = await catalog.publish(actor, value.character);
        // Publishing returns metadata; it does not echo a potentially 20 MiB PNG.
        return send(published.created ? 201 : 200, { summary: published.summary, created: published.created });
      }
      const route = /^\/v1\/characters\/([a-z0-9-]{1,64})\/download$/.exec(url.pathname);
      if (req.method === 'GET' && route) {
        return send(200, await catalog.download(actor, { id: route[1],
          version: url.searchParams.has('version') ? Number(url.searchParams.get('version')) : undefined,
          creatorId: url.searchParams.get('creatorId') ?? undefined }));
      }
      if (req.method === 'POST' && url.pathname === '/v1/imports') {
        const value = await body(req);
        allowedKeys(value, ['id','version','creatorId','digest']);
        return send(200, await catalog.recordImport(actor, value as unknown as Parameters<PersistentCatalog['recordImport']>[1]));
      }
      if (req.method === 'GET' && url.pathname === '/v1/imports') return send(200, { receipts: await catalog.imports(actor) });
      throw new CatalogError('Catalog route not found.', 404, 'not_found');
    } catch (error) {
      const status = error instanceof CatalogError ? error.status : error instanceof TypeError || error instanceof SyntaxError ? 400 : 500;
      if (res.headersSent) return res.end();
      send(status, { error: status === 500 ? 'Catalog storage is unavailable; no revision was replaced.' : (error as Error).message,
        code: error instanceof CatalogError ? error.code : status === 500 ? 'storage_error' : 'invalid_request' });
    }
  });
  server.requestTimeout = 30_000;
  server.headersTimeout = 15_000;
  return server;
}

export async function startCatalogServer(options: CatalogServerOptions & { port?: number }): Promise<{ server: Server; url: string }> {
  const { port = 0, ...rest } = options;
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new CatalogError('Invalid local catalog port.');
  const server = createCatalogServer(rest);
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  return { server, url: `http://127.0.0.1:${(server.address() as AddressInfo).port}` };
}
