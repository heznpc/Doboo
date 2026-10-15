import XCTest

final class CompanionInteractionUITests: XCTestCase {
  @MainActor func testTouchSettlesAfterDragAndTaskSheet() throws {
    let app = XCUIApplication()
    app.launch()
    let character = app.buttons["character.play"]
    XCTAssertTrue(character.waitForExistence(timeout: 15))
    let resting = try XCTUnwrap(character.value as? String)
    XCTAssertFalse(resting.isEmpty)

    let start = character.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
    let end = character.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
    start.press(forDuration: 1, thenDragTo: end)
    XCTAssertEqual(character.value as? String, resting)

    app.buttons["home.tasks"].tap()
    let dismiss = app.buttons["task.dismiss"]
    XCTAssertTrue(dismiss.waitForExistence(timeout: 10))
    dismiss.tap()
    XCTAssertTrue(character.waitForExistence(timeout: 10))
    character.tap()
    XCTAssertEqual(character.value as? String, resting)

    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(character.waitForExistence(timeout: 10))
    XCTAssertEqual(character.value as? String, resting)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "companion-after-interaction"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }
}
