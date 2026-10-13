# 통합 검증 기록

2026-10-13 · `feat/character-gallery-integration`

## 판단 기준

요구사항은 하나의 캐릭터를 Pets·Dots·서브에이전트에서 사용하고 다른 제작자의 캐릭터를 갤러리에서 찾아 주고받으며 기존 Watch 경험으로 연결하는 것입니다. 내부 플러그인, 네이티브 보관함, 공유 카탈로그는 이를 검증하기 위한 구현입니다. 파일 출력이나 화면만으로 이 요구사항이 완성됐다고 판단하지 않습니다.

## 실제 호스트와 기기 관찰

| 대상 | 관찰 결과 | 남은 범위 |
| --- | --- | --- |
| Codex 플러그인 | 로컬 marketplace 설치 후 실제 app-server에서 `doboo@doboo-local` 연결 상태 connected, 도구 11개 인식. status·import_character_file·install_agent·host_status 실제 호출, MCP App HTML resource 읽기 성공 | 실제 내부 갤러리 화면 렌더링·버튼 동작, ChatGPT 웹 설치 |
| Codex 서브에이전트 | Dewey 동일 revision을 명시한 검증 프로젝트 `.codex/agents/dewey.toml`에 설치하고 상태 재조회 | 별도 모델 실행은 QuotaPie `subscription_pool_source_history_unverified`로 거절. 실제 named-agent 호출·응답 미검증 |
| Pets | 계정의 Dewey stable ID `dewey` 원본 시트를 받아 pack 구성. select 후 active ID readback 확인 | 새 custom Pet 등록 경로, 캐릭터 성격이 Pet 행동까지 바뀐다는 주장 |
| Dot | 기존 Dot에 Dewey 이름·말투·성격 적용 요청, 실제 확인 응답과 예시 반응 관찰. 페이지를 다시 열어 Dewey 이름 유지 확인 | 모든 성격 필드의 내부 저장, 장기간 작업 중 지속성, 다른 계정 Dot |
| iPhone | production 통합 scheme 서명 빌드를 실제 기기에 설치·실행. Dewey pack import 후 컨테이너에서 원 ID/버전/설정/PNG 일치 확인 | App Store/TestFlight 배포 |
| Watch | watchOS 26.5 런타임 설치 후 포함 앱·아이콘을 제외하지 않은 production build 성공. 실제 iPhone WCSession activated/paired 확인 | 실제 Watch 설치·수신·표시 미검증. iPhone의 appconduitd가 페어링된 Watch unreachable을 기록하며 설치 요청을 무시 |
| 공유 갤러리 | 두 독립 fixture 주체의 HTTP/MCP 교환 검증에 더해, 설치된 Codex 플러그인을 실제 app-server 두 개에서 호출해 게시→open_gallery 다른 제작자 검색→adopt→수신 기록→원본 파일 일치 확인 | 실제 다른 사람의 계정/기기 간 교환, 운영 주소·계정 발급·공개 배포 |

Dewey는 OpenAI 기본 Pet 외형과 연결 검증용 성격을 조합한 로컬 검증 파일입니다. 사용자가 만든 캐릭터나 독립 제작자의 게시물이라고 주장하지 않습니다. 원본 이미지와 기기 식별자·로컬 증거 로그는 저장소에 배포하지 않습니다.

## 검증 중 발견하고 수정한 결함

