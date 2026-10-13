# Doboo (두부)

하나의 캐릭터를 Pets·Dots·서브에이전트에서 함께 사용하고,
갤러리에서 다른 제작자의 캐릭터를 찾아 주고받으며,
Apple Watch의 터치와 햅틱 경험으로 이어주는 프로젝트입니다.

## 현재 구현

- **호스트 내부 플러그인:** MCP 도구와 내부 갤러리, 실제 호스트 적용을 수행하는 스킬.
- **공유 카탈로그:** 인증된 제작자의 게시, 다른 제작자 검색, 버전별 받기와 수신 기록.
- **하나의 정의:** `.doboo.json`에 ID·버전·외형·설정·말투·성격을 보존.
- **iPhone → Watch:** 기존 앱에서 파일 가져오기와 WatchConnectivity 전송. Watch가 검증·저장한 뒤 보낸 수신 확인을 별도로 표시.
- **기존 Watch 경험:** 기본 두부의 연속 눌림·표정·햅틱·접근성·동작 줄이기를 유지. Pets PNG는 스프라이트 렌더러로 재생.

기억·작업 상태·권한이 자동으로 공유되지는 않습니다. 파일 설치와 호스트에서의 실제 실행도 구분합니다.
공개 갤러리 운영과 실제 다른 사람 간 교환은 아직 검증되지 않았습니다.

[플러그인 설치와 실행](plugins/doboo/README.md) · [실제 검증 결과](docs/QUALITY_REVIEW.md)

## 개발

- 네이티브 앱: Swift 6, iOS 18+, watchOS 11+, Xcode 26+, XcodeGen
- 내부 플러그인: Node.js 22+, TypeScript, MCP SDK/MCP Apps
- 캐릭터 변환 도구: Node.js 22+; 정적 검증: Python 3

```sh
xcodegen generate
swift test
npm test
npm --prefix plugins/doboo ci
npm --prefix plugins/doboo run check
npm --prefix plugins/doboo test
python3 scripts/check_repository.py
node scripts/check_interchange.mjs

# 사용 권한이 있는 PNG로 이미지 왕복을 확인합니다.
node scripts/check_interchange.mjs /path/to/pet.png
```

`DobooLibrary` scheme은 iPhone 앱과 포함 Watch 앱을, `Doboo` scheme은 Watch 앱을 빌드합니다.
각 실기기가 포함된 개발 프로파일과 설치된 플랫폼이 필요합니다.

## 설계와 근거

- [통합 방향·기존 커밋 검토](docs/INTEGRATION.md)
- [캐릭터 파일 규격](docs/CHARACTER_FORMAT.md)
- [Pets·Dots·서브에이전트 연결 범위](docs/CHATGPT_COMPATIBILITY.md)
- [Doboo 이름 검토](docs/NAME_REVIEW.md)
- [개인정보 안내](docs/PRIVACY.md)

Doboo와 `squeeez!`는 별도 제품·저장소입니다. 코드·에셋·Git 이력을 공유하지 않습니다.
검증에 사용한 외부 Pets 이미지는 저장소에 포함하지 않습니다.
`Screenshots/doboo-watch.png`는 초기 프로토타입 기록이며 현재 실행 증거가 아닙니다.
