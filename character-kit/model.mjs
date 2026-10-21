import { validateSpritePNG } from './png.mjs';

export const FORMAT = 'doboo.character.v1';
export const MAX_JSON_BYTES = 32 * 1024 * 1024;
const invalidText = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]|[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u;
function object(value, keys, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || ![Object.prototype, null].includes(Object.getPrototypeOf(value))) throw new TypeError(`${label}: 객체가 필요합니다.`);
  for (const key of Object.keys(value)) if (!keys.includes(key)) throw new TypeError(`${label}.${key}: 알 수 없는 필드입니다. 삭제 없이 가져오려면 형식을 확인해 주세요.`);
}
function text(value, max, label, required = false, singleLine = false) {
  if (typeof value !== 'string' || [...value].length > max || invalidText.test(value) || (required && !value.trim()) || (singleLine && /[\r\n\t\u0085\u2028\u2029]/.test(value))) throw new TypeError(`${label}: ${required ? '1' : '0'}–${max}자의 ${singleLine ? '한 줄 ' : ''}텍스트가 필요합니다.`);
}
function list(value, count, size, label) {
  if (!Array.isArray(value) || value.length > count) throw new TypeError(`${label}: 최대 ${count}개까지 입력할 수 있습니다.`);
  value.forEach((entry, i) => text(entry, size, `${label}[${i}]`, true));
}

export function validateCharacterization(detail) {
  object(detail, ['appearanceDescription','perspective','principles','workStyle','examples','origin'], 'characterization');
  text(detail.appearanceDescription, 4000, '외형 설명');
  text(detail.perspective, 4000, '관점');
  list(detail.principles, 16, 4000, '원칙');
  object(detail.workStyle, ['initiative','updates','recovery'], 'characterization.workStyle');
  for (const key of ['initiative','updates','recovery']) text(detail.workStyle[key], 4000, `characterization.workStyle.${key}`);
  if (!Array.isArray(detail.examples) || detail.examples.length > 8) throw new TypeError('대화 예시는 최대 8개입니다.');
  for (const example of detail.examples) {
    object(example, ['situation','response'], 'characterization.example');
    text(example.situation, 4000, '예시 상황', true);
    text(example.response, 4000, '예시 반응', true);
  }
  if (detail.origin !== undefined) {
    const origin = detail.origin;
    object(origin, ['schema','id','version','personalityId','personalityVersion','personalityName'], 'characterization.origin');
    if (!['innercast.character.v1','troupe.character.v1','troupe.personality.v1'].includes(origin.schema)) throw new TypeError('가져온 설정의 출처 형식이 잘못되었습니다.');
    if (typeof origin.id !== 'string' || !/^[a-z0-9-]{1,64}$/.test(origin.id)) throw new TypeError('출처 ID가 잘못되었습니다.');
    if (typeof origin.version !== 'string' || origin.version.length > 80 || !/^\d+\.\d+\.\d+$/.test(origin.version)) throw new TypeError('출처 버전이 잘못되었습니다.');
    if (origin.personalityId !== undefined && (typeof origin.personalityId !== 'string' || !/^[a-z0-9-]{1,64}$/.test(origin.personalityId))) throw new TypeError('성격 출처 ID가 잘못되었습니다.');
    if (origin.personalityVersion !== undefined && (typeof origin.personalityVersion !== 'string' || origin.personalityVersion.length > 80 || !/^\d+\.\d+\.\d+$/.test(origin.personalityVersion))) throw new TypeError('성격 출처 버전이 잘못되었습니다.');
    if (origin.personalityName !== undefined) text(origin.personalityName, 80, '성격 출처 이름', true, true);
  }
  return structuredClone(detail);
}

