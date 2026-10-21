import { randomUUID } from 'node:crypto';
import { digestContext } from './native-cast.mjs';

const terminal = new Set(['completed', 'failed', 'interrupted']);
const text = (value, limit) => typeof value === 'string' && value.trim() && value.length <= limit && !/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value);
const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value);
const now = () => new Date().toISOString();
export const emptyStory = () => ({ revision: 0, relationships: [], events: [], episodes: [] });

export class StoryWorld {
  constructor(bridge, state = emptyStory()) { this.bridge = bridge; this.state = state; }
  snapshot() { return structuredClone({ serverId: this.bridge.serverId, ...this.state }); }
  check(input) {
    this.before = structuredClone(this.state);
    if (input?.serverId !== this.bridge.serverId) throw new Error('연결된 컴퓨터가 변경되었습니다. 다시 연결을 확인해 주세요.');
    if (!Number.isSafeInteger(input.expectedRevision) || input.expectedRevision !== this.state.revision) throw new Error('이야기가 변경되었습니다. 새로 확인한 뒤 다시 시도해 주세요.');
    if ([...this.bridge.jobs.values()].some(task => task.episodeId && !terminal.has(task.status))) throw new Error('진행 중인 장면을 마치거나 중단한 뒤 이야기를 바꿔 주세요.');
  }
  episode(id) { const value = this.state.episodes.find(item => item.id === id); if (!value) throw new Error('에피소드가 없습니다.'); return value; }
  lineage(id) { const ids = []; let episode = this.episode(id); while (episode) { ids.unshift(episode.id); episode = episode.predecessorEpisodeId ? this.episode(episode.predecessorEpisodeId) : null; } return ids; }
  currentRelationships(id) { const pairs = new Map(); for (const episodeId of this.lineage(id)) { for (const relation of this.state.relationships.filter(item => item.episodeId === episodeId)) pairs.set(`${relation.fromCharacterId}:${relation.toCharacterId}`, relation); } return [...pairs.values()].filter(item => !item.deleted); }
  save() { this.state.revision++; try { this.bridge.persist(); } catch (error) { this.state = this.before; throw error; } return this.snapshot(); }
  createEpisode(input) {
    this.check(input);
    const predecessor = input.predecessorEpisodeId === undefined ? null : this.episode(input.predecessorEpisodeId);
    const castIds = predecessor?.castIds ?? input.castIds;
    if (!text(input.title, 160) || !Array.isArray(castIds) || castIds.length < 2 || castIds.length > 6
      || new Set(castIds).size !== castIds.length || castIds.some(id => typeof id !== 'string' || !this.bridge.companion(id))) throw new Error('제목과 등록된 캐릭터 2~6명을 선택해 주세요.');
    if (predecessor && (this.state.episodes.some(item => item.predecessorEpisodeId === predecessor.id)
      || !this.state.events.some(event => event.episodeId === predecessor.id && !event.forgotten && !event.excludedFromContext))) throw new Error('완료된 가장 최근 에피소드에서 다음 회차를 만들어 주세요.');
    const date = now(); const id = randomUUID();
    this.state.episodes.push({ id, title: input.title.trim(), castIds: [...castIds], seriesId: predecessor?.seriesId ?? id,
      ...(predecessor ? { predecessorEpisodeId: predecessor.id } : {}),
      castProfiles: structuredClone(predecessor?.castProfiles ?? castIds.map(id => this.bridge.companion(id).profile)),
      taskIds: [], createdAt: date, updatedAt: date });
    return this.save();
  }
  relationship(input) {
    this.check(input); const episode = this.episode(input.episodeId);
    if (input.fromCharacterId === input.toCharacterId || ![input.fromCharacterId, input.toCharacterId].every(id => episode.castIds.includes(id)) || (input.summary !== '' && !text(input.summary, 2000))) throw new Error('서로 다른 등장인물과 관계 설명을 입력해 주세요.');
    if (input.sourceEventId !== undefined && !this.state.events.some(event => event.id === input.sourceEventId && this.lineage(episode.id).includes(event.episodeId) && !event.forgotten && !event.excludedFromContext)) throw new Error('관계 변화의 출처 사건을 확인해 주세요.');
    const old = this.state.relationships.find(item => item.episodeId === episode.id && item.fromCharacterId === input.fromCharacterId && item.toCharacterId === input.toCharacterId);
    const value = { id: old?.id ?? randomUUID(), episodeId: episode.id, fromCharacterId: input.fromCharacterId, toCharacterId: input.toCharacterId, summary: input.summary.trim(), deleted: input.summary === '', updatedAt: now(), ...(input.sourceEventId ? { sourceEventId: input.sourceEventId } : {}) };
    if (old) this.state.relationships.splice(this.state.relationships.indexOf(old), 1, value); else this.state.relationships.push(value);
    return this.save();
  }
  editEvent(id, input) {
    this.check(input); const event = this.state.events.find(item => item.id === id);
    if (!event || !text(input.summary, 4000) || typeof input.forgotten !== 'boolean') throw new Error('사건 기억 형식이 올바르지 않습니다.');
    if (event.summary !== input.summary.trim() || input.forgotten) {
      // Old transcripts and derived relationship claims cannot resurrect corrected memories.
      event.dialogue = []; event.relationshipChanges = [];
      const affected = new Set([event.id]);
      const index = this.state.events.indexOf(event);
      for (const later of this.state.events.slice(index + 1)) {
        if (this.episode(later.episodeId).seriesId === this.episode(event.episodeId).seriesId) { later.excludedFromContext = true; affected.add(later.id); }
      }
      this.state.relationships = this.state.relationships.filter(item => !affected.has(item.sourceEventId));
    }
    event.summary = input.summary.trim(); event.forgotten = input.forgotten; event.excludedFromContext = false; event.updatedAt = now();
    return this.save();
  }
  async turn(id, input) {
    if (input?.serverId !== this.bridge.serverId || !uuid(input.requestId) || !text(input.prompt, 8000)) throw new Error('장면 요청 형식이나 컴퓨터 연결을 확인해 주세요.');
    const old = this.bridge.jobs.get(input.requestId);
    // Retry identity survives newer revisions and process restarts, without re-execution.
    if (old) { if (old.episodeId !== id || old.prompt !== input.prompt) throw new Error('같은 요청 ID의 내용을 바꿀 수 없습니다.'); return old; }
    this.check(input); const episode = this.episode(id);
    if (this.state.episodes.some(item => item.predecessorEpisodeId === id)) throw new Error('이어진 가장 최근 에피소드에서 장면을 계속해 주세요.');
    if ([...this.bridge.jobs.values()].some(task => !terminal.has(task.status))) throw new Error('진행 중인 작업을 먼저 마치거나 중단해 주세요.');
    const lineage = this.lineage(id);
    const memories = this.state.events.filter(event => lineage.includes(event.episodeId) && !event.forgotten && !event.excludedFromContext).map(event => ({ id: event.id, summary: event.summary }));
    let count = 0; const recent = [];
    for (const event of memories.slice().reverse()) { if (count + event.summary.length > 16000) break; recent.unshift(event); count += event.summary.length; }
    const snapshot = { revision: this.state.revision, episode: { id, title: episode.title, seriesId: episode.seriesId },
      lineage: lineage.map(episodeId => { const item = this.episode(episodeId); return { id: item.id, title: item.title, predecessorEpisodeId: item.predecessorEpisodeId ?? null }; }),
      cast: episode.castProfiles.map(profile => ({ id: profile.id, name: profile.name, version: profile.version })),
      relationships: structuredClone(this.currentRelationships(id)), previousScenes: recent, historyTruncated: recent.length !== memories.length };
    const story = { episodeId: id, cast: structuredClone(episode.castProfiles), snapshot, contextDigest: digestContext(snapshot) };
    const profile = episode.castProfiles[0]; const date = now();
    const task = { id: input.requestId, episodeId: id, prompt: input.prompt, character: { id: profile.id, version: profile.version, name: profile.name },
      project: this.bridge.projectName, status: 'queued', sequence: 0, createdAt: date, updatedAt: date, result: '', activity: '캐릭터별 이야기 실행 준비 중', error: null,
      threadId: null, turnId: null, approvals: [], commands: [], receipts: {},
      _execution: { story } };
    this.bridge.jobs.set(task.id, task); episode.taskIds.push(task.id); episode.updatedAt = date;
    try { this.save(); } catch (error) { this.bridge.jobs.delete(task.id); throw error; }
    void this.bridge.execute(task); return task;
  }
  complete(task, value, execution) {
    if (task.cancelRequested || terminal.has(task.status)) throw new Error('중단되거나 종료된 장면은 저장할 수 없습니다.');
    const episode = this.episode(task.episodeId);
    if (!execution || execution.mode !== 'native_subagents' || execution.coordinatorThreadId !== task.threadId
      || execution.contextDigest !== task._execution.story.contextDigest || execution.agents.length !== episode.castIds.length
      || execution.agents.some(agent => agent.status !== 'completed' || !agent.threadId || !agent.turnId || !agent.finalMessageId)
      || !value?.dialogue?.length) throw new Error('실제 캐릭터 실행 증거가 없는 장면은 저장할 수 없습니다.');
    if (this.state.events.some(event => event.taskId === task.id)) return;
    const before = structuredClone(this.state); const previousTask = structuredClone(task);
    try {
      this.state.events.push({ id: task.id, kind: 'fictional_scene', episodeId: episode.id, taskId: task.id, summary: value.summary.trim(), forgotten: false, createdAt: now(),
        dialogue: structuredClone(value.dialogue), relationshipChanges: structuredClone(value.relationshipChanges), execution: structuredClone(execution) });
      task.result = value.dialogue.map(line => `${line.speakerId}: ${line.text}`).join('\n\n');
      task.castExecution = structuredClone(execution);
      episode.updatedAt = now(); this.state.revision++;
      // Event and terminal task are committed together; failed persistence restores both.
      this.bridge.change(task, { status: 'completed', approvals: [], activity: '캐릭터별 이야기 완료', error: null });
    } catch (error) {
      this.state = before;
      for (const key of Object.keys(task)) delete task[key];
      Object.assign(task, previousTask);
      throw error;
    }
  }
}
