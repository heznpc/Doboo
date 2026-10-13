# Doboo internal plugin

하나의 캐릭터를 찾고 받아 Pets·Dot·Codex 서브에이전트·Watch에 적용하는 개발 플러그인입니다. 갤러리 화면은 MCP App으로 호스트 내부에서 표시됩니다. `use-character` 스킬은 파일 준비 이후 실제 호스트 도구를 사용하고 결과를 확인합니다.

현재 제공하는 것은 로컬 설치 가능한 플러그인과 인증된 공유 카탈로그 구현입니다. 공개 카탈로그 운영, 실제 다른 사람의 계정 간 교환, ChatGPT 웹의 사용자 설치 경로는 검증되지 않았습니다. 테스트 fixture 교환과 실제 사용자 간 교환은 별도로 검증합니다.

## 설치와 실행

Node.js 22 이상과 로컬 플러그인 설치를 지원하는 Codex가 필요합니다. 저장소 루트에서:

```sh
npm --prefix plugins/doboo ci
npm --prefix plugins/doboo run check
npm --prefix plugins/doboo test
codex plugin marketplace add .
codex plugin add doboo@doboo-local
```

`dist/`는 설치 후 별도 의존성 다운로드 없이 실행하도록 포함한 번들입니다. 소스를 바꾸면 다시 빌드하고 `plugin add`로 로컬 설치본을 갱신합니다. portable `plugin.json`/`mcp.json`과 현재 Codex 호환 `.codex-plugin/plugin.json`/`.mcp.json`을 함께 제공합니다. 현재 호스트는 플러그인 루트를 작업 디렉터리로 사용하므로 MCP 인수는 `./dist/server.mjs`입니다. 이 호스트에서 `${CLAUDE_PLUGIN_ROOT}` 인수 치환은 되지 않았습니다.

`status`로 연결을 확인하고, `import_character_file`에 사용자가 선택한 `.doboo.json`의 절대경로를 넘깁니다. `install_agent`와 `host_status`에는 **현재 작업의 프로젝트 절대경로**를 `projectDirectory`로 넘깁니다. 플러그인 캐시의 작업 디렉터리는 설치 대상이 아닙니다.

## 공유 카탈로그

- 인증된 주체가 게시 소유자를 결정하며 캐릭터 파일의 제작자 표기와 구분됩니다.
- ID의 게시 소유권과 각 버전의 내용은 고정됩니다. 다른 주체의 ID나 같은 버전을 덮어쓸 수 없습니다.
- 검색은 이미지 없는 메타데이터를 반환합니다. 받기는 선택한 제작자·ID·버전·SHA-256을 확인한 뒤 개인 보관함에 저장합니다.
- 수신 기록은 클라이언트가 보고한 저장 사실입니다. 기록 실패 시 저장본을 유지하고 `imported-receipt-pending`을 반환합니다.

검증용 서비스는 loopback에만 바인딩합니다. 서비스 실행을 위해 0600 권한의 JSON 설정 파일을 준비합니다. `credentials`의 키는 32자 이상의 무작위 토큰이고 값은 `{ "subject": "...", "displayName": "..." }`입니다. 설정에는 상대 또는 절대 `directory`, 선택적 `port`, `credentials`를 넣습니다. 자격증명을 저장소에 커밋하지 마세요.

```sh
DOBOO_CATALOG_CONFIG=/absolute/private/catalog.json node plugins/doboo/dist/catalog-main.mjs
```

MCP 프로세스에 `DOBOO_CATALOG_URL`과 `DOBOO_CATALOG_TOKEN`을 전달하면 공유 기능이 활성화됩니다. Codex 호환 `.mcp.json`의 `env_vars`가 부모 환경에서 해당 값들을 전달합니다. 표준 `mcp.json`에는 이 Codex 전용 필드를 넣지 않습니다. 클라이언트는 HTTPS 또는 로컬 검증용 loopback HTTP만 허용합니다. 현재 서버를 여러 사람에게 제공하려면 별도로 합의한 HTTPS 운영 환경과 계정 발급 경로가 필요합니다. 이 저장소는 운영 대상이나 공개 배포를 확정하지 않습니다.

개인 보관함 위치는 `DOBOO_DATA_DIR`, 호스트가 제공한 `PLUGIN_DATA`, 로컬 기본 경로 순입니다. 명시적인 `DOBOO_WORKSPACE`는 프로젝트 경로 기본값으로 사용할 수 있습니다.

## 실제 호스트 적용

`prepare_host_application`은 이미지, Dot 지침, Watch 파일을 준비하고 `install_agent`는 프로젝트 파일을 설치합니다. 모두 `hostConfirmed: false` 또는 `hostApplied: false`를 반환합니다. 실제 Pets 선택, Dot 응답/설정, 이름으로 호출한 서브에이전트, Watch 수신·선택은 각각 호스트에서 확인해야 합니다.

UI의 ‘함께 쓰기’는 현재 채팅에 명시적 적용 요청을 보내고 스킬이 이 과정을 진행하게 합니다. 이 버튼 자체는 외부 호스트 활성화 증거가 아닙니다.