export function validateCharacter(raw) {
  object(raw, ['format','id','version','name','description','creator','identity','personality','appearance','characterization'], '캐릭터');
  if (raw.format !== FORMAT) throw new TypeError(`형식은 ${FORMAT}여야 합니다.`);
  if (typeof raw.id !== 'string' || !/^[a-z0-9-]{1,64}$/.test(raw.id)) throw new TypeError('ID는 소문자, 숫자, 하이픈 1–64자여야 합니다.');
  if (!Number.isSafeInteger(raw.version) || raw.version < 1) throw new TypeError('버전은 1 이상의 안전한 정수여야 합니다.');
  text(raw.name, 80, '이름', true, true);
  text(raw.description, 500, '소개');
  text(raw.creator, 80, '제작자', true, true);
  object(raw.identity, ['backstory','voice'], 'identity');
  text(raw.identity.backstory, 4000, '배경 이야기');
  text(raw.identity.voice, 4000, '말투');
  object(raw.personality, ['traits','instructions'], 'personality');
  list(raw.personality.traits, 20, 160, '성격');
  list(raw.personality.instructions, 30, 500, '행동 지침');
  if (raw.characterization !== undefined) validateCharacterization(raw.characterization);
  object(raw.appearance, ['renderer','tint','sprite','watch'], 'appearance');
  if (!['native-doboo','spritesheet'].includes(raw.appearance.renderer)) throw new TypeError('외형 렌더러가 잘못되었습니다.');
  if (typeof raw.appearance.tint !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(raw.appearance.tint)) throw new TypeError('색상은 #RRGGBB 형식이어야 합니다.');
  if (raw.appearance.sprite !== undefined) {
    object(raw.appearance.sprite, ['layout','mimeType','base64'], 'sprite');
    if (raw.appearance.sprite.mimeType !== 'image/png') throw new TypeError('스프라이트는 PNG만 지원합니다.');
    validateSpritePNG(raw.appearance.sprite.base64, raw.appearance.sprite.layout);
  }
  if (raw.appearance.renderer === 'spritesheet' && !raw.appearance.sprite) throw new TypeError('스프라이트 외형에 PNG 이미지가 필요합니다.');
  if (raw.appearance.renderer === 'native-doboo' && raw.appearance.sprite) throw new TypeError('기본 외형에는 스프라이트를 함께 지정할 수 없습니다.');
  if (raw.appearance.watch !== undefined) {
    object(raw.appearance.watch, ['renderer','tint','sprite'], 'appearance.watch');
    validateCharacter({ ...raw, appearance: raw.appearance.watch });
  }
  if (Buffer.byteLength(JSON.stringify(raw)) > MAX_JSON_BYTES) throw new TypeError('캐릭터 파일은 32 MiB 이하여야 합니다.');
  return structuredClone(raw);
}

export function parseCharacter(source) {
  if (typeof source !== 'string' || Buffer.byteLength(source) > MAX_JSON_BYTES) throw new TypeError('캐릭터 파일은 32 MiB 이하여야 합니다.');
  let raw;
  try { raw = JSON.parse(source); } catch { throw new TypeError('올바른 JSON 파일이 아닙니다.'); }
  return validateCharacter(raw);
}

export function serializeCharacter(raw) { return `${JSON.stringify(validateCharacter(raw), null, 2)}\n`; }

