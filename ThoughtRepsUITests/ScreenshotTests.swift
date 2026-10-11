import XCTest

/// Captures the App Store screenshots. Run through `app-store-assets/Screenshots/gen.mjs --capture`,
/// which prepares the simulator (status bar) and exports the attachments. Each test launches the app
/// in its debug-only screenshot mode (in-memory store, fixed seed) and attaches one PNG of the screen.
/// On an iPad it runs in landscape, where the regular-width split view shows the section list and the
/// open thought side by side.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
    }

    /// The tab bar on an iPhone, the sidebar on an iPad.
    private func openSection(_ name: String) {
        if isPad {
            let row = app.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "No sidebar row \(name)")
            row.tap()
        } else {
            app.tabBars.buttons[name].tap()
        }
    }

    private func launch(_ extraArguments: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-screenshotMode", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extraArguments
        app.launch()
    }

    /// A landscape iPad screenshot comes back as the portrait framebuffer with the content turned on its
    /// side; turn it upright so the capture is 2752x2064 as shown.
    private func uprightPNG(_ screenshot: XCUIScreenshot) -> Data {
        guard isPad, let image = screenshot.image.cgImage else { return screenshot.pngRepresentation }
        let turned = UIImage(cgImage: image, scale: 1, orientation: .left)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: turned.size, format: format).pngData { _ in turned.draw(at: .zero) }
    }

    private func snap(_ name: String, settle: TimeInterval = 1.0) {
        Thread.sleep(forTimeInterval: settle)
        let attachment = XCTAttachment(data: uprightPNG(XCUIScreen.main.screenshot()), uniformTypeIdentifier: "public.png")
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
        XCTAssertTrue(app.staticTexts["Hope is the thing with feathers"].waitForExistence(timeout: 10))
        if isPad { openThought("The cost of a thing") }
        snap("01-timeline")
    }

    /// The same thought before and after tapping its blurred block.
    func testBlurredBlock() {
        launch()
        openThought("Ser vs estar")
        let hidden = app.buttons["Answer, hidden"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 10))
        snap("02-blurred-before")
        hidden.tap()
        XCTAssertTrue(app.buttons["Answer, hidden"].waitForNonExistence(timeout: 10))
        snap("02-blurred-after")
    }

    /// A due Learn thought with its blurred lines revealed, above Again / Got it.
    func testLearnMode() {
        launch()
        openThought("Hope is the thing with feathers")
        let hidden = app.buttons["Lines, hidden"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 10))
        hidden.tap()
        XCTAssertTrue(hidden.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Got it'")).firstMatch.exists)
        snap("03-learn")
    }

    /// One thought in each theme, for the cascade.
    func testThemes() {
        for theme in ["ink", "library", "midnight", "garden", "terminal", "pop"] {
            launch(["-screenshotTheme", theme])
            openThought("The cost of a thing")
            XCTAssertTrue(app.buttons["More intervals"].waitForExistence(timeout: 10))
            snap("04-themes-\(theme)")
            app.terminate()
        }
    }

    func testIntervalPicker() {
        launch()
        openThought("Thirteen virtues, one a week")
        XCTAssertTrue(app.buttons["More intervals"].waitForExistence(timeout: 10))
        snap("05-interval")
    }

    func testMarkdownAndPhotos() {
        launch()
        // Not due, so it's opened from its tag's "All" list.
        openSection("Tags")
        let travel = app.staticTexts["#travel"]
        XCTAssertTrue(travel.waitForExistence(timeout: 10))
        travel.tap()
        let all = app.buttons["All"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        all.tap()
        openThought("Weekend in the mountains")
        XCTAssertTrue(app.buttons["Moodboard image 1 of 4"].waitForExistence(timeout: 10))
        snap("06-markdown-photos")
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
        let searchKey = app.keyboards.buttons["Search"]
        if searchKey.exists { searchKey.tap() } else { field.typeText("\n") }
        snap("07-search")
    }

    func testTags() {
        launch()
        openSection("Tags")
        XCTAssertTrue(app.staticTexts["#journal"].waitForExistence(timeout: 10))
        snap("08-tags")
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
        snap("09-reminders", settle: 0.6)
    }
}
