import XCTest

/// Text fields in the in-app browser must stay above the keyboard, and the
/// page must return to the pill once the keyboard goes away. The pages mimic
/// Instagram's DM composer, comment box and search field.
///
/// Needs the simulator's software keyboard: turn off I/O > Keyboard > Connect
/// Hardware Keyboard if a test says the keyboard didn't appear.
@MainActor
final class BrowserKeyboardTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// A composer fixed to the bottom of the page, like Instagram's DMs.
  func testFixedComposerStaysAboveKeyboard() throws {
    let app = launch(
      body: """
        <p>Messages</p>
        <form style="position:fixed;left:0;right:0;bottom:0;padding:8px 8px calc(8px + env(safe-area-inset-bottom));background:#ddd">
          <input aria-label="Message" placeholder="Message…" style="box-sizing:border-box;width:100%;font-size:16px">
        </form>
        """)
    let field = app.webViews.textFields["Message"]
    try focus(field, in: app)
    // The page ends at the keyboard, so the composer sits right on it.
    let page = app.webViews.firstMatch
    XCTAssertLessThan(page.frame.maxY - field.frame.maxY, 20, "The composer \(field.frame) floats above the page's end \(page.frame).")
    try dismissKeyboard(in: app)
    // The composer is back on top of the pill, not under it.
    XCTAssertLessThanOrEqual(field.frame.maxY, pill(in: app).frame.minY + 1)
  }

  /// A field in the page's flow that the keyboard would cover, like a
  /// comment box below a post.
  func testInlineCommentBoxScrollsAboveKeyboard() throws {
    let app = launch(
      body: """
        <div style="height:calc(100vh - 190px)">Post</div>
        <input aria-label="Comment" placeholder="Add a comment…" style="box-sizing:border-box;width:100%;font-size:16px">
        <div style="height:100vh">More comments</div>
        """)
    try focus(app.webViews.textFields["Comment"], in: app)
    try dismissKeyboard(in: app)
  }

  /// A field at the top of the page, like Instagram's search.
  func testSearchFieldStaysVisible() throws {
    let app = launch(
      body: """
        <input aria-label="Search" placeholder="Search" style="box-sizing:border-box;width:100%;font-size:16px">
        <div style="height:200vh">Results</div>
        """)
    let field = app.webViews.textFields["Search"]
    try focus(field, in: app)
    XCTAssertGreaterThanOrEqual(field.frame.minY, app.windows.firstMatch.safeAreaTop)
    try dismissKeyboard(in: app)
  }

  // MARK: - Helpers

  private func launch(body: String) -> XCUIApplication {
    let html = """
      <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
      <body style="margin:0;font:17px system-ui">\(body)</body>
      """
    let app = XCUIApplication()
    app.launchArguments = [
      "-browse", "instagram", "-browseURL", "data:text/html;base64," + Data(html.utf8).base64EncodedString(),
    ]
    app.launch()
    XCTAssertTrue(pill(in: app).waitForExistence(timeout: 15), "The browser didn't open.")
    return app
  }

  /// The pill's Close button; the pill hides while the keyboard is up.
  private func pill(in app: XCUIApplication) -> XCUIElement { app.buttons["Close"] }

  /// Taps the field and checks it ends up fully above the keyboard.
  @discardableResult
  private func focus(_ field: XCUIElement, in app: XCUIApplication) throws -> XCUIElement {
    XCTAssertTrue(field.waitForExistence(timeout: 15), "The test page didn't load.")
    XCTAssertLessThanOrEqual(field.frame.maxY, pill(in: app).frame.minY + 1, "The pill covers the field.")
    field.tap()
    let keyboard = app.keyboards.firstMatch
    guard keyboard.waitForExistence(timeout: 5) else {
      throw XCTSkip("The software keyboard didn't appear; disconnect the simulator's hardware keyboard.")
    }
    let visible = eventually {
      keyboard.frame.height > 100 && field.frame.maxY <= keyboard.frame.minY + 1 && field.frame.minY >= 0
    }
    XCTAssertTrue(
      visible, "Field \(field.frame) is hidden by the keyboard \(keyboard.frame).")
    field.typeText("hi")
    XCTAssertEqual(field.value as? String, "hi", "Typing didn't reach the field.")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Keyboard up"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    return keyboard
  }

  /// Drags the page down past the keyboard, as people do, and waits for the
  /// pill to return.
  private func dismissKeyboard(in app: XCUIApplication) throws {
    let page = app.webViews.firstMatch
    page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
      .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
    XCTAssertTrue(eventually { !app.keyboards.firstMatch.exists }, "The keyboard didn't go away.")
    XCTAssertTrue(eventually { self.pill(in: app).isHittable }, "The pill didn't come back.")
    // The page fills the screen again, down to the pill.
    XCTAssertTrue(
      eventually { page.frame.maxY >= app.windows.firstMatch.frame.maxY - 1 },
      "The page \(page.frame) no longer reaches the bottom of the screen.")
  }

  private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    repeat {
      if condition() { return true }
      RunLoop.current.run(until: .now.addingTimeInterval(0.2))
    } while Date.now < deadline
    return condition()
  }
}

extension XCUIElement {
  /// Below the status bar.
  fileprivate var safeAreaTop: CGFloat { frame.minY + 44 }
}
