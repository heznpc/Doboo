# Doboo

Doboo는 Apple Watch에서 누르고 끌며 교감하는 오프라인 캐릭터입니다.
SwiftUI 도형으로 몸·눈·입을 그려 손가락 위치에 따라 눌리고 표정이 바뀝니다.
계정, 서버, 건강 데이터, 장기 육성 시스템은 사용하지 않습니다.

## 현재 구현

- 터치·드래그 반응과 선택 가능한 햅틱
- 첫 사용 안내, 설정, 다시 볼 수 있는 도움말과 개인정보 안내
- 기기에 저장되는 햅틱·모션 설정
- VoiceOver 놀이 동작과 한국어·영어 안내
- 비활성 화면·Always On·시스템 동작 줄이기 설정에서 지속 애니메이션 중지
- 앱 아이콘, 개인정보 매니페스트, 소스·리소스 일관성 CI

정적 검사가 통과해도 배터리, 실제 햅틱, 화면 배치, 접근성 동작 및 배포 성공을 보증하지 않습니다.
[검증 절차](docs/QUALITY_REVIEW.md)을 확인해 주세요.

## 개발 환경

- Xcode 26 이상, watchOS 11 이상
- XcodeGen (`project.yml`이 프로젝트 설정의 원본)
- 코어 모델 테스트용 Swift 6, macOS 15 이상
- Python 3: 앱을 실행하지 않는 저장소 일관성 검사

```sh
# 소스·리소스·설정 변경 후 프로젝트 참조를 갱신합니다. 앱을 빌드하지 않습니다.
xcodegen generate

# 코드와 파일 구조만 검사합니다. 앱·테스트를 실행하지 않습니다.
python3 scripts/check_repository.py
```

앱과 코어를 검증하는 명령:

```sh
swift test
xcodebuild -project Doboo.xcodeproj -scheme Doboo \
  -sdk watchsimulator -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

실기기 서명과 App Store 배포는 별도 검증이 필요합니다. 프로젝트에는 서버 비밀키가 없습니다.
설정은 해당 앱의 UserDefaults에만 저장하고 터치 좌표는 메모리에서만 처리합니다.
[개인정보 안내](docs/PRIVACY.md)와 실제 데이터 흐름을 배포 시점에 다시 대조해야 합니다.

## ChatGPT 호환성

Pets 외형 교환은 스프라이트 변환·재생 기능을 별도로 구현하면 가능하지만 현재 연결되어 있지 않습니다.
Mini는 데스크톱 채팅 컨트롤이며, dots를 watchOS에 직접 넣는 공개 SDK는 확인되지 않았습니다.
[공식 문서에 근거한 호환성 검토](docs/CHATGPT_COMPATIBILITY.md)에 범위와 규격 차이를 정리했습니다.

## 제품 경계와 에셋

Doboo와 `squeeez!`는 별도 제품·저장소입니다. 각 제품의 코드와 에셋은 독립적으로 관리합니다. 캐릭터와 아이콘은 이 저장소의 도형으로 작성했습니다.

아이콘 원본은 `Artwork/AppIcon.svg`입니다. librsvg가 설치된 환경에서 갱신할 수 있습니다.

```sh
rsvg-convert -w 1024 -h 1024 -o Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png Artwork/AppIcon.svg
```

`Screenshots/doboo-watch.png`는 초기 프로토타입의 기록이며 현재 버전 검증 자료가 아닙니다.

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