// Legacy conversion is deliberate: semver cannot be represented by a Doboo integer.
// Keep the original source and version in the returned report; never silently truncate.
export function importCharacter(raw, { version, creator } = {}) {
  if (raw?.format === FORMAT) return { character: validateCharacter(raw), migration: null };
  const schemas = ['innercast.character.v1','troupe.character.v1','troupe.personality.v1'];
  if (!schemas.includes(raw?.schema)) throw new TypeError('Doboo 또는 지원되는 Troupe 캐릭터 파일이 필요합니다.');
  if (!Number.isSafeInteger(version) || version < 1) throw new TypeError('기존 Troupe 버전은 semver입니다. 변환할 Doboo 정수 버전을 명시해 주세요.');
  text(creator, 80, '변환 캐릭터 제작자', true, true);
  if (typeof raw.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(raw.version)) throw new TypeError('기존 Troupe 버전 형식이 잘못되었습니다.');
  const isCast = raw.schema === 'troupe.character.v1';
  object(raw, isCast ? ['schema','id','version','identity','personality'] : raw.schema === 'innercast.character.v1' ? ['schema','id','version','name','perspective','voice','principles','workStyle'] : ['schema','id','version','name','perspective','principles','workStyle','examples'], 'Troupe');
  if (isCast) {
    object(raw.identity, ['name','appearance','backstory','voice'], 'Troupe.identity');
    for (const key of ['name','appearance','backstory','voice']) text(raw.identity[key], 4000, `Troupe.identity.${key}`, true);
  } else if (raw.schema === 'innercast.character.v1') text(raw.voice, 4000, 'Troupe.voice', true);
  const p = isCast ? raw.personality : raw;
  if (isCast && p !== undefined && p !== null) object(p, ['schema','id','version','name','perspective','principles','workStyle','examples'], 'Troupe.personality');
  if (p) {
    text(p.name, 80, 'Troupe.personality.name', true);
    text(p.perspective, 4000, 'Troupe.perspective', true);
    if (isCast && (p.schema !== 'troupe.personality.v1' || typeof p.id !== 'string' || !/^[a-z][a-z0-9-]{0,63}$/.test(p.id) || typeof p.version !== 'string' || !/^\d+\.\d+\.\d+$/.test(p.version))) throw new TypeError('Troupe 성격 ID·버전이 잘못되었습니다.');
    object(p.workStyle, ['initiative','updates','recovery'], 'Troupe.workStyle');
    for (const key of ['initiative','updates','recovery']) text(p.workStyle[key], 4000, `Troupe.workStyle.${key}`, true);
    if (!Array.isArray(p.principles) || p.principles.length < 1 || p.principles.length > 16) throw new TypeError('Troupe principles가 잘못되었습니다.');
    p.principles.forEach((item, index) => text(item, 4000, `Troupe.principles[${index}]`, true));
    if (p.examples !== undefined && !Array.isArray(p.examples)) throw new TypeError('Troupe examples가 잘못되었습니다.');
    if ((p.examples?.length ?? 0) > 8) throw new TypeError('Troupe examples는 최대 8개입니다.');
    for (const example of p.examples ?? []) { object(example, ['situation','response'], 'Troupe.example'); text(example.situation,4000,'Troupe.example.situation',true); text(example.response,4000,'Troupe.example.response',true); }
  }
  const character = validateCharacter({
    format: FORMAT, id: raw.id, version,
    name: isCast ? raw.identity.name : raw.name, description: '', creator,
    identity: { backstory: isCast ? raw.identity.backstory : '', voice: isCast ? raw.identity.voice : raw.voice ?? '' },
    personality: { traits: [], instructions: [] },
    characterization: {
      appearanceDescription: isCast ? raw.identity.appearance : '', perspective: p?.perspective ?? '',
      principles: p?.principles ?? [], workStyle: p?.workStyle ?? { initiative: '', updates: '', recovery: '' },
      examples: p?.examples ?? [],
      origin: { schema: raw.schema, id: raw.id, version: raw.version,
        ...(isCast && p ? { personalityId: p.id, personalityVersion: p.version, personalityName: p.name } : {}) },
    },
    appearance: { renderer: 'native-doboo', tint: '#FF8F62' },
  });
  return { character, migration: {
    sourceSchema: raw.schema, sourceId: raw.id, sourceVersion: raw.version,
    targetId: character.id, targetVersion: version, original: structuredClone(raw),
    changes: ['정수 버전은 사용자가 지정했습니다.', '외형 설명·관점·원칙·작업 방식·예시는 구조화된 캐릭터 설정에 보존했습니다. 중복 행동 지침을 만들지 않았습니다.', '외형 이미지가 없는 원본은 Doboo 기본 외형으로 표시합니다.', '원본과 원본 버전은 이 변환 기록에 보존됩니다. 캐릭터의 출처 표시는 이후 편집 내용의 일치를 보증하지 않습니다.'],
  } };
}
