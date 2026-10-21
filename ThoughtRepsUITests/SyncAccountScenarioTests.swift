import XCTest

/// Account scenarios (A1 to A6) on a real iPhone (A) and iPad (B), run in order by `scripts/sync-device-integ.sh account`:
/// sign in with Apple and create a vault, join by invite and by recovery code, the device list, leaving and erasing, a
/// reinstall, and deleting the sync data. They carry state from one method to the next (nothing resets between them), so a
/// failure skips the rest. Unlike the data scenarios there is no dev vault or secret: the app signs in for real, and only A
/// does (the script prints a prompt when the Sign in with Apple sheet needs a tap). Invites and recovery codes travel through
/// markers named `invite*` and `recovery*`, which the coordinator keeps out of its logs; never print them.
final class SyncAccountScenarioTests: SyncDeviceTestCase {
    nonisolated(unsafe) private static var earlierFailure = false

    /// The Sync lab's accessibility ids (`SyncLabID`; the UI tests can't import the app).
    private enum ID {
        static let inviteQR = "syncInviteQR"
        static let accountVault = "syncAccountVault"
        static let signIn = "syncSignIn"
        static let recoveryCodeText = "syncRecoveryCodeText"
        static let showRecoveryCode = "syncShowRecoveryCode"
        static let recoveryCodeField = "syncRecoveryCodeField"
        static let recoveryCodeJoin = "syncRecoveryCodeJoin"
        static let inviteTextField = "syncInviteTextField"
        static let inviteTextJoin = "syncInviteTextJoin"
        static let addDevice = "syncAddDevice"
        static let joinConfirm = "syncJoinConfirm"
        static let joinMerge = "syncJoinMerge"
        static let joinErase = "syncJoinErase"
        static let joinEraseConfirm = "syncJoinEraseConfirm"
        static let deviceName = "syncDeviceName"
        static let deviceThisMarker = "syncDeviceThisMarker"
        static let deviceRename = "syncDeviceRename"
        static let renameField = "syncRenameField"
        static let renameSave = "syncRenameSave"
        static let deviceRemove = "syncDeviceRemove"
        static let removeConfirm = "syncRemoveConfirm"
        static let leave = "syncLeave"
        static let leaveConfirm = "syncLeaveConfirm"
        static let eraseAndLeave = "syncEraseAndLeave"
        static let eraseAndLeaveContinue = "syncEraseAndLeaveContinue"
        static let eraseAndLeaveConfirm = "syncEraseAndLeaveConfirm"
        static let deleteData = "syncDeleteData"
        static let deleteDataConfirm = "syncDeleteDataConfirm"
        static let forget = "syncForget"
        static let resumePrompt = "syncResumePrompt"
        static let resume = "syncResume"
        static let engineAttention = "syncEngineAttention"
        static let accountMessage = "syncAccountMessage"
    }

    /// A person can take a while to approve Sign in with Apple, and the other device's steps each take a minute or two.
    private static let signInWait: TimeInterval = 180
    private static let peerWait: TimeInterval = 300

    private var aSeed: String { "\(title) from A" }
    private var bSeed: String { "\(title) from B" }
    private var aAfter: String { "\(title) A after" }
    private var bLocal: String { "\(title) B local" }
    private var aWhile: String { "\(title) A while" }

    override func identify(environment env: [String: String]) -> String? {
        guard let token = env["TR_SYNC_COORDINATOR"].flatMap({ URL(string: $0)?.lastPathComponent }), !token.isEmpty else { return nil }
        title = "Acct \(token.suffix(6))"
        return token
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if Self.earlierFailure { throw XCTSkip("An earlier account scenario failed, so the state this one needs isn't there") }
    }

    override func tearDown() {
        if let run = testRun, run.totalFailureCount > 0 { Self.earlierFailure = true }
        super.tearDown()
    }

    // MARK: Scenarios

