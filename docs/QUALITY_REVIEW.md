# Verification guide

## Character identity and exchange

- Run the Swift core tests, JavaScript character tests and source consistency checks.
- Round-trip native export, file import and re-export with the same ID and revision.
- Compare all character settings and sprite bytes; test malformed input and revision conflicts.
- Parse generated Dot instructions and agent TOML; distinguish generated files from host execution.
- Check imported sprite alignment, localization, persistence across restart and sharing UI.

## Host and device boundaries

- Build the production application with its included Watch app, resources and icons.
- Verify host connection, tool discovery and resource retrieval independently of model behavior.
- For a catalog, test authenticated publication, discovery, adoption and receipt persistence.
- For a Pet, verify the selected stable ID separately from custom-image creation or update.
- For a Dot or named agent, verify the requested behavior in the intended host.
- For Watch transfer, distinguish queueing, sending, receiver validation, storage and display.
- Check device provisioning and connectivity before using installation as execution evidence.

Keep local account, device and diagnostic records outside the public repository.
Fixture exchanges, compilation and file generation do not prove another user's
host behavior or physical-device delivery.

## Optional local transfer diagnostics

기기 진단 빌드는 DEBUG에서 `--character-transfer-diagnostics`를 명시했을 때만 CharacterTransferDiagnostics.json을 기록합니다. 추가 `--send-character <id>`는 실제 앱의 기존 send 함수를 호출합니다. 정상 실행·Release에서는 진단 파일을 쓰지 않으며 캐릭터 내용은 진단에 포함하지 않습니다. queue·송신 callback·수신 확인을 합치지 않습니다.
