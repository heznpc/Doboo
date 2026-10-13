# 통합 검증 기록

2026-10-13 · `feat/character-gallery-integration`

## 구현 범위

기존 `2e9501a`의 Watch 촉감·접근성·수명 관리에 캐릭터 파일과 렌더러 선택을
연결했습니다. iPhone 앱 안에서 생성·편집·공유·가져오기를 제공하고,
같은 캐릭터를 Watch 파일 전송 및 Pets/Dots/서브에이전트 출력에 사용합니다.
별도 웹 갤러리는 제품에 포함하지 않습니다.

## 실행 확인

| 확인 | 결과와 범위 |
| --- | --- |
| Swift 핵심 테스트 | 24개 통과. 입력·취소·도형, 스키마·버전 충돌, 저장 실패시 기존 데이터 유지, 재시작 선택 보존, sprite 방향, 실제 host exporter 포함 |
| JS 개발 도구 | 5개 통과. 포맷 왕복, 잘못된 입력 거부, PNG checksum/압축 데이터, legacy 변환, TOML escaping |
| 파일 교환 | 네이티브 두 독립 저장소 → 재시작 → CLI 왕복. 기본 캐릭터 및 실제 Pets PNG 포함 파일에서 모든 필드·이미지 바이트 일치 |
| Dots/서브에이전트 파일 | Swift와 JS가 생성한 지침의 ID·말투 확인, Python tomllib로 양쪽 TOML 파싱. name/description/developer_instructions만 생성 |
| 기존 Troupe 파일 | 실제 steady-character, pico, pragmatic-builder 및 mori 변환. 원 ID·원문·semver는 변환 기록에 보존하고 새 정수 버전·제작자를 명시 |
| 앱 실제 실행 | 공용 iPad 시뮬레이터에서 생성 → v2 편집 → 공유 시트, 파일 선택기를 통한 Pets 포함 JSON 가져오기 → 선택 → 재시작 보존 확인. 앱이 만든 JSON/PNG의 원본 일치와 Dots/TOML 내용도 확인 |
| iOS 코드 빌드 | 동일 production 소스·설정으로 빌드 성공. 아래 검증 구성 차이 있음 |
| Watch 코드 빌드 | watchOS device SDK로 compile/link 성공. 아이콘 제외 조건이며 전체 배포 빌드 아님 |
| 정적 정합성 | 21개 Swift 파일, 한국어/영어 97개 키, 리소스·프로젝트 참조·diff 검사 통과 |

## 시뮬레이터 환경과 한계

이 Mac에는 iOS 26.5 시뮬레이터가 있지만 watchOS 런타임이 없습니다.
Watch SDK가 설치돼 있어도 Xcode의 포함 Watch 앱 preflight 및 asset compiler가
해당 런타임을 요구해 production 통합 scheme의 전체 빌드는 진행할 수 없었습니다.

iOS 실행 검증에는 `work/ios-verification`의 임시 XcodeGen 프로젝트를 썼습니다.
production iOS 소스·리소스·bundle ID·설정은 같고, 포함 Watch target 의존성만 제외했습니다.
제품 프로젝트에 별도의 Preview 앱이나 검증 전용 target을 추가하지 않았습니다.
Watch 코드 컴파일은 `EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets`와
빈 `ASSETCATALOG_COMPILER_APPICON_NAME` 조건을 사용했습니다.
이 결과를 통합 패키징·아이콘 검증·실기기 실행 성공으로 간주하지 않습니다.

실제 화면을 확인하면서 iOS 지역화 리소스가 번들에서 빠져 raw key가 보이는 문제를
발견했고, 리소스 그룹 구성을 수정했습니다. iPhone 아이콘은 기존 자체 PNG를 재사용했습니다. 가져온 스프라이트가 왼쪽에 치우치는 문제도 실제 화면에서 확인해 중앙 정렬을 고쳤습니다.
Watch bundle ID는 iOS companion의 접두어를 따르도록 `app.doboo.watchkitapp`,
iOS는 `app.doboo`로 맞췄습니다. 기존 Watch 프로토타입 설치의 설정 마이그레이션은 미검증입니다.

## 남은 검증

- 페어링된 iPhone↔Watch 파일 수신, 실제 렌더링·햅틱·Always On·배터리·큰 글자.
- Watch 런타임이 설치된 환경에서 production 통합 scheme, 서명·archive·배포.
- 내보낸 Pets PNG의 실제 ChatGPT 등록, Dots 지침 저장, Codex 서브에이전트 등록·호출.
- OS 공유 시트에서 실제 다른 사람에게 보내고 그 사람의 기기에서 가져오는 과정.

파일 생성·복사·공유 UI와 실제 외부 호스트 설치/상대 기기 수신은 별개의 검증입니다.