    /// Both devices seed a thought; A signs in with Apple and creates the vault, shows an invite, and B joins with it and
    /// merges. Both end with both thoughts.
    func testA1_createAndInviteJoinMerge() throws {
        launchApp()
        if isA {
            createThought(aSeed)
            let vault = signInAndCreateVault()
            signal("account-vault", text: vault)
            offerInvite(1)
        } else {
            createThought(bSeed)
            let vault = waitForSignalText("account-vault", timeout: Self.peerWait)
            join(withInvite: waitForSignalText("invite-1", timeout: Self.peerWait), choice: .merge)
            XCTAssertEqual(value(ID.accountVault), vault, "B should join A's vault")
            signal("b-joined-1")
        }
        closeSyncLab()
        waitForThought(isA ? bSeed : aSeed)
        assertConverged(thoughts: 2)
        assertChecksPass()
    }

    /// B leaves sync and keeps its thoughts, then writes one more while out; A writes one too. B rejoins with A's recovery
    /// code and erases first: the thought it wrote while out is gone for good, and it ends with exactly A's set.
    func testA2_recoveryCodeJoinErase() throws {
        launchApp()
        if isA {
            waitForSignal("b-left", timeout: Self.peerWait)
            createThought(aAfter)
            pushAll()
            let code = showRecoveryCode()
            signal("recovery-1", text: code)
            waitForSignal("b-joined", timeout: Self.peerWait)
            closeSyncLab()
        } else {
            leave(erase: false)
            closeSyncLab()
            assertThoughtsKept([aSeed, bSeed])
            createThought(bLocal)
            signal("b-left")
            join(withRecoveryCode: waitForSignalText("recovery-1", timeout: Self.peerWait), choice: .erase)
            signal("b-joined")
            closeSyncLab()
            waitForThought(aAfter)
            XCTAssertFalse(thoughtRow(bLocal).exists, "the thought B wrote while out should be gone after the erase")
        }
        assertConverged(thoughts: 3)
        assertChecksPass()
    }

    /// Both list two devices; A renames itself and B sees the new name; A removes B and B's engine reports that the server
    /// refused it.
    func testA3_devices() throws {
        let renamed = "Renamed \(runID.suffix(6))"
        launchApp()
        openSyncLab()
        _ = waitForDevices(count: 2)
        if isA {
            rename(to: renamed)
            signal("renamed")
            waitForSignal("b-saw-rename", timeout: Self.peerWait)
            tapLab(ID.deviceRemove)
            tapDialogButton(ID.removeConfirm, label: "Remove")
            _ = waitForDevices(count: 1)
            signal("removed")
        } else {
            waitForSignal("renamed", timeout: Self.peerWait)
            XCTAssertTrue(waitForDeviceName(renamed), "B should list A's new name")
            signal("b-saw-rename")
            waitForSignal("removed", timeout: Self.peerWait)
            XCTAssertTrue(syncUntil(timeout: 240) { self.snapshot()?.attention?.hasPrefix("Server refused") ?? false },
                          "the engine should report that the server refused this device: \(snapshot()?.summary ?? "no status")")
            reopenSyncLab()
            XCTAssertTrue(value(ID.engineAttention).hasPrefix("Server refused"), "the Sync lab should show the refusal")
        }
    }

    /// B forgets its key and rejoins with a fresh invite, leaves keeping its thoughts and rejoins, then erases and leaves
    /// (no thoughts left) while A keeps writing and syncing, and rejoins empty: it gets all of A's set back.
    func testA4_leaveAndEraseAndLeave() throws {
        launchApp()
        if isA {
            waitForSignal("b-forgot", timeout: Self.peerWait)
            offerInvite(1)
            waitForSignal("b-left-kept", timeout: Self.peerWait)
            offerInvite(2)
            waitForSignal("b-erased", timeout: Self.peerWait)
            createThought(aWhile)
            pushAll()
            XCTAssertNil(snapshot()?.attention, "A should keep syncing while B is out")
            offerInvite(3)
        } else {
            openSyncLab()
            tapLab(ID.forget)
            waitSignedOut()
            signal("b-forgot")
            join(withInvite: waitForSignalText("invite-1", timeout: Self.peerWait), choice: .merge)
            signal("b-joined-1")

            leave(erase: false)
            closeSyncLab()
            assertThoughtsKept([aSeed, bSeed, aAfter])
            signal("b-left-kept")
            join(withInvite: waitForSignalText("invite-2", timeout: Self.peerWait), choice: .merge)
            signal("b-joined-2")

            leave(erase: true)
            closeSyncLab()
            assertThoughtsGone([aSeed, bSeed, aAfter])
            signal("b-erased")
            join(withInvite: waitForSignalText("invite-3", timeout: Self.peerWait), choice: .merge)
            signal("b-joined-3")
        }
        closeSyncLab()
        waitForThought(aWhile)
        assertConverged(thoughts: 4)
        assertChecksPass()
    }

