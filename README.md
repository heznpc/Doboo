# Doboo (두부)

Pets·Dots·서브에이전트에서 함께하는 캐릭터를 만들고 주고받아,
Apple Watch의 터치와 햅틱 경험으로 이어주는 앱입니다.
기본 캐릭터 두부 외에도 각자의 외형·설정·말투·성격을 가진 캐릭터를 담습니다.

## 이번 통합

- **앱 안의 캐릭터 갤러리:** 만들기, 새 버전으로 편집, 파일 가져오기와 공유.
- **하나의 캐릭터 파일:** `.doboo.json`에 ID·버전·외형·설정·말투·성격을 보존합니다.
- **iPhone → Watch:** 갤러리에서 캐릭터를 선택하고 WatchConnectivity로 보냅니다.
  전송 대기와 Watch의 검증·저장 후 수신 확인은 구분합니다.
- **Watch 경험 유지:** 기본 두부의 연속 눌림·표정·햅틱·접근성·동작 줄이기를 유지합니다.
  Pets PNG는 별도 스프라이트 렌더러로 재생합니다.
- **같은 캐릭터의 다른 표현:** Dots 지침, Codex 서브에이전트 TOML,
  실제 포함된 Pets PNG를 내보냅니다. 기억·작업 상태·권한이 자동 동기화되지는 않습니다.

갤러리는 Doboo 앱 안에 있습니다. 파일은 OS 공유 시트로 상대에게 보내고,
받은 사람은 자신의 앱으로 가져옵니다. 공개 게시판·계정·웹 서비스 운영은 이 구현에 포함하지 않습니다.
기본 도형 캐릭터에 Pets 스프라이트가 있는 것처럼 표시하지 않습니다.

구성 요소별 확인 방법은 [검증 절차](docs/QUALITY_REVIEW.md)를 따릅니다.
Watch 기기 간 전송과 실제 ChatGPT 설정 적용은 개별 검증 대상입니다.

## 개발

- iOS 18+, watchOS 11+, Swift 6, Xcode 26+, XcodeGen
- Node.js 22+: 캐릭터 파일 변환·내보내기용 개발 CLI (앱 실행에는 불필요)
- Python 3: 프로젝트/리소스 일관성 및 TOML 검증

```sh
xcodegen generate
swift test
npm test
python3 scripts/check_repository.py
node scripts/check_interchange.mjs

# 스프라이트 왕복까지 확인할 경우, 사용 권한이 있는 PNG를 지정합니다.
node scripts/check_interchange.mjs /path/to/pet.png

# 캐릭터 개발 도구
npm run character -- validate Characters/doboo.doboo.json
npm run character -- export Characters/doboo.doboo.json work/doboo-export
```

Xcode에서 `DobooLibrary` scheme은 iPhone 앱과 포함된 Watch 앱을,
`Doboo` scheme은 Watch 앱을 빌드합니다. 필요한 iOS/watchOS 플랫폼을 설치해야 합니다.
서명·archive·스토어 제출은 별도 검증이 필요합니다.

## 설계와 근거

- [통합 구조](docs/INTEGRATION.md)
- [캐릭터 파일 규격](docs/CHARACTER_FORMAT.md)
- [Pets·Dots·서브에이전트 연결 범위](docs/CHATGPT_COMPATIBILITY.md)
- [Doboo 이름 검토](docs/NAME_REVIEW.md)
- [개인정보 안내](docs/PRIVACY.md)

Doboo와 `squeeez!`는 별도 제품·저장소입니다. 코드·에셋·Git 이력을 공유하지 않습니다.
저장소에 배포하는 기본 캐릭터와 아이콘은 자체 도형입니다.
외부 Pets 이미지는 저장소에 포함하지 않습니다.
`Screenshots/doboo-watch.png`는 초기 프로토타입 기록이며 현재 버전의 실행 증거가 아닙니다.

## Local signing configuration

The public project leaves `DEVELOPMENT_TEAM` empty. Simulator builds and core
tests do not require a personal development team. Signed device builds require
your own Apple development team and matching provisioning profiles.

For a direct Xcode build, select your team in Signing & Capabilities or pass
`DEVELOPMENT_TEAM=<YOUR_TEAM_ID>` to `xcodebuild`. For a generated project, set
`settings.base.DEVELOPMENT_TEAM` in your local `project.yml`, then run
`xcodegen generate`. Keep the personal signing values out of commits.

If this revision includes `scripts/build_device.py`, configure the local project
before running it: that tool reads Release settings directly from the Xcode
project, so a shell environment variable or command-line override alone does not
configure it. 
