# Doboo 개인정보 안내

작성: Heznpc · 2026-10-03 · 현재 저장소의 코드 기준

Doboo는 Apple Watch 안에서 동작합니다. 현재 앱에는 서버 통신, 로그인,
광고, 분석 SDK, 추적, 건강 데이터 접근, ChatGPT 계정 연결 기능이 없습니다.
Doboo가 사용자의 데이터를 서버로 전송하는 코드는 없습니다.

햅틱·모션 설정과 첫 안내 확인 여부는 앱의 UserDefaults에 저장됩니다.
터치 위치와 눌림 상태는 캐릭터 반응에만 사용되며 파일로 기록하지 않습니다.
앱의 설정에서 선호 설정을 변경할 수 있습니다. OS가 제공하는 앱 삭제와 백업 동작은
해당 기기의 설정을 따릅니다.

`Resources/PrivacyInfo.xcprivacy`에는 추적 없음, 수집 데이터 없음,
앱 자체 설정 저장을 위한 UserDefaults 접근 사유 `CA92.1`을 선언했습니다.
매니페스트는 앱의 실제 동작 및 향후 추가되는 SDK와 함께 관리해야 합니다.

이 문서는 스토어에 게시된 개인정보 처리방침 URL을 대신하지 않습니다.
배포 시 Heznpc의 지원·개인정보 안내 페이지와 App Store Connect의 개인정보 응답을
실제 출시 구성에 맞춰 준비해야 합니다. 이번 작업에서는 외부 페이지를 새로 발행하지 않았습니다.

개발 근거: [Apple의 required reason API 매니페스트 안내](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)