    /// Runs after the script reinstalls the app on B with its Keychain item kept: B has no thoughts and no sync history, so
    /// it asks before resuming, and Resume brings A's set back. If the Keychain item didn't survive, B rejoins with a
    /// recovery code so the next scenario still has two devices, and both skip.
    func testA5_reinstallResume() throws {
        launchApp()
        var outcome = "resumed"
        if isA {
            outcome = waitForSignalText("b-outcome", timeout: Self.peerWait)
            if outcome == "skipped" {
                signal("recovery-a5", text: showRecoveryCode())
                waitForSignal("b-joined", timeout: Self.peerWait)
                closeSyncLab()
            }
        } else {
            openSyncLab()
            let prompt = element(ID.resumePrompt)
            let vault = element(ID.accountVault)
            if waitUntil(90, { prompt.exists || vault.exists }) {
                if prompt.exists { tapLab(ID.resume) }
                XCTAssertTrue(waitUntil(30) { !prompt.exists && vault.exists }, "Resume should start syncing: \(accountMessage())")
                signal("b-outcome", text: "resumed")
            } else {
                XCTAssertTrue(reveal(ID.signIn).exists && reveal(ID.recoveryCodeField).exists,
                              "B should show the signed-out Sync lab before A5 is skipped: \(accountMessage())")
                outcome = "skipped"
                signal("b-outcome", text: outcome)
                join(withRecoveryCode: waitForSignalText("recovery-a5", timeout: Self.peerWait), choice: .merge)
                signal("b-joined")
            }
            closeSyncLab()
            waitForThought(aSeed)
        }
        assertConverged(thoughts: 4)
        assertChecksPass()
        if outcome == "skipped" { throw XCTSkip("Keychain item didn't survive reinstall") }
    }

    /// A deletes the sync data (a second Sign in with Apple sheet may need a tap); B signs out and forgets its key. Both end
    /// signed out with all their thoughts.
    func testA6_deleteSyncData() throws {
        let everything = [aSeed, bSeed, aAfter, aWhile]
        launchApp()
        if isA {
            openSyncLab()
            tapLab(ID.deleteData)
            tapDialogButton(ID.deleteDataConfirm, label: "Delete sync data")
            signal("action-siwa-a-maybe")
            waitSignedOut(timeout: Self.signInWait)
            XCTAssertEqual(accountMessage(), "Sync data deleted. This device keeps its thoughts.")
            signal("a-deleted")
        } else {
            waitForSignal("a-deleted", timeout: Self.signInWait + Self.peerWait)
            openSyncLab()
            tapLab(ID.forget)
            waitSignedOut()
        }
        closeSyncLab()
        assertThoughtsKept(everything)
        assertChecksPass()
    }

    // MARK: Account steps

    private func launchApp() {
        app.launch()
        XCTAssertTrue(app.buttons["New thought"].waitForExistence(timeout: 30))
    }

    /// Taps sign in, tells the script to prompt for the Sign in with Apple sheet, and waits for the vault. Returns its id.
    /// Only a vault this run just created is returned: an account that already had one would be deleted by the cleanup.
    private func signInAndCreateVault() -> String {
        openSyncLab()
        tapLab(ID.signIn)
        signal("action-siwa-a")
        let vault = element(ID.accountVault)
        let failures = ["Sign in cancelled", "Sign in failed", "This account already has a vault", "This device belongs"]
        XCTAssertTrue(waitUntil(Self.signInWait) {
            let message = self.accountMessage()
            return vault.exists || failures.contains { message.hasPrefix($0) }
        }, "Sign in with Apple wasn't approved in time")
        XCTAssertTrue(vault.exists, "Sign in didn't create a vault: \(accountMessage())")
        XCTAssertEqual(accountMessage(), "Vault created.", "This Apple ID already had a vault; the test needs a fresh account")
        let id = value(ID.accountVault)
        XCTAssertFalse(id.isEmpty, "the vault id should show")
        print("account vault: \(id)")
        return id
    }

