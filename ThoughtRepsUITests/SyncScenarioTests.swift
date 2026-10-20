import XCTest

/// Two-device sync scenarios, driven by `scripts/sync-integ.sh` on simulators and `scripts/sync-device-integ.sh` on real
/// devices (see their headers). Each test is one scenario and runs on both devices at once: device A (iPhone) asserts what
/// the user sees, device B (iPad) does the other side's work. They hand over steps through markers: files in `TR_SYNC_DIR`
/// on simulators, which share the host's filesystem, or `PUT`/`GET` on the script's coordinator (`TR_SYNC_COORDINATOR`, the
/// base URL with the run token) on devices. Without the script's variables every test skips, so the scheme stays safe to run
/// on its own.
///
/// A device makes the app sync by sending it to the background and back (the app runs a cycle on foreground), so waiting
/// for a state is a loop of that and a check, never a long sleep.
final class SyncScenarioTests: XCTestCase {
    private var app: XCUIApplication!
    private var role = "a"
    private var directory = ""
    private var coordinator: URL?
    private var scenario = ""
    private var title = ""
    private var serverURL = ""
    private var vaultID = ""
    private var secret = ""

    private var isA: Bool { role == "a" }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Every probe thought carries this tag: a new thought isn't due yet, so the only list that shows it is its tag's "All".
    private static let tag = "syncprobe"

    /// What the app's DEBUG `SyncTestSeed` names its thoughts and tags (the UI tests can't import the app).
    private enum Seed {
        static let image = "Seed image"
        static let gallery = "Seed gallery"
        static let file = "Seed file"
        static let learn = "Seed learn"
        static let bulkCount = 500
        static let bulkTag = "syncbulk"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let directory = env["TR_SYNC_DIR"] ?? ""
        let coordinator = env["TR_SYNC_COORDINATOR"].flatMap { URL(string: $0) }
        guard let role = env["TR_SYNC_ROLE"], !directory.isEmpty || coordinator != nil, let url = env["TR_SYNC_URL"],
              let vault = env["TR_SYNC_VAULT"], let secret = env["TR_SYNC_SECRET"], let key = env["TR_SYNC_KEY"]
        else { throw XCTSkip("Run through scripts/sync-integ.sh or scripts/sync-device-integ.sh") }
        self.role = role
        self.directory = directory
        self.coordinator = directory.isEmpty ? coordinator : nil
        scenario = invocation.map { NSStringFromSelector($0.selector).replacingOccurrences(of: "AndReturnError:", with: "") } ?? name
        serverURL = url
        vaultID = vault
        self.secret = secret
        title = "Probe \(vault.suffix(6))"
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-didSeedSampleData", "YES", "-reminderPromptAsked", "YES", "-ratingPromptAsked", "YES",
            "-syncSaveKeyToICloudKeychain", "<false/>",
        ]
        app.launchEnvironment = [
            "THOUGHTREPS_SYNC_URL": url, "THOUGHTREPS_SYNC_VAULT": vault,
            "THOUGHTREPS_SYNC_DEV_SECRET": secret, "THOUGHTREPS_SYNC_KEY": key,
        ]
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

    // MARK: Data scenarios (D1 to D6)

    // A step is `publishStep` on the device that acted (push everything, then tell the peer the digest of its store) and
    // `awaitStep` on the other (sync until its own store has that digest). Every scenario ends with `assertConverged`, so the
    // run passes only if both stores hold the same thoughts, bytes included, and nothing is queued, parked or held.

    /// B creates a thought, A creates one, B edits A's; A adds and removes a tag; A deletes its thought.
    func testD1_content() throws {
        let name = "\(title) content"
        let second = "\(title) content two"
        launch()
        if isA {
            awaitStep("b-created-two")
            waitForThought(second)
            createThought(name)
            publishStep("a-created")
            awaitStep("b-edited")
            openProbeList()
            openThought(name, listShowing: true)
            XCTAssertTrue(text("bedit").waitForExistence(timeout: 10), "B's edit should reach A")
            rewriteOpenThought(to: "\(name)\nbedit line\n#\(Self.tag) #d1tag")
            publishStep("a-tagged")
            waitForSignal("b-saw-tag")
            rewriteOpenThought(to: "\(name)\nbedit line\n#\(Self.tag)")
            publishStep("a-untagged")
            waitForSignal("b-saw-untag")
            deleteOpenThought()
            publishStep("a-deleted")
        } else {
            createThought(second)
            publishStep("b-created-two")
            awaitStep("a-created")
            waitForThought(name)
            openThought(name, listShowing: true)
            rewriteOpenThought(to: "\(name)\nbedit line\n#\(Self.tag)")
            publishStep("b-edited")
            awaitStep("a-tagged")
            openSection("Tags")
            XCTAssertTrue(app.staticTexts["#d1tag"].waitForExistence(timeout: 10), "the tag A added should reach B")
            signal("b-saw-tag")
            awaitStep("a-untagged")
            signal("b-saw-untag")
            awaitStep("a-deleted")
            openProbeList()
            XCTAssertTrue(syncUntil { !self.thoughtRow(name).exists }, "A's delete should reach B")
            XCTAssertTrue(thoughtRow(second).exists)
        }
        assertConverged(thoughts: 1)
        assertChecksPass()
    }

