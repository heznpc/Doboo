import XCTest

final class CharacterSettingsUITests: XCTestCase {
  @MainActor func testImportedSettingsEditSurvivesRelaunch() throws {
    let id = "settings-" + UUID().uuidString.lowercased()
    let fixture: [String: Any] = [
      "format": "doboo.character.v1", "id": id, "version": 1,
      "name": "설정 확인 캐릭터", "description": "Troupe 설정 편집 검증", "creator": "UITest",
      "identity": ["backstory": "별빛 극장의 안내자", "voice": "짧고 다정하게 말한다"],
      "personality": ["traits": ["호기심"], "instructions": ["기존 지침 보존"]],
      "appearance": ["renderer": "native-doboo", "tint": "#FF8F62"],
      "characterization": [
        "appearanceDescription": "별 모양 장식", "perspective": "실수도 이야기의 일부다",
        "principles": ["선택을 대신하지 않는다"],
        "workStyle": ["initiative": "먼저 작은 제안을 한다", "updates": "짧게 알린다", "recovery": "다음 장면을 찾는다"],
        "examples": [["situation": "사용자가 돌아왔다", "response": "다음 장면을 함께 펼쳐볼까?"]],
        "origin": ["schema": "troupe.character.v1", "id": id, "version": "1.0.0", "personalityId": "guide", "personalityVersion": "1.2.0", "personalityName": "안내자"]
      ]
    ]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).json")
    try JSONSerialization.data(withJSONObject: fixture).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let app = XCUIApplication()
    app.launchArguments = ["--import-character", url.path, "-AppleLanguages", "(ko)"]
    app.launch()
    app.tabBars.buttons["캐릭터"].tap()
    let card = app.buttons["character.card.\(id)"]
    reveal(card, in: app)
    card.tap()
    let origin = app.staticTexts["character.origin"]
    reveal(origin, in: app)
    XCTAssertTrue(origin.exists)
    XCTAssertTrue(app.staticTexts["Troupe"].exists)
    reveal(app.staticTexts["별빛 극장의 안내자"], in: app)
    XCTAssertTrue(app.staticTexts["별빛 극장의 안내자"].exists)
    let before = XCTAttachment(screenshot: app.screenshot())
    before.name = "character-settings-source"; before.lifetime = .keepAlways; add(before)
    app.buttons["character.edit"].tap()
    let perspective = app.descendants(matching: .any).matching(identifier: "editor.perspective").firstMatch
    reveal(perspective, in: app)
    XCTAssertTrue(perspective.exists)
    perspective.tap()
    perspective.press(forDuration: 1.2)
    let selectAll = app.menuItems.matching(NSPredicate(format: "label IN %@", ["전체 선택", "Select All"])).firstMatch
    XCTAssertTrue(selectAll.waitForExistence(timeout: 3))
    selectAll.tap()
    perspective.typeText("함께 새로운 장면을 만든다")
    app.buttons["editor.save"].tap()
    XCTAssertTrue(app.staticTexts["character.detail.identity"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["character.detail.identity"].label.contains("v2"))
    app.terminate()
    app.launchArguments = ["-AppleLanguages", "(ko)"]
    app.launch()
    app.tabBars.buttons["캐릭터"].tap()
    reveal(card, in: app)
    card.tap()
    let updated = app.staticTexts["함께 새로운 장면을 만든다"]
    reveal(updated, in: app)
    XCTAssertTrue(updated.exists)
    let after = XCTAttachment(screenshot: app.screenshot())
    after.name = "character-settings-persisted"; after.lifetime = .keepAlways; add(after)
  }

  @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<12 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
  }
}