    /// A: opens "Add a device", hands the invite to B, waits for B to join and closes the sheet.
    private func offerInvite(_ number: Int) {
        openSyncLab()
        tapLab(ID.addDevice)
        let qr = element(ID.inviteQR)
        XCTAssertTrue(qr.waitForExistence(timeout: 30), "the invite should show")
        let payload = qr.value as? String ?? ""
        XCTAssertTrue(payload.hasPrefix("thoughtreps-pair:v1:"), "the invite's value should be the pairing payload")
        signal("invite-\(number)", text: payload)
        waitForSignal("b-joined-\(number)", timeout: Self.peerWait)
        app.navigationBars["Add a device"].buttons["Done"].tap()
        closeSyncLab()
    }

    private func showRecoveryCode() -> String {
        openSyncLab()
        tapLab(ID.showRecoveryCode)
        let code = element(ID.recoveryCodeText)
        XCTAssertTrue(code.waitForExistence(timeout: 10), "the recovery code should show")
        let text = code.value as? String ?? ""
        XCTAssertFalse(text.isEmpty, "the recovery code should have a value")
        return text
    }

    private enum JoinChoice { case merge, erase }

    private func join(withInvite invite: String, choice: JoinChoice) {
        openSyncLab()
        let field = reveal(ID.inviteTextField)
        field.tap()
        dismissKeyboardPrompt()
        field.typeText(invite)
        XCTAssertTrue(fieldText(field) == invite, "the invite should be typed in full")
        tapLab(ID.inviteTextJoin)
        finishJoin(choice)
    }

    private func join(withRecoveryCode code: String, choice: JoinChoice) {
        openSyncLab()
        let field = reveal(ID.recoveryCodeField)
        field.tap()
        dismissKeyboardPrompt()
        field.typeText(code)
        tapLab(ID.recoveryCodeJoin)
        finishJoin(choice)
    }

    /// Confirms the join, answers the merge or erase question if this device has thoughts, and waits until it has joined.
    private func finishJoin(_ choice: JoinChoice) {
        tapDialogButton(ID.joinConfirm, label: "Join")
        let vault = element(ID.accountVault)
        let end = Date().addingTimeInterval(60)
        asking: while Date() < end {
            if let merge = dialogButton(ID.joinMerge, label: "Merge") {
                switch choice {
                case .merge:
                    merge.tap()
                case .erase:
                    tapDialogButton(ID.joinErase, label: "Erase")
                    tapDialogButton(ID.joinEraseConfirm, label: "Erase")
                }
                break asking
            }
            if vault.exists { break asking }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(vault.waitForExistence(timeout: 90), "Joining should finish: \(accountMessage())")
    }

    private func leave(erase: Bool) {
        openSyncLab()
        if erase {
            tapLab(ID.eraseAndLeave)
            tapDialogButton(ID.eraseAndLeaveContinue, label: "Continue")
            tapDialogButton(ID.eraseAndLeaveConfirm, label: "Erase")
        } else {
            tapLab(ID.leave)
            tapDialogButton(ID.leaveConfirm, label: "Leave sync")
        }
        waitSignedOut()
    }

    private func waitSignedOut(timeout: TimeInterval = 90) {
        let signIn = reveal(ID.signIn, timeout: timeout)
        XCTAssertTrue(signIn.exists, "This device should be signed out: \(accountMessage())")
    }

    private func assertThoughtsKept(_ names: [String]) {
        openProbeList()
        for name in names { XCTAssertTrue(thoughtRow(name).waitForExistence(timeout: 10), "\(name) should still be on this device") }
    }

    private func assertThoughtsGone(_ names: [String]) {
        openSection("Tags")
        let tag = app.staticTexts["#\(Self.tag)"].firstMatch
        guard tag.waitForExistence(timeout: 3) else { return }
        tag.tap()
        let all = app.buttons["All"]
        if all.waitForExistence(timeout: 3) { all.tap() }
        for name in names { XCTAssertFalse(thoughtRow(name).exists, "\(name) should be gone from this device") }
    }

    // MARK: Devices

    private func deviceNames() -> [String] {
        app.staticTexts.matching(identifier: ID.deviceName).allElementsBoundByIndex.map { $0.label }
    }

    /// The lab loads the list when it opens, so waiting means closing and opening it again.
    private func waitForDevices(count: Int, timeout: TimeInterval = 90) -> [String] {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            _ = reveal(ID.deviceThisMarker, timeout: 15)
            let names = deviceNames()
            if names.count == count { return names }
            Thread.sleep(forTimeInterval: 3)
            reopenSyncLab()
        }
        XCTFail("The device list should show \(count) device(s), not \(deviceNames().count)")
        return []
    }