- 실제 plugin host는 `${CLAUDE_PLUGIN_ROOT}`를 MCP 인수에서 치환하지 않았습니다. 설치 루트 기준 `./dist/server.mjs`로 바꾸고 실제 호스트 재연결을 확인했습니다.
- 표준 mcp.json에 Codex 전용 env_vars를 넣으면 실제 호스트에서 서버가 누락됐습니다. 환경 전달은 호환 .mcp.json에만 선언하고 실제 catalog 연결과 교환을 확인했습니다.
- plugin cwd를 현재 프로젝트로 추정하면 에이전트가 설치 캐시에 생성됐습니다. 현재 작업의 절대 projectDirectory 또는 명시적 절대 DOBOO_WORKSPACE만 사용하도록 바꿨습니다.
- HTML 번들 삽입에 문자열 replacement를 사용해 번들 내부 `$&`가 marker로 바뀌었습니다. callback replacement로 고치고 실제 resource 내용을 검증했습니다.
- 원격 메타데이터의 알 수 없는 필드, 이미지 payload, hostApplied 위조, owner/version/digest 불일치, 과도한 본문을 거부하도록 했습니다.
- 카탈로그 수신 기록 실패가 로컬 저장 실패처럼 보이지 않도록 부분 성공 상태와 같은 revision 재시도를 구현했습니다.
- Watch arm64_32의 32비트 Int로는 포맷의 JS-safe revision 범위를 담을 수 없었습니다. version을 Int64로 바꾸고 범위 왕복을 검증했습니다.
- 실제 Watch가 개발 프로파일에 없는 결함을 발견했습니다. 기존 팀·인증서에 Watch를 등록하고 포함 프로파일로 다시 서명한 빌드를 iPhone에 설치했습니다. 그래도 설치가 진행되지 않아 iPhone Mirroring으로 설치 버튼을 직접 재현하면서 Console 실시간 로그를 수집했습니다. appconduitd는 “Ignoring request to install app app.doboo.watchkitapp because the device with pairing ID … isn't reachable”라고 기록했습니다. 현재 거절 지점은 iPhone→Watch 연결이며 프로파일 수정만으로 해소되지 않았습니다. 추가 재클릭을 성공 증거로 취급하지 않습니다.

## 자동 검증

- Swift 핵심 25개: 스키마, 영속 저장, 원자적 변경, ID/버전 충돌, exporter, 정수 범위, 기본 상호작용.
- JS 캐릭터 도구 5개: 정의 왕복, 입력 거부, PNG 검증, legacy 변환, 지침 escaping.
- 플러그인 20개: 소유권·불변 버전, 실제 HTTP 교환, 제한된 원격 응답, 로컬 설치/출력, 파일 충돌, 실제 manifest로 시작한 MCP 프로세스, 프로젝트 경로, 부분 성공 재시도, UI resource.
- TypeScript 검사와 저장소 정합성 21 Swift 파일·97 지역화 키·리소스/프로젝트 참조 통과.
- production `DobooLibrary` signed build 성공. Watch 바이너리 arm64_32/arm64와 실제 sprite atlas 1536×1872의 idle 프레임 192×208×6 디코딩 확인.

테스트 및 프로토콜 통과와 실제 UI·호스트·수신자의 실행은 위 표에서 별도로 관리합니다.

## 로컬 증거 재현

플러그인 테스트: `npm --prefix plugins/doboo test`. 실제 호스트는 로컬 plugin install 후 app-server의 `mcpServerStatus/list`, `mcpServer/tool/call`, `mcpServer/resource/read`로 확인했습니다. 모델을 통한 에이전트 호출은 별도의 검증입니다.

기기 진단 빌드는 DEBUG에서 `--character-transfer-diagnostics`를 명시했을 때만 CharacterTransferDiagnostics.json을 기록합니다. 추가 `--send-character <id>`는 실제 앱의 기존 send 함수를 호출합니다. 정상 실행·Release에서는 진단 파일을 쓰지 않으며 캐릭터 내용은 진단에 포함하지 않습니다. queue·송신 callback·수신 확인을 합치지 않습니다.

이전 `f8a12f9` 검증은 iOS 임시 프로젝트와 Watch 아이콘 제외 컴파일을 포함했습니다. 이번에는 공식 런타임을 설치하고 production 통합 패키지를 빌드했으므로 이전의 빌드 제한은 해소됐습니다. 당시 iPad에서의 생성/편집/파일 가져오기/공유 시트/재시작 검증은 기존 기록으로 유지하며 Watch 실기기 증거로 쓰지 않습니다.
