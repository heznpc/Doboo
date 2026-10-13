#!/usr/bin/env node
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { parseCharacter, importCharacter, serializeCharacter } from '../character-kit/model.mjs';
import { renderDots, renderCodex } from '../character-kit/exporters.mjs';

const [command, input, destination, version, creator] = process.argv.slice(2);
try {
  if (!input || !['validate','export','import'].includes(command)) throw new Error('사용법: npm run character -- validate <file> | export <file> <new-directory> | import <legacy-file> <new-directory> <integer-version> <creator>');
  const text = await readFile(resolve(input), 'utf8');
  if (command === 'validate') {
    const c = parseCharacter(text);
    console.log(`${c.id}@${c.version}: valid Doboo character`);
  } else {
    if (!destination) throw new Error('새 출력 디렉터리를 지정해 주세요. 기존 디렉터리는 덮어쓰지 않습니다.');
    const result = command === 'import' ? importCharacter(JSON.parse(text), { version: Number(version), creator }) : { character: parseCharacter(text), migration: null };
    const c = result.character;
    const output = resolve(destination);
    await mkdir(output, { recursive: false });
    await writeFile(join(output, `${c.id}.doboo.json`), serializeCharacter(c), { flag: 'wx' });
    await writeFile(join(output, `${c.id}-dots.md`), renderDots(c), { flag: 'wx' });
    await writeFile(join(output, `${c.id}.toml`), renderCodex(c), { flag: 'wx' });
    if (c.appearance.sprite) await writeFile(join(output, `${c.id}-${c.appearance.sprite.layout}.png`), Buffer.from(c.appearance.sprite.base64, 'base64'), { flag: 'wx' });
    if (result.migration) await writeFile(join(output, `${c.id}-migration.json`), `${JSON.stringify(result.migration, null, 2)}\n`, { flag: 'wx' });
    console.log(`Exported ${c.id}@${c.version} to ${output}`);
  }
} catch (error) { console.error(error.message); process.exitCode = 1; }