    private func waitForDeviceName(_ name: String, timeout: TimeInterval = 90) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            _ = reveal(ID.deviceThisMarker, timeout: 15)
            if deviceNames().contains(name) { return true }
            Thread.sleep(forTimeInterval: 3)
            reopenSyncLab()
        }
        return false
    }

    private func rename(to name: String) {
        tapLab(ID.deviceRename)
        let field = element(ID.renameField)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the rename dialog should show")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        dismissKeyboardPrompt()
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: fieldText(field).count + 3))
        app.typeText(name)
        XCTAssertEqual(fieldText(field), name, "the rename field should hold exactly the new name")
        tapDialogButton(ID.renameSave, label: "Rename")
        XCTAssertTrue(waitUntil(30) { self.deviceNames().contains(name) }, "the device list should show the new name")
    }

    // MARK: The Sync lab

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func value(_ id: String) -> String {
        element(id).value as? String ?? ""
    }

    private func accountMessage() -> String {
        let message = element(ID.accountMessage)
        return message.exists ? message.label : ""
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }

    /// Settings > Sync lab, from wherever the app is. A no-op if the lab is already showing.
    private func openSyncLab() {
        if app.navigationBars["Sync lab"].exists { return }
        if !app.navigationBars["Settings"].exists {
            if !app.buttons["Settings"].exists { openSection("Timeline") }
            app.buttons["Settings"].tap()
        }
        tapLab("Sync lab", asButton: true)
        XCTAssertTrue(app.navigationBars["Sync lab"].waitForExistence(timeout: 10))
    }

    private func reopenSyncLab() {
        let lab = app.navigationBars["Sync lab"]
        if lab.exists { lab.buttons.element(boundBy: 0).tap() }
        openSyncLab()
    }

    private func closeSyncLab() {
        let lab = app.navigationBars["Sync lab"]
        let wasOpen = lab.exists
        if wasOpen { lab.buttons.element(boundBy: 0).tap() }
        let settings = app.navigationBars["Settings"]
        if wasOpen ? settings.waitForExistence(timeout: 5) : settings.exists {
            settings.buttons["Done"].tap()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 10), "Settings should close")
        }
    }

    /// Scrolls the lab until the element is on screen and hittable, trying down first and then back up; the rows below the
    /// screen aren't in the hierarchy until they are scrolled to. Returns it either way, so callers check `exists`.
    private func reveal(_ id: String, timeout: TimeInterval = 20, asButton: Bool = false) -> XCUIElement {
        let target = asButton ? app.buttons[id] : element(id)
        let end = Date().addingTimeInterval(timeout)
        var swipes = 0
        var down = true
        while Date() < end {
            if target.exists && target.isHittable { return target }
            if swipes >= 6 {
                down.toggle()
                swipes = 0
            }
            if down { app.swipeUp() } else { app.swipeDown() }
            swipes += 1
            Thread.sleep(forTimeInterval: 0.3)
        }
        return target
    }

    private func tapLab(_ id: String, asButton: Bool = false) {
        let target = reveal(id, asButton: asButton)
        XCTAssertTrue(target.exists && target.isHittable, "No \(id) in the Sync lab: \(accountMessage())")
        target.tap()
    }

    // MARK: Dialogs

    /// An alert or dialog button, by id or else by the start of its label; nil if none shows now. Alert button ids haven't
    /// been confirmed on a device, hence the fallback.
    private func dialogButton(_ id: String, label: String) -> XCUIElement? {
        let byID = element(id)
        if byID.exists { return byID }
        for container in [app.alerts, app.sheets, app.popovers] {
            let match = container.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            if match.exists { return match }
        }
        return nil
    }

    private func tapDialogButton(_ id: String, label: String, timeout: TimeInterval = 15) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let button = dialogButton(id, label: label) {
                button.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("No dialog button \(id) (\(label))")
    }
}
