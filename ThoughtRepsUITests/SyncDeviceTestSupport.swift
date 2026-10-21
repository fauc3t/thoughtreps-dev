import XCTest

/// What the two-device sync UI tests share (`SyncScenarioTests`, `SyncAccountScenarioTests`): the role and marker plumbing, the
/// coordinator, sync triggers and status reading, and the app-driving helpers. A test class says what its run is called
/// (`identify`) and what the app launches with (`addLaunchEnvironment`); everything else is here.
///
/// A device makes the app sync by posting a Darwin notification, tapping a hidden button, or sending it to the background
/// and back, so waiting for a state is a loop of that and a check, never a long sleep.
class SyncDeviceTestCase: XCTestCase {
    var app: XCUIApplication!
    var role = "a"
    var directory = ""
    var coordinator: URL?
    var scenario = ""
    var title = ""
    var runID = ""
    var workingTrigger: SyncTrigger?

    var isA: Bool { role == "a" }
    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Every probe thought carries this tag: a new thought isn't due yet, so the only list that shows it is its tag's "All".
    static let tag = "syncprobe"

    /// A name for this run, unique per run (it keeps the two roles' sync-now notifications apart from other runs'), or nil
    /// if the launch environment lacks what the test class needs, which skips the test.
    func identify(environment: [String: String]) -> String? { nil }

