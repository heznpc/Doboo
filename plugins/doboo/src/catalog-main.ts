import { stat, readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { PersistentCatalog, type CatalogPrincipal } from './catalog.js';
import { startCatalogServer } from './catalog-service.js';

interface CatalogConfiguration {
  directory: string; port: number; credentials: Record<string, CatalogPrincipal>;
}
export async function loadCatalogConfiguration(path: string): Promise<CatalogConfiguration> {
  const source = resolve(path);
  const metadata = await stat(source);
  if (!metadata.isFile() || metadata.size > 64 * 1024 || (metadata.mode & 0o777) !== 0o600) {
    throw new Error('Catalog configuration must be a regular file of at most 64 KiB with permissions 0600.');
  }
  let raw: unknown;
  try { raw = JSON.parse(await readFile(source, 'utf8')); }
  catch { throw new Error('Catalog configuration is not valid JSON.'); }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('Invalid catalog configuration.');
  const config = raw as Record<string, unknown>;
  if (Object.keys(config).some(key => !['directory','port','credentials'].includes(key))
    || typeof config.directory !== 'string' || !config.directory.trim()
    || config.port !== undefined && (!Number.isInteger(config.port) || Number(config.port) < 0 || Number(config.port) > 65535)
    || !config.credentials || typeof config.credentials !== 'object' || Array.isArray(config.credentials)) {
    throw new Error('Invalid catalog configuration fields.');
  }
  const entries = Object.entries(config.credentials);
  if (!entries.length || entries.length > 100) throw new Error('Configure between 1 and 100 catalog credentials.');
  const credentials: Record<string, CatalogPrincipal> = Object.create(null);
  for (const [token, identity] of entries) {
    if (!/^[A-Za-z0-9_-]{32,200}$/.test(token) || !identity || typeof identity !== 'object' || Array.isArray(identity)) {
      throw new Error('Invalid catalog credential or identity.');
    }
    const actor = identity as Record<string, unknown>;
    if (Object.keys(actor).some(key => !['subject','displayName'].includes(key))
      || typeof actor.subject !== 'string' || !actor.subject.trim() || actor.subject.length > 200 || /[\x00-\x1f\x7f]/.test(actor.subject)
      || typeof actor.displayName !== 'string' || !actor.displayName.trim() || [...actor.displayName].length > 80 || /[\x00-\x1f\x7f]/.test(actor.displayName)) {
      throw new Error('Invalid catalog credential identity.');
    }
    credentials[token] = { subject: actor.subject, displayName: actor.displayName };
  }
  return { directory: resolve(dirname(source), config.directory), port: Number(config.port ?? 0), credentials };
}

export async function startConfiguredCatalog(path: string) {
  const config = await loadCatalogConfiguration(path);
  return startCatalogServer({ catalog: new PersistentCatalog({ directory: config.directory }), port: config.port,
    authenticate: token => config.credentials[token] ?? null });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const path = process.env.DOBOO_CATALOG_CONFIG;
    if (!path) throw new Error('Set DOBOO_CATALOG_CONFIG to a private 0600 configuration file.');
    const { server, url } = await startConfiguredCatalog(path);
    process.stdout.write(`${url}\n`);
    const stop = () => server.close(() => process.exit(0));
    process.once('SIGINT', stop);
    process.once('SIGTERM', stop);
  } catch (error) {
    // Configuration values and credential tokens are never printed.
    process.stderr.write(`${(error as Error).message}\n`);
    process.exitCode = 1;
  }
}
