import XCTest

/// Captures the App Store screenshots. Run through `app-store-assets/Screenshots/gen.mjs --capture`,
/// which prepares the simulator (status bar) and exports the attachments. Each test launches the app
/// in its debug-only screenshot mode (in-memory store, fixed seed) and attaches one PNG of the screen.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-screenshotMode", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
        app.launch()
    }

    private func snap(_ name: String, settle: TimeInterval = 1.0) {
        Thread.sleep(forTimeInterval: settle)
        let attachment = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openThought(_ title: String) {
        let card = app.buttons.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "No card titled \(title)")
        card.tap()
    }

    func testTimeline() {
        launch()
        XCTAssertTrue(app.staticTexts["Weekend in the mountains"].waitForExistence(timeout: 10))
        snap("01-timeline")
    }

    func testIntervalPicker() {
        launch()
        openThought("Margin of safety")
        XCTAssertTrue(app.buttons["More intervals"].waitForExistence(timeout: 10))
        snap("02-interval")
    }

    func testMarkdownAndPhotos() {
        launch()
        openThought("Weekend in the mountains")
        XCTAssertTrue(app.buttons["Moodboard image 1 of 4"].waitForExistence(timeout: 10))
        snap("03-markdown-photos")
    }

    func testSearch() {
        launch()
        app.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let slideToType = app.buttons["Continue"]
        if slideToType.waitForExistence(timeout: 2) { slideToType.tap() }
        field.typeText("reflect")
        XCTAssertTrue(app.staticTexts["Why journals work"].waitForExistence(timeout: 10))
        app.keyboards.buttons["Search"].tap()
        snap("04-search")
    }

    func testTags() {
        launch()
        app.tabBars.buttons["Tags"].tap()
        XCTAssertTrue(app.staticTexts["#journal"].waitForExistence(timeout: 10))
        snap("05-tags")
    }

    /// The app schedules its test reminder 15 seconds out (asking for permission the first time on a
    /// simulator); the device is locked and the notification captured on the Lock Screen once it arrives.
    func testReminderNotification() {
        launch(["-screenshotReminder"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 8) { allow.tap() }
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        let banner = springboard.staticTexts["4 thoughts are back today"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30), springboard.debugDescription)
        snap("06-reminders", settle: 0.6)
    }
}
