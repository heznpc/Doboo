# Pets·Dots·서브에이전트 연결 범위

확인일: 2026-10-13. 아래 표는 파일 구현과 실제 호스트 적용을 구분합니다.

| 대상 | 현재 구현 | 아직 확인하지 않은 연결 |
| --- | --- | --- |
| Pets | v1/v2 PNG가 포함된 캐릭터 가져오기·재생·원본 PNG 내보내기 | 내보낸 이미지를 실제 ChatGPT 계정에 등록·선택하는 전체 과정 |
| Dots | 동일 캐릭터의 설정·말투·성격을 담은 지침 복사·공유 | 실제 dot 설정 저장과 지속 작업 중 적용 |
| Codex 서브에이전트 | 동일 ID·성격을 담은 TOML 파일 생성 | 실제 호스트 등록·호출 및 행동 검증 |
| Watch | 기본 도형 및 스프라이트 렌더러, 터치·햅틱, 파일 전송과 저장 후 수신 확인 | Watch 실기기 표시·햅틱·무선 수신 |

이들은 하나의 `.doboo.json`을 각각의 환경에 맞게 표현합니다.
정의가 같다는 것이 기억, 작업 진행, 접근 권한까지 공유한다는 뜻은 아닙니다.
생성한 지침이나 TOML을 파일로 받았다는 이유만으로 호스트에 설치됐다고 표시하지 않습니다.

## Pets 이미지

공개 문서는 PNG/WebP **1536 × 1872**, 최대 **20 MiB**를 안내합니다.
설치된 work-pets 0.1.6 계약에는 v2 **1536 × 2288**도 있습니다.
Doboo의 현재 휴대 포맷은 PNG만 받으며 둘의 크기를 명시적으로 구분합니다.
WebP는 PNG로 변환한 뒤 가져올 수 있습니다.
[OpenAI Pets 문서](https://learn.chatgpt.com/docs/pets)

셀은 192 × 208, 8열입니다. 공통 9행은 idle, running-right, running-left,
waving, jumping, failed, waiting, running, review이고 프레임 수는
6·8·8·4·5·8·6·6·6입니다. v2에는 시선 방향 16개가 추가됩니다.
Watch에서는 idle과 터치 반응을 사용하며 v2는 터치 방향을 시선에 매핑합니다.
ChatGPT의 실시간 작업 이벤트가 Watch에 전달되는 구현은 아닙니다.

기본 두부는 SwiftUI 도형이므로 유효한 Pets 시트를 갖고 있지 않습니다.
이 캐릭터에는 PNG 내보내기가 표시되지 않습니다.
외형이 없는 상태를 임의 이미지로 채우지 않습니다.

## Dots와 서브에이전트

Dots에는 캐릭터 지침을 복사해 사용자가 적용하고 지속 책임을 별도로 지정합니다.
파일만으로 반복 작업을 만들거나 접근 권한을 부여하지 않습니다.
[OpenAI Dots 문서](https://learn.chatgpt.com/docs/dots)

Codex 출력은 `name`, `description`, `developer_instructions`가 있는 TOML입니다.
호스트의 `.codex/agents/`에 등록하는 형식이며, 갤러리의 내보내기만으로 등록하지 않습니다.
캐릭터 작성자 입력은 호스트 규칙이나 현재 사용자 지시를 덮어쓸 수 없습니다.
[공식 서브에이전트 설정 문서](https://learn.chatgpt.com/docs/agent-configuration/subagents)

Mini는 데스크톱의 간소화된 채팅 컨트롤입니다. 공개 문서에서 dots나 Mini의 UI를
watchOS에 그대로 임베딩하는 SDK는 확인하지 못했습니다.
이 앱은 각 환경에 맞는 외형·캐릭터 설정을 내보내는 경로를 제공합니다.
