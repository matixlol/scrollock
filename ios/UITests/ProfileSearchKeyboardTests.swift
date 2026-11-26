import XCTest

/// The home screen's profile search must offer a Search key that closes the
/// keyboard, leaving the query and its results on screen.
///
/// Needs the simulator's software keyboard: turn off I/O > Keyboard > Connect
/// Hardware Keyboard if the test says the keyboard didn't appear.
@MainActor
final class ProfileSearchKeyboardTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  func testSearchKeyClosesKeyboard() throws {
    let app = XCUIApplication()
    app.launch()
    let field = app.textFields["profileSearchField"]
    XCTAssertTrue(field.waitForExistence(timeout: 15), "The search bar didn't appear.")
    field.tap()
    let keyboard = app.keyboards.firstMatch
    guard keyboard.waitForExistence(timeout: 5) else {
      throw XCTSkip("The software keyboard didn't appear; disconnect the simulator's hardware keyboard.")
    }
    field.typeText("@nike")

    // The return key is labelled Search, in whatever language the keyboard uses.
    let searchKey = keyboard.buttons.matching(
      NSPredicate(format: "label IN[c] %@ OR identifier IN[c] %@", ["Search", "Buscar"], ["Search", "Buscar"])
    ).firstMatch
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Keyboard with Search key"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    XCTAssertTrue(searchKey.exists, "The keyboard has no Search key:\n\(keyboard.debugDescription)")
    searchKey.tap()

    XCTAssertTrue(waitForDisappearance(of: keyboard), "The keyboard stayed up.")
    XCTAssertEqual(field.value as? String, "@nike", "Closing the keyboard cleared the search.")
    XCTAssertTrue(app.buttons["Open @nike on Instagram"].exists, "The results went away with the keyboard.")
    XCTAssertTrue(app.buttons["Close search"].isHittable)
  }

  private func waitForDisappearance(of element: XCUIElement) -> Bool {
    let deadline = Date.now.addingTimeInterval(5)
    while element.exists && Date.now < deadline { RunLoop.current.run(until: .now.addingTimeInterval(0.1)) }
    return !element.exists
  }
}