    /// Pin, unpin, interval, snooze, archive, restore, Learn mode and Got it, each made on one device and checked on the other.
    func testD2_stateAndSchedule() throws {
        let name = "\(title) state"
        let learn = Seed.learn
        if isA {
            launch()
            awaitStep("b-ready")
            waitForThought(learn)
            createThought(name)
            publishStep("a-created")
            awaitStep("b-pinned")
            openProbeList()
            openThought(name, listShowing: true)
            XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 10), "the thought should be pinned here too")
            app.buttons["Unpin"].tap()
            publishStep("a-unpinned")
            awaitStep("b-interval")
            XCTAssertTrue(syncUntil { self.app.buttons["3 days"].isSelected }, "the 3 day interval should show here")
            app.buttons["More"].tap()
            tapMenuItem("Snooze a week")
            publishStep("a-snoozed")
            awaitStep("b-archived")
            XCTAssertTrue(syncUntil { !self.thoughtRow(name).exists }, "the archived thought should leave the list here")
            openSection("Archive")
            let row = thoughtRow(name)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the archived thought should be in the archive here")
            row.tap()
            app.buttons["More"].tap()
            tapMenuItem("Restore")
            publishStep("a-restored")
            awaitStep("b-learn")
            openProbeList()
            openThought(learn, listShowing: true, learn: true)
            let gotIt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Got it")).firstMatch
            XCTAssertTrue(gotIt.waitForExistence(timeout: 10), "a due Learn thought should offer Got it")
            gotIt.tap()
            publishStep("a-gotit")
        } else {
            launch(seeding: ["learn"])
            publishStep("b-ready")
            awaitStep("a-created")
            waitForThought(name)
            openThought(name, listShowing: true)
            app.buttons["Pin"].tap()
            publishStep("b-pinned")
            awaitStep("a-unpinned")
            XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 10), "the unpin should show on the open thought here")
            app.buttons["3 days"].tap()
            publishStep("b-interval")
            awaitStep("a-snoozed")
            app.buttons["More"].tap()
            tapMenuItem("Archive")
            publishStep("b-archived")
            awaitStep("a-restored")
            openProbeList()
            XCTAssertTrue(syncUntil { self.thoughtRow(name).exists }, "the restored thought should be back in the list here")
            openThought(name, listShowing: true)
            app.switches["Learn mode"].tap()
            publishStep("b-learn")
            awaitStep("a-gotit")
        }
        assertConverged(thoughts: 2)
        assertChecksPass()
    }

    /// An inline image, a gallery and a file block, seeded on one device or the other, arrive with the same bytes.
    func testD3_imagesAndFiles() throws {
        launch(seeding: isA ? ["image", "gallery"] : ["file"])
        for kind in [Seed.image, Seed.gallery, Seed.file] { waitForThought(kind) }
        if isA {
            openThought(Seed.file, listShowing: true)
            let file = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "File: seed-notes.txt")).firstMatch
            XCTAssertTrue(file.waitForExistence(timeout: 10), "the file block should show here")
            publishStep("a-opened-file")
            awaitStep("b-opened-gallery")
        } else {
            awaitStep("a-opened-file")
            openProbeList()
            openThought(Seed.gallery, listShowing: true)
            let last = app.descendants(matching: .any)["Gallery image 3 of 3"]
            XCTAssertTrue(last.waitForExistence(timeout: 10), "all three gallery images should show here")
            publishStep("b-opened-gallery")
        }
        assertConverged(thoughts: 3)
        assertChecksPass()
    }

    /// B creates a thought and one linking to it; A opens the link card; B deletes the target and the card dangles on both.
    func testD4_links() throws {
        let target = "\(title) linktarget"
        let source = "\(title) linksource"
        let dangling = app.descendants(matching: .any)["Linked thought: deleted"]
        launch()
        if isA {
            awaitStep("b-created")
            waitForThought(source)
            openThought(source, listShowing: true)
            let card = app.buttons["Linked thought: \(target)"]
            XCTAssertTrue(card.waitForExistence(timeout: 10), "the link card should show here")
            card.tap()
            XCTAssertTrue(app.staticTexts[target].waitForExistence(timeout: 10), "the card should open its target")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            publishStep("a-walked")
            awaitStep("b-deleted-target")
            XCTAssertTrue(dangling.waitForExistence(timeout: 30), "the link should dangle here once the target is gone")
            publishStep("a-checked")
            awaitStep("b-checked")
        } else {
            createThought(target)
            createThought(source, linking: target)
            publishStep("b-created")
            awaitStep("a-walked")
            openThought(target)
            deleteOpenThought()
            publishStep("b-deleted-target")
            awaitStep("a-checked")
            openThought(source, listShowing: listIsShowing)
            XCTAssertTrue(dangling.waitForExistence(timeout: 10), "the link should dangle here")
            publishStep("b-checked")
        }
        assertConverged(thoughts: 1)
        assertChecksPass()
    }

    private static let twoParagraphs = "\nfirst paragraph\n\nsecond paragraph\n"

    /// The body `createThought(_:paragraphs: twoParagraphs)` types, with the title and the two paragraphs changeable.
    private func mergeBody(_ title: String, first: String, second: String) -> String {
        "\(title)\n\n\(first)\n\n\(second)\n#\(Self.tag)"
    }

    /// Both devices edit different lines of the same thought before either syncs: both edits survive, no copy.
    func testD5_cleanMerge() throws {
        let name = "\(title) merge"
        launchBothOffline(creating: name)
        if isA {
            rewriteOpenThought(to: mergeBody(name, first: "first paragraph", second: "second paragraph A-end"))
            signal("a-edited")
            waitForSignal("b-edited")
            pushAll()
            signal("a-pushed")
            awaitStep("b-merged")
        } else {
            rewriteOpenThought(to: mergeBody("B-start \(name)", first: "first paragraph", second: "second paragraph"))
            signal("b-edited")
            waitForSignal("a-pushed")
            publishStep("b-merged")
        }
        openProbeList()
        let merged = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(merged.waitForExistence(timeout: 10))
        merged.tap()
        XCTAssertTrue(text("B-start").waitForExistence(timeout: 10) && text("A-end").exists, "both edits should survive the merge")
        assertConverged(thoughts: 1)
        assertChecksPass()
    }

    /// Both devices edit the same line before either syncs: the edit that loses is kept as a conflict copy on both.
    func testD5_overlappingEdit() throws {
        let name = "\(title) overlap"
        launchBothOffline(creating: name)
        if isA {
            rewriteOpenThought(to: mergeBody(name, first: "first paragraph A-tail", second: "second paragraph"))
            signal("a-edited")
            waitForSignal("b-edited")
            pushAll()
            signal("a-pushed")
            awaitStep("b-merged")
        } else {
            rewriteOpenThought(to: mergeBody(name, first: "first paragraph B-tail", second: "second paragraph"))
            signal("b-edited")
            waitForSignal("a-pushed")
            publishStep("b-merged")
        }
        openSection("Timeline")
        XCTAssertTrue(syncUntil { self.app.staticTexts["Needs a look"].exists }, "the conflict copy should be listed under Needs a look")
        assertConverged(thoughts: 2)
        assertChecksPass()
    }

    /// B deletes, then A edits (later), then both sync: the edit came after the delete, so the thought comes back on both.
    func testD5_editAfterDeleteKeepsTheThought() throws {
        let name = "\(title) editlater"
        launchBothOffline(creating: name)
        if isA {
            waitForSignal("b-deleted")
            rewriteOpenThought(to: mergeBody(name, first: "first paragraph", second: "second paragraph late"))
            signal("a-edited")
            waitForSignal("b-pushed")
            publishStep("a-synced")
        } else {
            deleteOpenThought()
            signal("b-deleted")
            waitForSignal("a-edited")
            pushAll()
            signal("b-pushed")
            awaitStep("a-synced")
        }
        openProbeList()
        XCTAssertTrue(syncUntil { self.thoughtRow(name).exists }, "the thought should be back here")
        assertConverged(thoughts: 1)
        assertChecksPass()
    }

    /// A edits, then B deletes (later), then both sync: the delete came after the edit, so the thought is gone on both.
    func testD5_deleteAfterEditRemovesTheThought() throws {
        let name = "\(title) deletelater"
        launchBothOffline(creating: name)
        if isA {
            rewriteOpenThought(to: mergeBody(name, first: "first paragraph", second: "second paragraph early"))
            signal("a-edited")
            waitForSignal("b-deleted")
            pushAll()
            signal("a-pushed")
            awaitStep("b-synced")
        } else {
            waitForSignal("a-edited")
            deleteOpenThought()
            signal("b-deleted")
            waitForSignal("a-pushed")
            publishStep("b-synced")
        }
        openProbeList()
        XCTAssertTrue(syncUntil { !self.thoughtRow(name).exists }, "the thought should be gone here")
        assertConverged(thoughts: 0)
        assertChecksPass()
    }

    /// A seeds 500 thoughts and one whose record is over 64 KiB; B ends with all 501, bytes of the big one included.
    func testD6_volume() throws {
        launch(seeding: isA ? ["bulk", "large"] : [], timeout: 180)
        assertConverged(thoughts: Seed.bulkCount + 1, timeout: 600, pause: 3)
        if !isA {
            openSection("Tags")
            XCTAssertTrue(app.staticTexts["#\(Seed.bulkTag)"].waitForExistence(timeout: 10), "the bulk tag should be here")
        }
        assertChecksPass()
    }

    /// Both devices launch with automatic sync off and in sync on one thought of three paragraphs, and that thought is open on
    /// both. From here they sync only when the test foregrounds them, so each can edit before the other's change arrives.
    private func launchBothOffline(creating name: String) {
        launch(manualSync: true)
        if isA {
            createThought(name, paragraphs: Self.twoParagraphs)
            publishStep("a-created")
        } else {
            awaitStep("a-created")
        }
        waitForThought(name)
        openThought(name, listShowing: true)
    }

    // MARK: Steps and convergence

    /// Syncs until every local change is pushed and a cycle has run since.
    private func pushAll(timeout: TimeInterval = 90, pause: TimeInterval = 0.5) {
        let before = snapshot()?.cycles ?? 0
        XCTAssertTrue(syncUntil(timeout: timeout, pause: pause) { (self.snapshot().map { $0.cycles >= before + 2 && $0.outbox == 0 }) ?? false },
                      "this device's changes should be pushed: \(snapshot()?.summary ?? "no status")")
    }

    /// Pushes everything, then tells the peer the digest of this device's store.
    private func publishStep(_ step: String, timeout: TimeInterval = 90, pause: TimeInterval = 0.5) {
        pushAll(timeout: timeout, pause: pause)
        guard let digest = snapshot()?.digest else {
            XCTFail("The status has no digest to publish for \(step)")
            return
        }
        signal(step, text: digest)
    }

    /// Waits for the peer's step and syncs until this device's store has the digest it published.
    private func awaitStep(_ step: String, timeout: TimeInterval = 120, pause: TimeInterval = 0.5) {
        let expected = waitForSignalText(step)
        XCTAssertTrue(syncUntil(timeout: timeout, pause: pause) { (self.snapshot().map { $0.outbox == 0 && $0.digest == expected }) ?? false },
                      "this device should reach the state of \(step): \(snapshot()?.summary ?? "no status")")
    }

    /// Both devices end with the same thought count and digest, an empty outbox, nothing parked or held, no stop reason, and a
    /// cursor at the server's head. Each publishes its own and compares with the peer's.
    private func assertConverged(thoughts expected: Int, timeout: TimeInterval = 180, pause: TimeInterval = 0.5) {
        let peer = isA ? "b" : "a"
        var last: Snapshot?
        let converged = syncUntil(timeout: timeout, pause: pause) {
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

    /// Opens the Edit screen of the open thought, selects all of its text and types `body` over it. Retyping the lines that
    /// stay the same leaves them unchanged, and the caret never has to be placed.
    private func rewriteOpenThought(to body: String) {
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit thought"].waitForExistence(timeout: 10))
        app.textViews["Thought"].tap()
        dismissKeyboardPrompt()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(body)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit thought"].waitForNonExistence(timeout: 10), "Save should close the editor")
    }

    /// A menu item in the menu that is open now: the last match, since the sidebar or tab bar can have the same label.
    private func tapMenuItem(_ label: String) {
        let items = app.buttons.matching(identifier: label)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10), "the menu should offer \(label)")
        items.element(boundBy: items.count - 1).tap()
    }

    private func text(_ part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch
    }

    // MARK: Waiting for a state

    /// Syncs by foregrounding the app until `done` holds; false after `timeout` seconds.
    private func syncUntil(timeout: TimeInterval = 60, pause: TimeInterval = 0.5, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            XCUIDevice.shared.press(.home)
            app.activate()
            Thread.sleep(forTimeInterval: pause)
            if done() { return true }
        }
        return done()
    }

    /// The app's status file (`SyncDebugSession.StatusSnapshot`), rewritten after every cycle. The convergence fields are nil
    /// until the first cycle has finished.
    private struct Snapshot {
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

    private func status() -> (cycles: Int, cursor: Int64, outbox: Int)? {
        snapshot().map { ($0.cycles, $0.cursor, $0.outbox) }
    }

    /// A file on simulators, and on devices, where the runner can't read the app's container, the accessibility value of the
    /// app's status probe.
    private func snapshot() -> Snapshot? {
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

    private func launchAndSignalReady(timeout: TimeInterval = 30) {
        app.launch()
        XCTAssertTrue(app.buttons["New thought"].waitForExistence(timeout: timeout))
        signal("b-launched")
    }

    private func launchAfterPeer(timeout: TimeInterval = 30) {
        waitForSignal("b-launched")
        app.launch()
        XCTAssertTrue(app.buttons["New thought"].waitForExistence(timeout: timeout))
    }

    /// B launches first, then A; both launches may seed thoughts (`SyncTestSeed`) and may turn off the engine's automatic
    /// triggers, so this device syncs only when `syncUntil` foregrounds it.
    private func launch(seeding kinds: [String] = [], manualSync: Bool = false, timeout: TimeInterval = 30) {
        if !kinds.isEmpty { app.launchArguments += ["-TRSeedSyncTestData", "\(kinds.joined(separator: ",")):\(vaultID)"] }
        if manualSync { app.launchEnvironment["THOUGHTREPS_SYNC_MANUAL"] = "1" }
        if isA { launchAfterPeer(timeout: timeout) } else { launchAndSignalReady(timeout: timeout) }
    }

    private func signal(_ name: String, _ value: Int64? = nil) {
        putMarker(name, value.map { Data("\($0)".utf8) })
    }

    private func signal(_ name: String, text: String) {
        putMarker(name, Data(text.utf8))
    }

    /// Waits for the other device's marker and returns the number it carries (0 for an empty one).
    @discardableResult
    private func waitForSignal(_ name: String, timeout: TimeInterval = 120) -> Int64 {
        waitForMarker(name, timeout: timeout).flatMap { String(data: $0, encoding: .utf8) }.flatMap { Int64($0) } ?? 0
    }

    /// Waits for the other device's marker and returns the text it carries (empty for an empty one).
    @discardableResult
    private func waitForSignalText(_ name: String, timeout: TimeInterval = 120) -> String {
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

    private func readMarker(_ name: String) -> Data? {
        guard let coordinator else { return FileManager.default.contents(atPath: "\(directory)/\(name)") }
        var request = URLRequest(url: coordinator.appending(path: scenario).appending(path: name))
        request.timeoutInterval = 5
        guard let answer = send(request), answer.status == 200 else { return nil }
        return answer.body
    }

    private func send(_ request: URLRequest) -> (status: Int, body: Data)? {
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

    /// Taps the thought's row and waits for its detail screen: the interval bar, or the Learn switch that every thought has.
    private func openThought(_ name: String, listShowing: Bool = false, learn: Bool = false) {
        if !listShowing { openProbeList() }
        let row = thoughtRow(name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "No row for \(name)")
        row.tap()
        let ready = learn ? app.switches["Learn mode"] : app.buttons["More intervals"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
    }

    private func dismissKeyboardPrompt() {
        let slideToType = app.buttons["Continue"]
        if slideToType.waitForExistence(timeout: 2) { slideToType.tap() }
    }

    /// `paragraphs` go between the name and the tag line, as typed text.
    private func createThought(_ name: String, paragraphs: String = "", linking target: String? = nil) {
        // A tag's list offers "New thought with this tag" instead, which would prefill a tag.
        if !app.buttons["New thought"].exists { openSection("Timeline") }
        app.buttons["New thought"].tap()
        let field = app.textViews["Thought"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        dismissKeyboardPrompt()
        field.typeText("\(name)\n\(paragraphs)#\(Self.tag)")
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

    private func deleteOpenThought() {
        app.buttons["More"].tap()
        app.buttons["Delete"].firstMatch.tap()
        let dialog = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Delete this thought?", "This can't be undone."])).firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "the delete confirmation should appear")
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["More intervals"].waitForNonExistence(timeout: 10))
    }

    /// Deletes the open thought, waits until this device has pushed the delete, then tells the other device the server's
    /// head seq at that point: once it has pulled that far it has the delete.
    private func deleteOpenThoughtAndPublishHead() {
        deleteOpenThought()
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