    /// Adds what the app launches with beyond the shared arguments; `app` exists.
    func addLaunchEnvironment() {}

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let directory = env["TR_SYNC_DIR"] ?? ""
        let coordinator = env["TR_SYNC_COORDINATOR"].flatMap { URL(string: $0) }
        guard let role = env["TR_SYNC_ROLE"], !directory.isEmpty || coordinator != nil, let runID = identify(environment: env)
        else { throw XCTSkip("Run through scripts/sync-integ.sh or scripts/sync-device-integ.sh") }
        self.role = role
        self.directory = directory
        self.coordinator = directory.isEmpty ? coordinator : nil
        self.runID = runID
        scenario = invocation.map { NSStringFromSelector($0.selector).replacingOccurrences(of: "AndReturnError:", with: "") } ?? name
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-didSeedSampleData", "YES", "-reminderPromptAsked", "YES", "-ratingPromptAsked", "YES",
            "-syncSaveKeyToICloudKeychain", "<false/>",
        ]
        addLaunchEnvironment()
        app.launchEnvironment["THOUGHTREPS_UITEST_PLAIN_TYPING"] = "1"
        app.launchEnvironment["THOUGHTREPS_SYNC_NOW_NOTIFICATION"] = syncNowNotification
        if self.coordinator == nil {
            app.launchEnvironment["THOUGHTREPS_SYNC_STATUS_FILE"] = "\(directory)/status-\(role).json"
        } else {
            app.launchEnvironment["THOUGHTREPS_SYNC_STATUS_FILE"] = "Documents/status-\(role).json"
            app.launchEnvironment["THOUGHTREPS_SYNC_STATUS_PROBE"] = "1"
            reachCoordinator()
        }
    }

    /// On a device the runner's first request to the Mac raises the Local Network prompt; until it's answered every
    /// request fails (-1009). Keeps asking for up to two minutes, tapping Allow when the prompt shows. Any HTTP answer
    /// (the coordinator says 404 for an unknown marker) means the Mac is reachable.
    private func reachCoordinator() {
        guard let coordinator else { return }
        var request = URLRequest(url: coordinator.appending(path: scenario).appending(path: "reach"))
        request.timeoutInterval = 5
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        // iOS asks only for a foreground app, and the runner is in the background unless brought forward.
        if let runner = Bundle.main.bundleIdentifier { XCUIApplication(bundleIdentifier: runner).activate() }
        let end = Date().addingTimeInterval(120)
        while Date() < end {
            if send(request) != nil { return }
            if allow.exists { allow.tap() }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("Can't reach the coordinator. Turn on ThoughtRepsUITests-Runner in Settings > Privacy & Security > Local Network")
    }

    // MARK: Steps and convergence

    /// Syncs until every local change is pushed and a cycle has run since.
    func pushAll(timeout: TimeInterval = 90, settle: TimeInterval = SyncDeviceTestCase.defaultSettle) {
        let before = snapshot()?.cycles ?? 0
        XCTAssertTrue(syncUntil(timeout: timeout, settle: settle) { (self.snapshot().map { $0.cycles >= before + 2 && $0.outbox == 0 }) ?? false },
                      "this device's changes should be pushed: \(snapshot()?.summary ?? "no status")")
    }

    /// Pushes everything, then tells the peer the digest of this device's store.
    func publishStep(_ step: String, timeout: TimeInterval = 90, settle: TimeInterval = SyncDeviceTestCase.defaultSettle) {
        pushAll(timeout: timeout, settle: settle)
        guard let digest = snapshot()?.digest else {
            XCTFail("The status has no digest to publish for \(step)")
            return
        }
        signal(step, text: digest)
    }

    /// Waits for the peer's step and syncs until this device's store has the digest it published.
    func awaitStep(_ step: String, timeout: TimeInterval = 120, settle: TimeInterval = SyncDeviceTestCase.defaultSettle) {
        let expected = waitForSignalText(step)
        XCTAssertTrue(syncUntil(timeout: timeout, settle: settle) { (self.snapshot().map { $0.outbox == 0 && $0.digest == expected }) ?? false },
                      "this device should reach the state of \(step): \(snapshot()?.summary ?? "no status")")
    }

    /// The server's head seq when the test can ask for it; 0 (never ahead of the cursor) when it can't.
    func serverHeadSeq() -> Int64 { 0 }

    /// Both devices end with the same thought count and digest, an empty outbox, nothing parked or held, no stop reason, and a
    /// cursor at the server's head. Each publishes its own and compares with the peer's.
    func assertConverged(thoughts expected: Int, timeout: TimeInterval = 180, settle: TimeInterval = SyncDeviceTestCase.defaultSettle) {
        let peer = isA ? "b" : "a"
        var last: Snapshot?
        let converged = syncUntil(timeout: timeout, settle: settle) {
            guard let now = self.snapshot(), let count = now.thoughts, let digest = now.digest else { return false }
            last = now
            guard now.outbox == 0, now.parked == 0, now.held == 0, now.attention == nil, now.cursor >= self.serverHeadSeq() else { return false }
            let line = "\(count) \(digest)"
            self.signal("final-\(self.role)", text: line)
            return self.readMarker("final-\(peer)").flatMap { String(data: $0, encoding: .utf8) } == line
        }
        XCTAssertTrue(converged, "both devices should end with the same thoughts and nothing left to sync: \(last?.summary ?? "no status")")
        XCTAssertEqual(last?.thoughts, expected, "the thought count")
    }

    func fieldText(_ field: XCUIElement) -> String {
        field.value as? String ?? ""
    }

    func text(_ part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    // MARK: Waiting for a state

    static let defaultSettle: TimeInterval = 3

    enum SyncTrigger: String, CaseIterable {
        case signal, button, foreground
    }

    /// Unique per device role and run: two simulators can share a Darwin notify center, and one device's signal must never
    /// sync the other.
    var syncNowNotification: String { "com.thoughtreps.debug.sync-now.\(role).\(runID)" }

    /// Starts sync cycles until `done` holds; false after `timeout` seconds. Each round tries the trigger that last advanced
    /// `cycles` first, then the rest in order (Darwin notification, the app's hidden "sync now" button, backgrounding and
    /// foregrounding it), and credits the first one whose own settle window sees `cycles` advance.
    func syncUntil(timeout: TimeInterval = 60, settle: TimeInterval = SyncDeviceTestCase.defaultSettle, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            let order = (workingTrigger.map { [$0] } ?? []) + SyncTrigger.allCases.filter { $0 != workingTrigger }
            for trigger in order where Date() < end {
                let before = snapshot()?.cycles ?? 0
                guard fire(trigger) else { continue }
                if settleUntil(min(settle, end.timeIntervalSinceNow), done) { return true }
                if (snapshot()?.cycles ?? 0) > before {
                    if workingTrigger != trigger { print("sync trigger: \(trigger.rawValue)") }
                    workingTrigger = trigger
                    break
                }
            }
        }
        return done()
    }

    private func fire(_ trigger: SyncTrigger) -> Bool {
        switch trigger {
        case .signal:
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(syncNowNotification as CFString), nil, nil, true
            )
        case .button:
            let button = app.descendants(matching: .any).matching(identifier: "syncNowProbe").firstMatch
            guard button.exists, button.isHittable else { return false }
            button.tap()
        case .foreground:
            XCUIDevice.shared.press(.home)
            app.activate()
        }
        return true
    }

    /// Polls `done` every half second for `seconds`; true as soon as it holds.
    func settleUntil(_ seconds: TimeInterval, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.5)
            if done() { return true }
        }
        return false
    }

    /// The app's status file (`SyncDebugSession.StatusSnapshot`), rewritten after every cycle. The convergence fields are nil
    /// until the first cycle has finished.
    struct Snapshot {
        var cycles: Int
        var cursor: Int64
        var outbox: Int
        var thoughts: Int?
        var parked: Int?
        var held: Int?
        var digest: String?
        var attention: String?
        var lastError: String?

        var summary: String {
            "cycles \(cycles), cursor \(cursor), outbox \(outbox), thoughts \(thoughts.map(String.init) ?? "?"), "
                + "parked \(parked.map(String.init) ?? "?"), held \(held.map(String.init) ?? "?"), "
                + "digest \(digest.map { String($0.prefix(10)) } ?? "?"), attention \(attention ?? "none"), error \(lastError ?? "none")"
        }
    }

    func status() -> (cycles: Int, cursor: Int64, outbox: Int)? {
        snapshot().map { ($0.cycles, $0.cursor, $0.outbox) }
    }

    /// A file on simulators, and on devices, where the runner can't read the app's container, the accessibility value of the
    /// app's status probe.
    func snapshot() -> Snapshot? {
        let data: Data?
        if coordinator == nil {
            data = FileManager.default.contents(atPath: "\(directory)/status-\(role).json")
        } else {
            let probe = app.descendants(matching: .any).matching(identifier: "syncStatusProbe").firstMatch
            data = probe.exists ? (probe.value as? String).map { Data($0.utf8) } : nil
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cycles = (json["cycles"] as? NSNumber)?.intValue, let cursor = (json["cursor"] as? NSNumber)?.int64Value,
              let outbox = (json["outbox"] as? NSNumber)?.intValue
        else { return nil }
        return Snapshot(
            cycles: cycles, cursor: cursor, outbox: outbox, thoughts: (json["thoughts"] as? NSNumber)?.intValue,
            parked: (json["parked"] as? NSNumber)?.intValue, held: (json["held"] as? NSNumber)?.intValue,
            digest: json["digest"] as? String, attention: json["attention"] as? String, lastError: json["lastError"] as? String
        )
    }

    var listIsShowing: Bool { app.navigationBars["#\(Self.tag)"].exists }

    func thoughtRow(_ name: String) -> XCUIElement {
        app.buttons.containing(.staticText, identifier: name).firstMatch
    }

    func waitForThought(_ name: String) {
        openProbeList()
        XCTAssertTrue(syncUntil { self.thoughtRow(name).exists }, "\(name) should reach this device")
    }

    // MARK: Signals

    func signal(_ name: String, _ value: Int64? = nil) {
        putMarker(name, value.map { Data("\($0)".utf8) })
    }

    func signal(_ name: String, text: String) {
        putMarker(name, Data(text.utf8))
    }

    /// Waits for the other device's marker and returns the number it carries (0 for an empty one).
    @discardableResult
    func waitForSignal(_ name: String, timeout: TimeInterval = 120) -> Int64 {
        waitForMarker(name, timeout: timeout).flatMap { String(data: $0, encoding: .utf8) }.flatMap { Int64($0) } ?? 0
    }

    /// Waits for the other device's marker and returns the text it carries (empty for an empty one).
    @discardableResult
    func waitForSignalText(_ name: String, timeout: TimeInterval = 120) -> String {
        waitForMarker(name, timeout: timeout).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func putMarker(_ name: String, _ body: Data?) {
        guard let coordinator else {
            FileManager.default.createFile(atPath: "\(directory)/\(name)", contents: body)
            return
        }
        var request = URLRequest(url: coordinator.appending(path: scenario).appending(path: name))
        request.httpMethod = "PUT"
        request.httpBody = body ?? Data()
        request.timeoutInterval = 10
        var stored = false
        for _ in 0..<5 where !stored {
            stored = send(request)?.status == 204
            if !stored { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertTrue(stored, "The coordinator didn't take the marker \(name)")
    }

    /// The marker's body (empty if it has none), or nil after `timeout` seconds without the marker.
    private func waitForMarker(_ name: String, timeout: TimeInterval) -> Data? {
        let end = Date().addingTimeInterval(timeout)
        while true {
            if let body = readMarker(name) { return body }
            if Date() > end {
                XCTFail("The other device never signalled \(name)")
                return nil
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    func readMarker(_ name: String) -> Data? {
        guard let coordinator else { return FileManager.default.contents(atPath: "\(directory)/\(name)") }
        var request = URLRequest(url: coordinator.appending(path: scenario).appending(path: name))
        request.timeoutInterval = 5
        guard let answer = send(request), answer.status == 200 else { return nil }
        return answer.body
    }

    func send(_ request: URLRequest) -> (status: Int, body: Data)? {
        var answer: (status: Int, body: Data)?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { answer = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        return answer
    }

    // MARK: Driving the app

    /// The tag's list with "All" selected, reached from the tab bar on an iPhone and the sidebar on an iPad.
    func openProbeList() {
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

    func openSection(_ name: String) {
        if isPad {
            let row = app.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "No sidebar row \(name)")
            row.tap()
        } else {
            app.tabBars.buttons[name].tap()
        }
    }

    /// Taps the thought's row and waits for its detail screen: the interval bar, or the Learn switch that every thought has.
    func openThought(_ name: String, listShowing: Bool = false, learn: Bool = false) {
        if !listShowing { openProbeList() }
        let row = thoughtRow(name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "No row for \(name)")
        row.tap()
        let ready = learn ? app.switches["Learn mode"] : app.buttons["More intervals"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
    }

    func dismissKeyboardPrompt() {
        let slideToType = app.buttons["Continue"]
        if slideToType.waitForExistence(timeout: 2) { slideToType.tap() }
    }

    /// `paragraphs` go between the name and the tag line, as typed text.
    func createThought(_ name: String, paragraphs: String = "", linking target: String? = nil) {
        // A tag's list offers "New thought with this tag" instead, which would prefill a tag.
        if !app.buttons["New thought"].exists { openSection("Timeline") }
        app.buttons["New thought"].tap()
        let field = app.textViews["Thought"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        dismissKeyboardPrompt()
        let typed = "\(name)\n\(paragraphs)#\(Self.tag)"
        field.typeText(typed)
        XCTAssertEqual(fieldText(field), typed, "the new thought should hold exactly the typed text")
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

    func deleteOpenThought() {
        app.buttons["More"].tap()
        app.buttons["Delete"].firstMatch.tap()
        let dialog = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Delete this thought?", "This can't be undone."])).firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "the delete confirmation should appear")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["More intervals"].waitForNonExistence(timeout: 10))
    }

    func scrollTo(_ element: XCUIElement) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
    }

    /// Settings > Sync lab > Run checks: the integrity and search index checks must pass on this device.
    func assertChecksPass() {
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
