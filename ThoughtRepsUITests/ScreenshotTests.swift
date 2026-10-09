import XCTest

/// Captures the App Store screenshots. Run through `app-store-assets/Screenshots/gen.mjs --capture`,
/// which prepares the simulator (status bar) and exports the attachments. Each test launches the app
/// in its debug-only screenshot mode (in-memory store, fixed seed) and attaches one PNG of the screen.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-screenshotMode", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
    }

    private func snap(_ name: String) {
        Thread.sleep(forTimeInterval: 1.0)
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
        XCTAssertTrue(app.staticTexts["Margin of safety"].waitForExistence(timeout: 10))
        snap("01-timeline")
    }

    func testIntervalPicker() {
        openThought("Rubber-duck before asking")
        let more = app.buttons["More intervals"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        XCTAssertTrue(app.buttons["Custom…"].waitForExistence(timeout: 10))
        snap("02-interval")
    }

    func testMarkdownAndPhotos() {
        openThought("Weekend in the mountains")
        XCTAssertTrue(app.buttons["Moodboard image 1 of 4"].waitForExistence(timeout: 10))
        snap("03-markdown-photos")
    }

    func testSearch() {
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
        app.tabBars.buttons["Tags"].tap()
        XCTAssertTrue(app.staticTexts["#journal"].waitForExistence(timeout: 10))
        snap("05-tags")
    }

    func testReminders() {
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Reminder"].waitForExistence(timeout: 10))
        snap("06-reminders")
    }
}
