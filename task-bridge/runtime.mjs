import { accessSync, constants, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const isExecutable = path => {
  try { accessSync(path, constants.X_OK); return statSync(path).isFile(); } catch { return false; }
};

// Match the desktop account's runtime without altering its model, effort, or configuration.
export function resolveCodexBinary({ explicit, env = process.env, platform = process.platform,
  home = homedir(), executable = isExecutable } = {}) {
  if (explicit) return explicit;
  if (env.DOBOO_CODEX_BINARY) return env.DOBOO_CODEX_BINARY;
  if (platform === 'darwin') {
    for (const root of ['/Applications', join(home, 'Applications')]) {
      for (const suffix of [
        'ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
        'Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
        'Codex.app/Contents/Resources/codex',
      ]) {
        const path = join(root, suffix);
        if (executable(path)) return path;
      }
    }
  }
  return 'codex';
}
