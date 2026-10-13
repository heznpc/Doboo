# Pets·Dots·서브에이전트 연결 범위

확인일: 2026-10-13. `.doboo.json`의 동일 ID·버전으로 외형과 성격을 각각의 호스트에 적용합니다. 정의 공유와 기억·작업 상태·접근 권한의 공유는 구분합니다.

## 내부 플러그인

`plugins/doboo`는 Node/TypeScript MCP 서버, MCP App 갤러리, `use-character` 스킬입니다. Codex 로컬 marketplace 설치와 실제 app-server의 MCP 연결·도구 인식·호출을 확인했습니다. ChatGPT 웹에서의 사용자 플러그인 설치 및 내부 갤러리 렌더링은 별도 미검증입니다. 로컬 Codex 설치가 모든 ChatGPT 표면 지원을 의미하지 않습니다.

`install_agent`와 `host_status`는 현재 작업의 절대 `projectDirectory`를 받습니다. 플러그인 프로세스의 cwd는 설치 캐시이므로 프로젝트로 추정하지 않습니다. 내보내기·설치 도구는 `hostApplied: false` 또는 `hostConfirmed: false`를 반환하고 실제 호스트 결과를 만들어내지 않습니다.

## Pets

공개 Pets 문서는 PNG/WebP 1536×1872, 최대 20MiB를 안내합니다. 설치된 work-pets 0.1.6 계약에는 v2 1536×2288도 있습니다. Doboo의 휴대 포맷은 PNG만 받으며 둘의 크기를 구분합니다. [OpenAI Pets 문서](https://learn.chatgpt.com/docs/pets)

192×208 셀 8열이며 공통 9행은 idle, running-right, running-left, waving, jumping, failed, waiting, running, review입니다. v2에는 시선 방향 16개가 추가됩니다. Watch는 idle·터치 반응을 사용하고 v2 터치 방향을 시선에 매핑합니다. ChatGPT 실시간 작업 이벤트를 Watch에 전송하는 구현은 아닙니다.

Dewey 검증에서는 실제 계정의 stable ID `dewey`로 원본 시트를 받아 PNG로 변환하고 같은 pack을 사용했습니다. Pets 선택 후 active ID를 재조회했습니다. 기존 Pet의 선택 검증이며 새 custom Pet 업로드 검증은 아닙니다. 기본 도형 두부에는 Pets 시트가 없습니다.

## Dot

같은 캐릭터의 이름·설정·말투·성격을 기존 Dot 대화에 적용합니다. 실제 Dewey 선호 설정 요청 후 Dot 응답을 확인했고 페이지를 새로 열어 이름이 유지되는 것을 확인했습니다. 모든 성격 설정의 내부 저장과 장기 동작은 이 관찰만으로 보장하지 않습니다. [OpenAI Dots 문서](https://learn.chatgpt.com/docs/dots)

현재 검증은 지원되는 대화 경로로 수행했습니다. 플러그인에 다른 Dot을 임의로 변경하는 API가 있다고 가정하지 않습니다. 지속 책임과 예약 작업은 별도의 사용자 요청이 필요합니다.

## Codex 서브에이전트

`name`, `description`, `developer_instructions` TOML을 실제 대상 프로젝트 `.codex/agents/`에 설치합니다. 같은 이름의 다른 내용을 덮어쓰지 않습니다. 실제 named agent를 호출해 확인하기 전에는 설치 상태만 보고합니다. [공식 서브에이전트 문서](https://learn.chatgpt.com/docs/agent-configuration/subagents)

현재 환경에서 별도 모델 실행은 QuotaPie 구독 보호의 `subscription_pool_source_history_unverified`로 거절됐습니다. 해당 보호를 변경하거나 다른 계정으로 우회하지 않았고, named agent 행동 검증은 남아 있습니다.

## Watch

iPhone 앱에서 exact pack을 가져와 기존 WatchConnectivity 경로로 전달합니다. 송신 queue·송신 callback·Watch 저장 후 수신 확인·실제 선택/표시는 각각 다른 상태입니다. 실제 검증 결과는 [검증 기록](QUALITY_REVIEW.md)을 따릅니다.

## 제작·갱신 파이프라인

공식 제작 스크립트를 실행하는 MCP 도구와 호스트 스킬, stable Pet ID 기반 생성/갱신 상태 관리, 저장 이미지 대조, 버전·정의 해시를 확인하는 Watch 수신증을 연결했습니다. Pets와 Watch의 픽셀 일치는 요구하지 않으며 `appearance.watch`로 별도 표현을 보존합니다. 실제 생성·등록·실물 전달의 미검증 항목은 [제작 파이프라인 검증 기록](CREATION_PIPELINE.md#observed-verification-2026-10-13)을 따릅니다.
