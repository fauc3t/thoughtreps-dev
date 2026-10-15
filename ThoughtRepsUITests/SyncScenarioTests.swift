import XCTest

/// Two-device sync scenarios, driven by `scripts/sync-integ.sh` (see its header). Each test is one scenario and runs on both
/// devices at once: device A (iPhone) asserts what the user sees, device B (iPad) does the other side's work. They hand
/// over steps through marker files in `TR_SYNC_DIR`, which both simulators can read because they share the host's filesystem.
/// Without the script's variables every test skips, so the scheme stays safe to run on its own.
///
/// A device makes the app sync by sending it to the background and back (the app runs a cycle on foreground), so waiting
/// for a state is a loop of that and a check, never a long sleep.
final class SyncScenarioTests: XCTestCase {
    private var app: XCUIApplication!
    private var role = "a"
    private var directory = ""
    private var title = ""
    private var serverURL = ""
    private var vaultID = ""
    private var secret = ""

    private var isA: Bool { role == "a" }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Every probe thought carries this tag: a new thought isn't due yet, so the only list that shows it is its tag's "All".
    private static let tag = "syncprobe"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let role = env["TR_SYNC_ROLE"], let directory = env["TR_SYNC_DIR"], let url = env["TR_SYNC_URL"],
              let vault = env["TR_SYNC_VAULT"], let secret = env["TR_SYNC_SECRET"], let key = env["TR_SYNC_KEY"]
        else { throw XCTSkip("Run through scripts/sync-integ.sh") }
        self.role = role
        self.directory = directory
        serverURL = url
        vaultID = vault
        self.secret = secret
        title = "Probe \(vault.suffix(6))"
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-didSeedSampleData", "YES", "-reminderPromptAsked", "YES", "-ratingPromptAsked", "YES",
        ]
        app.launchEnvironment = [
            "THOUGHTREPS_SYNC_URL": url, "THOUGHTREPS_SYNC_VAULT": vault,
            "THOUGHTREPS_SYNC_DEV_SECRET": secret, "THOUGHTREPS_SYNC_KEY": key,
            "THOUGHTREPS_SYNC_STATUS_FILE": "\(directory)/status-\(role).json",
        ]
    }

    // MARK: Scenarios

    /// A has a thought's detail screen open when B deletes it: the screen goes away.
    func testDeletedWhileOpen_detail() throws {
        let name = "\(title) detail"
        if isA {
            launchAfterPeer()
            waitForThought(name)
            openThought(name, listShowing: true)
            signal("opened")
            waitForSignal("deleted")
            XCTAssertTrue(syncUntil { !self.app.buttons["More intervals"].exists && self.listIsShowing },
                          "the detail screen should pop once the delete syncs")
            XCTAssertFalse(thoughtRow(name).exists)
            signal("done")
            assertChecksPass()
        } else {
            launchAndSignalReady()
            createThought(name)
            signal("created")
            waitForSignal("opened")
            openThought(name)
            deleteOpenThoughtAndPublishHead()
            waitForSignal("done")
            assertChecksPass()
        }
    }

    /// A has the thought in the editor when B deletes it: the editor stays open with its notice, and Save keeps the text
    /// as a new thought that reaches B.
    func testDeletedWhileOpen_editor() throws {
        let name = "\(title) editor"
        if isA {
            launchAfterPeer()
            waitForThought(name)
            openThought(name, listShowing: true)
            app.buttons["Edit"].tap()
            XCTAssertTrue(app.navigationBars["Edit thought"].waitForExistence(timeout: 10))
            signal("opened")
            waitForSignal("deleted")
            let notice = app.staticTexts["This thought was deleted on another device. Save keeps it as a new thought."]
            XCTAssertTrue(syncUntil { notice.exists }, "the editor should show the deleted notice")
            XCTAssertTrue(app.navigationBars["Edit thought"].exists, "the editor should stay open")
            app.textViews["Thought"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            dismissKeyboardPrompt()
            app.typeText(" kept")
            app.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars["Edit thought"].waitForNonExistence(timeout: 10), "Save should close the editor")
            signal("saved")
            waitForSignal("done")
            assertChecksPass()
        } else {
            launchAndSignalReady()
            createThought(name)
            signal("created")
            waitForSignal("opened")
            openThought(name)
            deleteOpenThoughtAndPublishHead()
            waitForSignal("saved")
            openProbeList()
            XCTAssertTrue(syncUntil { self.keptThought.exists }, "the thought A saved should reach B")
            signal("done")
            assertChecksPass()
        }
    }

    /// A has a thought open with a linked thought pushed on top when B deletes the first: the linked thought stays, and
    /// going back skips the deleted one.
    func testDeletedWhileOpen_coveredByLinkedThought() throws {
        let target = "\(title) target"
        let source = "\(title) source"
        if isA {
            launchAfterPeer()
            waitForThought(source)
            openThought(source, listShowing: true)
            let card = app.buttons["Linked thought: \(target)"]
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            card.tap()
            XCTAssertTrue(app.staticTexts[target].waitForExistence(timeout: 10))
            signal("opened")
            let head = waitForSignal("deleted")
            XCTAssertTrue(syncUntil { (self.status()?.cursor ?? 0) >= head }, "the delete should reach A while the linked thought covers it")
            XCTAssertTrue(app.staticTexts[target].exists, "the pushed linked thought should stay")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(syncUntil(timeout: 30) { self.listIsShowing && !self.app.buttons["More intervals"].exists },
                          "going back should skip the deleted thought and land on the list")
            XCTAssertFalse(thoughtRow(source).exists)
            signal("done")
            assertChecksPass()
        } else {
            launchAndSignalReady()
            createThought(target)
            createThought(source, linking: target)
            signal("created")
            waitForSignal("opened")
            openThought(source)
            deleteOpenThoughtAndPublishHead()
            waitForSignal("done")
            assertChecksPass()
        }
    }

    // MARK: Waiting for a state

    /// Syncs by foregrounding the app until `done` holds; false after `timeout` seconds.
    private func syncUntil(timeout: TimeInterval = 60, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            XCUIDevice.shared.press(.home)
            app.activate()
            Thread.sleep(forTimeInterval: 0.5)
            if done() { return true }
        }
        return done()
    }

    /// The app's own status file (`SyncDebugSession.StatusSnapshot`), rewritten after every cycle.
    private func status() -> (cycles: Int, cursor: Int64, outbox: Int)? {
        guard let data = FileManager.default.contents(atPath: "\(directory)/status-\(role).json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cycles = (json["cycles"] as? NSNumber)?.intValue, let cursor = (json["cursor"] as? NSNumber)?.int64Value,
              let outbox = (json["outbox"] as? NSNumber)?.intValue
        else { return nil }
        return (cycles, cursor, outbox)
    }

    /// The server's head seq, asked for directly with the dev secret.
    private func serverHeadSeq() -> Int64 {
        var request = URLRequest(url: URL(string: "\(serverURL)/head")!)
        request.setValue("Dev \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue(vaultID, forHTTPHeaderField: "x-tr-vault")
        var seq: Int64 = -1
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json["headSeq"] as? NSNumber { seq = value.int64Value }
            done.signal()
        }.resume()
        done.wait()
        return seq
    }

    private var listIsShowing: Bool { app.navigationBars["#\(Self.tag)"].exists }

    private var keptThought: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "kept")).firstMatch
    }

    private func thoughtRow(_ name: String) -> XCUIElement {
        app.buttons.containing(.staticText, identifier: name).firstMatch
    }

    private func waitForThought(_ name: String) {
        openProbeList()
        XCTAssertTrue(syncUntil { self.thoughtRow(name).exists }, "\(name) should reach this device")
    }

    // MARK: Launching and signals

    private func launchAndSignalReady() {
        app.launch()
        XCTAssertTrue(app.buttons["New thought"].waitForExistence(timeout: 30))
        signal("b-launched")
    }

    private func launchAfterPeer() {
        waitForSignal("b-launched")
        app.launch()
        XCTAssertTrue(app.buttons["New thought"].waitForExistence(timeout: 30))
    }

    private func signal(_ name: String, _ value: Int64? = nil) {
        FileManager.default.createFile(atPath: "\(directory)/\(name)", contents: value.map { Data("\($0)".utf8) })
    }

    /// Waits for the other device's marker and returns the number it carries (0 for an empty one).
    @discardableResult
    private func waitForSignal(_ name: String, timeout: TimeInterval = 120) -> Int64 {
        let path = "\(directory)/\(name)"
        let end = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path) {
            if Date() > end {
                XCTFail("The other device never signalled \(name)")
                return 0
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }.flatMap { Int64($0) } ?? 0
    }

    // MARK: Driving the app

    /// The tag's list with "All" selected, reached from the tab bar on an iPhone and the sidebar on an iPad.
    private func openProbeList() {
        if !listIsShowing {
            openSection("Tags")
            let tag = app.staticTexts["#\(Self.tag)"].firstMatch
            XCTAssertTrue(syncUntil { tag.exists }, "the probe tag should reach this device")
            tag.tap()
        }
        let all = app.buttons["All"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        all.tap()
    }

    private func openSection(_ name: String) {
        if isPad {
            let row = app.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "No sidebar row \(name)")
            row.tap()
        } else {
            app.tabBars.buttons[name].tap()
        }
    }

    private func openThought(_ name: String, listShowing: Bool = false) {
        if !listShowing { openProbeList() }
        let row = thoughtRow(name)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["More intervals"].waitForExistence(timeout: 10))
    }

    private func dismissKeyboardPrompt() {
        let slideToType = app.buttons["Continue"]
        if slideToType.waitForExistence(timeout: 2) { slideToType.tap() }
    }

    private func createThought(_ name: String, linking target: String? = nil) {
        app.buttons["New thought"].tap()
        let field = app.textViews["Thought"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        dismissKeyboardPrompt()
        field.typeText("\(name)\n#\(Self.tag)")
        if let target {
            app.staticTexts["Add block"].firstMatch.tap()
            let kind = app.descendants(matching: .any).matching(identifier: "Linked thought").firstMatch
            XCTAssertTrue(kind.waitForExistence(timeout: 10),"the Add block menu should offer Linked thought")
            kind.tap()
            let row = app.buttons.containing(.staticText, identifier: target).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
        }
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["New thought"].waitForNonExistence(timeout: 10))
    }

    /// Deletes the open thought, waits until this device has pushed the delete, then tells the other device the server's
    /// head seq at that point: once it has pulled that far it has the delete.
    private func deleteOpenThoughtAndPublishHead() {
        app.buttons["More"].tap()
        app.buttons["Delete"].firstMatch.tap()
        let dialog = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Delete this thought?", "This can't be undone."])).firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "the delete confirmation should appear")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["More intervals"].waitForNonExistence(timeout: 10))
        let before = status()?.cycles ?? 0
        XCTAssertTrue(syncUntil { (self.status().map { $0.cycles >= before + 2 && $0.outbox == 0 }) ?? false },
                      "the delete should be pushed")
        let head = serverHeadSeq()
        XCTAssertGreaterThan(head, 0, "the server's head should be readable")
        signal("deleted", head)
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
    }

    /// Settings > Sync lab > Run checks: the integrity and search index checks must pass on this device.
    private func assertChecksPass() {
        openSection("Timeline")
        app.buttons["Settings"].tap()
        scrollTo(app.buttons["Sync lab"])
        app.buttons["Sync lab"].tap()
        scrollTo(app.buttons["Run checks"])
        app.buttons["Run checks"].tap()
        let result = app.staticTexts["syncLabChecksResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertEqual(result.label, "Passed")
    }
}
