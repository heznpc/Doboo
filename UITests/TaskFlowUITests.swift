import XCTest

/// Opt-in live test. Requires the separately started, authenticated computer bridge.
/// No mock transport, launch-argument task submission, or injected result.
final class TaskFlowUITests: XCTestCase {
  @MainActor func testCompanionRemainsHomeAndOpensActualResult() throws {
    guard ProcessInfo.processInfo.environment["DOBOO_LIVE_TASK_TEST"] == "1" else { throw XCTSkip("Live companion verification only") }
    let app = XCUIApplication()
    app.launch()
    let character = app.buttons["character.play"]
    XCTAssertTrue(character.waitForExistence(timeout: 15))
    XCTAssertFalse(app.textFields["task.prompt"].exists)
    let resting = character.value as? String
    let start = character.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4))
    let end = character.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.55))
    start.press(forDuration: 4, thenDragTo: end)
    XCTAssertEqual(character.value as? String, resting)
    let home = XCTAttachment(screenshot: app.screenshot()); home.name = "companion-home"; home.lifetime = .keepAlways; add(home)
    app.buttons["home.tasks"].tap()
    let status = app.staticTexts["task.status"]
    XCTAssertTrue(status.waitForExistence(timeout: 15))
    XCTAssertEqual(status.label, "완료")
    XCTAssertTrue(app.staticTexts["task.result"].exists)
    app.buttons["task.dismiss"].tap()
    XCTAssertTrue(character.waitForExistence(timeout: 10))
    XCTAssertFalse(app.textFields["task.prompt"].exists)
  }

  @MainActor func testPhoneRequestsRealComputerWork() throws {
    guard ProcessInfo.processInfo.environment["DOBOO_LIVE_TASK_TEST"] == "1" else {
      throw XCTSkip("Explicit live bridge verification only")
    }
    let app = XCUIApplication()
    app.launch()
    app.buttons["캐릭터"].firstMatch.tap()
    let card = app.buttons["character.card.doboo"]
    if !card.isHittable { app.swipeUp() }
    XCTAssertTrue(card.waitForExistence(timeout: 10))
    card.tap()
    let select = app.buttons["character.select"]
    if !select.isHittable { app.swipeUp() }
    select.tap()
    app.buttons["동반자"].firstMatch.tap()
    app.buttons["home.tasks"].tap()
    let memory = app.buttons["memory.open"]
    XCTAssertTrue(memory.waitForExistence(timeout: 20))
    if !memory.isHittable { app.swipeUp() }
    memory.tap()
    let saveMemory = app.buttons["memory.save"]
    XCTAssertTrue(saveMemory.waitForExistence(timeout: 10))
    if !saveMemory.isHittable { app.swipeUp() }
    saveMemory.tap()
    XCTAssertTrue(app.descendants(matching: .any)["memory.saved"].firstMatch.waitForExistence(timeout: 20))
    app.buttons["memory.close"].tap()
    let field = app.textFields["task.prompt"].exists ? app.textFields["task.prompt"] : app.textViews["task.prompt"]
    guard field.waitForExistence(timeout: 20) else { return XCTFail("Task entry missing") }
    if !field.isHittable { app.swipeUp() }
    field.tap()
    field.typeText("Run npm test in this project. If the tests pass, create work/phone-task-proof.txt containing DOBOO_PHONE_TO_COMPUTER_OK and the real test summary. Do not commit or push. Report the result in Korean.")
    let submit = app.buttons["task.submit"]
    XCTAssertTrue(submit.waitForExistence(timeout: 10))
    let ready = NSPredicate(format: "enabled == true")
    expectation(for: ready, evaluatedWith: submit)
    waitForExpectations(timeout: 20)
    guard submit.isEnabled else { return XCTFail("Computer connection not ready") }
    submit.tap()
    let status = app.staticTexts["task.status"]
    guard status.waitForExistence(timeout: 20) else { return XCTFail("Task was not accepted") }
    let running = XCTAttachment(screenshot: app.screenshot()); running.name = "phone-submitted"; running.lifetime = .keepAlways; add(running)
    let completed = NSPredicate(format: "label IN %@", ["완료", "실패", "중단됨"])
    expectation(for: completed, evaluatedWith: status)
    waitForExpectations(timeout: 420)
    XCTAssertEqual(status.label, "완료")
    XCTAssertTrue(app.staticTexts["task.result"].exists)
    let result = XCTAttachment(screenshot: app.screenshot()); result.name = "phone-completed"; result.lifetime = .keepAlways; add(result)
  }
}
