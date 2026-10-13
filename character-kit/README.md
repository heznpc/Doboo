# Character kit

Node.js 22 이상, 외부 의존성 없음. 공통 파일 계약은 `docs/CHARACTER_FORMAT.md`를 따릅니다.

```js
import { validateCharacter, parseCharacter, importCharacter, serializeCharacter } from './model.mjs';
import { renderDots, renderCodex } from './exporters.mjs';
```

- `validateCharacter(object)` → 검증된 깊은 복사. 원본의 ID·버전·공백을 포함한 값은 변경하지 않습니다. 알 수 없는 필드는 조용히 버리지 않고 거부합니다.
- `parseCharacter(jsonText)` / `serializeCharacter(object)` → 같은 캐릭터 파일을 읽고 씁니다. JSON은 32 MiB, PNG 원본은 20 MiB까지입니다.
- `importCharacter(object, {version, creator})` → `{character, migration}`. Doboo 파일은 변경 없이 반환합니다. 기존 `innercast.character.v1`, `troupe.character.v1`, `troupe.personality.v1`은 정수 버전과 제작자를 명시해야 변환합니다. 기존 필드가 새 계약 한도를 넘으면 잘라내지 않고 거부합니다. `migration`에는 전체 원본과 원본 semver가 포함됩니다. CLI는 변환 기록도 출력 디렉터리에 함께 저장합니다.
- `renderDots(character)` → 해당 dot에 수동 적용할 Markdown. 실행·저장·상태 공유를 보장하지 않습니다.
- `renderCodex(character)` → `name`, `description`, `developer_instructions`만 가진 TOML. 호스트 권한·모델·sandbox 설정을 바꾸지 않습니다. 캐릭터 입력의 우선순위 한계가 지침에 포함됩니다.

PNG 검사는 시그니처, 크기, 청크 체크섬, 필수 청크, 압축 해제 길이와 scanline 필터를 확인합니다. 이미지의 미적 품질이나 각 프레임의 의미를 판정하지 않습니다.

Troupe의 실제 `innercast/lib/personality.mjs`, `character.mjs`, `character-export.mjs`를 검토하여 인격과 정체성 구분, 두 실행 역할, 명시적 교체, 호스트 권한 유지 원칙을 이식했습니다. 이전 프로젝트의 실행기·전역 설치기·제품 UI는 복제하지 않았습니다.
