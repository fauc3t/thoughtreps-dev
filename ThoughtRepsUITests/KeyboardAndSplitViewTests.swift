import XCTest

/// Hardware-keyboard shortcuts and the iPad split view (the editor's ⌘↩ and Esc aren't covered: XCUITest
/// key events didn't trigger them in the simulator, so they need a device check), against the debug-only screenshot seed.
/// Run with the `ThoughtRepsScreenshots` scheme (`-only-testing:ThoughtRepsUITests/KeyboardAndSplitViewTests`).
final class KeyboardAndSplitViewTests: XCTestCase {
    private var app: XCUIApplication!

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["-screenshotMode", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Hope is the thing with feathers"].waitForExistence(timeout: 10))
    }

    /// The simulator sometimes drops the first key event after a launch or a presentation, so a key
    /// whose effect isn't there after a second is sent once more.
    private func press(_ key: String, _ flags: XCUIElement.KeyModifierFlags = .command, on target: XCUIElement? = nil, until done: () -> Bool) {
        let target = target ?? app!
        target.typeKey(key, modifierFlags: flags)
        for _ in 0..<10 where !done() { Thread.sleep(forTimeInterval: 0.1) }
        if !done() { target.typeKey(key, modifierFlags: flags) }
    }

    private func command(_ key: String) {
        app.typeKey(key, modifierFlags: .command)
    }

    private var editorIsOpen: Bool { app.staticTexts["New thought"].exists }

    func testNewThoughtShortcutOpensTheEditor() {
        press("n") { editorIsOpen }
        XCTAssertTrue(app.staticTexts["New thought"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["New thought"].waitForNonExistence(timeout: 5))
    }

    func testSectionShortcuts() {
        command("2")
        XCTAssertTrue(app.navigationBars["Tags"].waitForExistence(timeout: 5))
        command("3")
        XCTAssertTrue(app.navigationBars["Archive"].waitForExistence(timeout: 5))
        command("4")
        XCTAssertTrue(app.navigationBars["Stats"].waitForExistence(timeout: 5))
        command("1")
        XCTAssertTrue(app.navigationBars["Timeline"].waitForExistence(timeout: 5))
    }

    func testSearchAndSettingsShortcuts() {
        press("f") { app.staticTexts["Search your thoughts"].exists }
        XCTAssertTrue(app.staticTexts["Search your thoughts"].waitForExistence(timeout: 5))
        command("1")
        press(",") { app.staticTexts["Settings"].exists }
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }

    func testSplitViewSelectsAndClearsAThought() throws {
        try XCTSkipUnless(isPad, "The split view is iPad only")
        XCTAssertTrue(app.staticTexts["Select a thought"].exists)
        app.buttons.containing(.staticText, identifier: "The cost of a thing").firstMatch.tap()
        XCTAssertTrue(app.buttons["More intervals"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Select a thought"].exists)
        app.buttons["More"].tap()
        app.buttons["Archive"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Select a thought"].waitForExistence(timeout: 5))
    }

    func testDeleteFromTheDetailClearsTheSelection() throws {
        try XCTSkipUnless(isPad, "The split view is iPad only")
        app.buttons.containing(.staticText, identifier: "Ser vs estar").firstMatch.tap()
        XCTAssertTrue(app.buttons["More intervals"].waitForExistence(timeout: 5))
        app.buttons["More"].tap()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Select a thought"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Ser vs estar"].exists)
    }
}
