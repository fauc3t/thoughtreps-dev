import XCTest

/// Two-device sync scenarios, driven by `scripts/sync-integ.sh` on simulators and `scripts/sync-device-integ.sh` on real
/// devices (see their headers). Each test is one scenario and runs on both devices at once: device A (iPhone) asserts what
/// the user sees, device B (iPad) does the other side's work. They hand over steps through markers: files in `TR_SYNC_DIR`
/// on simulators, which share the host's filesystem, or `PUT`/`GET` on the script's coordinator (`TR_SYNC_COORDINATOR`, the
/// base URL with the run token) on devices. Without the script's variables every test skips, so the scheme stays safe to run
/// on its own. The shared plumbing is in `SyncDeviceTestCase`.
final class SyncScenarioTests: SyncDeviceTestCase {
    private var serverURL = ""
    private var vaultID = ""
    private var secret = ""
    private var key = ""

    /// What the app's DEBUG `SyncTestSeed` names its thoughts and tags (the UI tests can't import the app).
    private enum Seed {
        static let image = "Seed image"
        static let gallery = "Seed gallery"
        static let file = "Seed file"
        static let learn = "Seed learn"
        static let bulkCount = 500
        static let bulkTag = "syncbulk"
    }

    override func identify(environment env: [String: String]) -> String? {
        guard let url = env["TR_SYNC_URL"], let vault = env["TR_SYNC_VAULT"], let secret = env["TR_SYNC_SECRET"],
              let key = env["TR_SYNC_KEY"]
        else { return nil }
        serverURL = url
        vaultID = vault
        self.secret = secret
        self.key = key
        title = "Probe \(vault.suffix(6))"
        return vault
    }

    override func addLaunchEnvironment() {
        app.launchEnvironment = [
            "THOUGHTREPS_SYNC_URL": serverURL, "THOUGHTREPS_SYNC_VAULT": vaultID,
            "THOUGHTREPS_SYNC_DEV_SECRET": secret, "THOUGHTREPS_SYNC_KEY": key,
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
        assertConverged(thoughts: Seed.bulkCount + 1, timeout: 600, settle: 10)
        if !isA {
            openSection("Tags")
            XCTAssertTrue(app.staticTexts["#\(Seed.bulkTag)"].waitForExistence(timeout: 10), "the bulk tag should be here")
        }
        assertChecksPass()
    }

    /// Both devices launch with automatic sync off and in sync on one thought of three paragraphs, and that thought is open on
    /// both. From here they sync only when the test triggers them, so each can edit before the other's change arrives.
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

    /// Replaces the open thought's whole text with `body`. Cmd-A needs a hardware keyboard, so select all comes from the
    /// edit menu; the field is checked afterwards so a bad edit fails here instead of surfacing as a sync mismatch.
    private func rewriteOpenThought(to body: String) {
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit thought"].waitForExistence(timeout: 10))
        let field = app.textViews["Thought"]
        field.tap()
        dismissKeyboardPrompt()
        field.press(forDuration: 1)
        let selectAllItem = app.menuItems["Select All"].firstMatch
        let selectAllButton = app.buttons["Select All"].firstMatch
        if selectAllItem.waitForExistence(timeout: 2) {
            selectAllItem.tap()
        } else if selectAllButton.exists {
            selectAllButton.tap()
        } else {
            app.typeKey("a", modifierFlags: .command)
        }
        app.typeText(body)
        if fieldText(field) != body {
            for _ in 0..<3 where !fieldText(field).isEmpty {
                tapEndOfText(field)
                app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: fieldText(field).count + 5))
            }
            app.typeText(body)
        }
        XCTAssertEqual(fieldText(field), body, "the editor should hold exactly the typed body")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Edit thought"].waitForNonExistence(timeout: 10), "Save should close the editor")
    }

    /// Taps just inside the bottom-right of the field's visible part (above the keyboard), which puts the caret at the end.
    private func tapEndOfText(_ field: XCUIElement) {
        let frame = field.frame
        var bottom = frame.maxY
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: frame.maxX - 4, dy: bottom - 6)).tap()
    }


    /// A menu item in the menu that is open now: the last match, since the sidebar or tab bar can have the same label.
    private func tapMenuItem(_ label: String) {
        let items = app.buttons.matching(identifier: label)
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10), "the menu should offer \(label)")
        items.element(boundBy: items.count - 1).tap()
    }

    /// The server's head seq, asked for directly with the dev secret.
    override func serverHeadSeq() -> Int64 {
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

    private var keptThought: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "kept")).firstMatch
    }

    // MARK: Launching

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
    /// triggers, so this device syncs only when `syncUntil` triggers it (notification, hidden button or foregrounding).
    private func launch(seeding kinds: [String] = [], manualSync: Bool = false, timeout: TimeInterval = 30) {
        if !kinds.isEmpty { app.launchArguments += ["-TRSeedSyncTestData", "\(kinds.joined(separator: ",")):\(vaultID)"] }
        if manualSync { app.launchEnvironment["THOUGHTREPS_SYNC_MANUAL"] = "1" }
        if isA { launchAfterPeer(timeout: timeout) } else { launchAndSignalReady(timeout: timeout) }
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
}
