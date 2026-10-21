import XCTest

/// Opt-in against the separately started test bridge; scene output is never injected into the app.
final class StoryFlowUITests: XCTestCase {
  @MainActor func testCreateSceneAndSequel() throws {
    guard ProcessInfo.processInfo.environment["DOBOO_STORY_UI_TEST"] == "1" else {
      throw XCTSkip("Requires isolated story bridge")
    }
    let id = "story-" + UUID().uuidString.lowercased()
    let pack: [String: Any] = [
      "format": "doboo.character.v1", "id": id, "version": 1,
      "name": "Moss", "description": "A cautious traveler", "creator": "UITest",
      "identity": ["backstory": "An observatory traveler", "voice": "Speak cautiously"],
      "personality": ["traits": ["cautious"], "instructions": ["Respect fictional memories"]],
      "appearance": ["renderer": "native-doboo", "tint": "#77AABB"]
    ]
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).json")
    try JSONSerialization.data(withJSONObject: pack).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let app = XCUIApplication()
    app.launchArguments = ["--import-character", file.path, "-AppleLanguages", "(ko)"]
    app.launch()
    app.tabBars.buttons["이야기"].tap()
    let create = app.buttons["story.create"]
    XCTAssertTrue(create.waitForExistence(timeout: 20))
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 20)
    create.tap()
    let title = app.textFields["story.title"]
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    title.tap(); title.typeText("Observatory \(id.suffix(6))")
    for cast in ["doboo", id] {
      let registration = app.buttons["story.register.\(cast)"]
      if registration.exists { reveal(registration, in: app); registration.tap() }
      let toggle = app.switches["story.cast.\(cast)"]
      XCTAssertTrue(toggle.waitForExistence(timeout: 20))
      reveal(toggle, in: app)
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
      XCTAssertEqual(toggle.value as? String, "1")
    }
    let save = app.buttons["story.createEpisode"]
    reveal(save, in: app)
    XCTAssertTrue(save.isEnabled)
    save.tap()
    let episode = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'story.episode.'")).firstMatch
    XCTAssertTrue(episode.waitForExistence(timeout: 20)); episode.tap()
    let scene = app.textFields["story.scenePrompt"]
    reveal(scene, in: app)
    scene.tap(); scene.typeText("Doboo shares the observatory code AURORA913 with Moss. Both speak. Record this in memory and propose a trust relationship.")
    let send = app.buttons["story.sendScene"]
    reveal(send, in: app); send.tap()
    let memory = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'story.editEvent.'")).firstMatch
    XCTAssertTrue(app.staticTexts["완료"].waitForExistence(timeout: 240))
    reveal(memory, in: app)
    XCTAssertTrue(memory.exists)
    let sceneShot = XCTAttachment(screenshot: app.screenshot())
    sceneShot.name = "story-scene-and-memory"; sceneShot.lifetime = .keepAlways; add(sceneShot)
    app.swipeDown(); app.swipeDown()
    let sequel = app.buttons["story.sequel"]
    reveal(sequel, in: app); sequel.tap()
    let sequelTitle = app.alerts.textFields.firstMatch
    XCTAssertTrue(sequelTitle.waitForExistence(timeout: 10))
    sequelTitle.tap(); sequelTitle.typeText("Return to observatory")
    app.alerts.buttons["에피소드 만들기"].tap()
    XCTAssertTrue(app.buttons["story.openSequel"].waitForExistence(timeout: 20))
    app.buttons["story.openSequel"].tap()
    XCTAssertTrue(app.textFields["story.scenePrompt"].waitForExistence(timeout: 10))
    let sequelShot = XCTAttachment(screenshot: app.screenshot())
    sequelShot.name = "story-sequel"; sequelShot.lifetime = .keepAlways; add(sequelShot)
  }

  @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<10 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
  }
}
