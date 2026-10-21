import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveCodexBinary } from './runtime.mjs';

const desktop = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex';
const options = { env: {}, platform: 'darwin', home: '/Users/example', executable: path => path === desktop };
test('explicit and environment runtimes override desktop discovery', () => {
  assert.equal(resolveCodexBinary({ ...options, explicit: '/explicit/codex', env: { DOBOO_CODEX_BINARY: '/env/codex' } }), '/explicit/codex');
  assert.equal(resolveCodexBinary({ ...options, env: { DOBOO_CODEX_BINARY: '/env/codex' } }), '/env/codex');
});
test('macOS prefers an executable bundled desktop runtime, then falls back to PATH', () => {
  assert.equal(resolveCodexBinary(options), desktop);
  const codexApp = '/Applications/Codex.app/Contents/Resources/codex';
  assert.equal(resolveCodexBinary({ ...options, executable: path => path === codexApp }), codexApp);
  const userApp = desktop.replace('/Applications', '/Users/example/Applications');
  assert.equal(resolveCodexBinary({ ...options, executable: path => path === userApp }), userApp);
  assert.equal(resolveCodexBinary({ ...options, executable: () => false }), 'codex');
  assert.equal(resolveCodexBinary({ ...options, platform: 'linux' }), 'codex');
});
