import { spawnSync } from 'node:child_process';
import { readFileSync, lstatSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

const hash = value => createHash('sha256').update(value).digest('hex');
export const workEvidenceTool = { type: 'function', name: 'doboo_work_evidence',
  description: 'Read host-observed command item IDs and file-change receipts for this code task. Call after validation and use the exact returned itemId in the final validation entries. Read-only; no actions are executed.',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false } };
export function workEvidenceResponse(task, params) {
  if (!task.work || task.cancelRequested || task.status !== 'running' || params.threadId !== task.threadId || params.turnId !== task.turnId
    || params.tool !== workEvidenceTool.name || params.namespace != null || !params.arguments || Array.isArray(params.arguments)
    || typeof params.arguments !== 'object' || Object.keys(params.arguments).length) throw new Error('작업 증거 조회의 실행 문맥이 일치하지 않습니다.');
  const commands = task.commands.filter(command => command.threadId === task.threadId && command.turnId === task.turnId
    && command.status === 'completed' && command.exitCode === 0).map(({ output, ...command }) => command);
  return { contentItems: [{ type: 'inputText', text: JSON.stringify({ commands, fileChanges: task.fileChanges ?? [] }) }], success: true };
}
// Host observations, separate from the coordinator's claims. Limits are explicit
// so an incomplete snapshot is never presented as complete repository coverage.
export function repositorySnapshot(project) {
  const git = args => spawnSync('git', ['-C', project, ...args], { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  const head = git(['rev-parse', 'HEAD']);
  const listing = git(['ls-files', '-z', '--cached', '--others', '--exclude-standard']);
  if (listing.status !== 0) return { available: false, files: {}, truncated: true };
  const files = {}, unobservedPaths = []; let bytes = 0, truncated = false;
  const paths = [...new Set(listing.stdout.split('\0').filter(Boolean))].sort();
  for (const [index, path] of paths.entries()) {
    if (index >= 5000) {
      truncated = true;
      for (const remaining of paths.slice(index)) unobservedPaths.push(remaining);
      break;
    }
    try {
      const full = join(project, path), stat = lstatSync(full);
      if (!stat.isFile() || stat.size > 2 * 1024 * 1024 || bytes + stat.size > 128 * 1024 * 1024) {
        truncated = true; unobservedPaths.push(path); continue;
      }
      files[path] = hash(readFileSync(full)); bytes += stat.size;
    } catch (error) {
      if (error.code === 'ENOENT') files[path] = null;
      else { truncated = true; unobservedPaths.push(path); }
    }
  }
  return { available: true, head: head.status === 0 ? head.stdout.trim() : null, files, unobservedPaths, truncated };
}

export function repositoryEvidence(before, after) {
  const available = before.available && after.available;
  const unobserved = new Set([...(before.unobservedPaths ?? []), ...(after.unobservedPaths ?? [])]);
  return { available, headBefore: before.head ?? null, headAfter: after.head ?? null,
    truncated: before.truncated || after.truncated,
    changes: available ? [...new Set([...Object.keys(before.files), ...Object.keys(after.files)])].sort()
      .filter(path => !unobserved.has(path) && (before.files[path] ?? null) !== (after.files[path] ?? null))
      .map(path => ({ path, beforeSHA256: before.files[path] ?? null, afterSHA256: after.files[path] ?? null })) : [] };
}

export function workMemory(task) {
  const record = task.workRecord;
  if (!record || task.status !== 'completed') return null;
  let detailTextShortened = false;
  const excerpt = value => {
    if (value?.length > 1000) detailTextShortened = true;
    return value?.slice(0, 1000);
  };
  const memory = { taskId: task.id, project: record.project, recordedAt: record.recordedAt,
    summary: record.summary, decisions: record.decisions.map(decision => {
      const proposal = record.contributions.find(c => c.characterId === decision.characterId)?.proposals.find(p => p.id === decision.proposalId);
      return { ...decision, rationale: excerpt(decision.rationale), proposal: excerpt(proposal?.summary), paths: proposal?.paths };
    }),
    // Historical checks are facts about that run, never proof of today's code.
    verification: record.evidence.commands.map(({ itemId, command, exitCode, status, purpose }) => ({ itemId, command: excerpt(command), exitCode, status, purpose })),
    changedFiles: record.evidence.repository?.changes ?? [], remainingRisks: record.remainingRisks,
    contextDigest: record.contextDigest, cast: task.continuity.workCast };
  const stamp = () => { memory.omitted = {
    decisions: record.decisions.length - memory.decisions.length,
    verification: record.evidence.commands.length - memory.verification.length,
    changedFiles: (record.evidence.repository?.changes.length ?? 0) - memory.changedFiles.length,
    remainingRisks: record.remainingRisks.length - memory.remainingRisks.length,
    detailTextMayBeShortened: true,
  }; };
  if (detailTextShortened) { memory.truncated = true; stamp(); }
  if (JSON.stringify(memory).length <= 24000) return memory;
  // Keep the immediate predecessor usable even when its full evidence is large.
  // The durable workRecord remains intact; only this historical projection shrinks.
  memory.summary = memory.summary.slice(0, 1000);
  memory.decisions = memory.decisions.map(decision => ({ ...decision,
    rationale: decision.rationale.slice(0, 500), proposal: decision.proposal?.slice(0, 500),
    paths: decision.paths?.slice(0, 1) }))
    .sort((a, b) => Number(b.disposition === 'adopted') - Number(a.disposition === 'adopted'));
  memory.verification = memory.verification.slice(0, 8).map(check => ({ ...check,
    command: check.command.slice(0, 500), purpose: check.purpose?.slice(0, 500) }));
  memory.changedFiles = memory.changedFiles.slice(0, 20);
  memory.remainingRisks = memory.remainingRisks.slice(0, 6).map(risk => risk.slice(0, 500));
  memory.truncated = true;
  stamp();
  while (JSON.stringify(memory).length > 24000) {
    if (memory.changedFiles.length) memory.changedFiles.pop();
    else if (memory.verification.length > 1) memory.verification.pop();
    else if (memory.remainingRisks.length) memory.remainingRisks.pop();
    else if (memory.decisions.length > 1) memory.decisions.pop();
    else throw new Error('작업 기억의 필수 정보가 허용 크기를 초과했습니다.');
    stamp();
  }
  return memory;
}
