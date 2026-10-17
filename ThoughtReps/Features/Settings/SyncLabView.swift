#if DEBUG
import SwiftUI
import SwiftData

/// What the Sync lab says about the engine, as plain text so it can be tested without a view.
enum SyncLabText {
    static func phase(_ phase: SyncEngine.Phase) -> String {
        switch phase {
        case .idle: "Idle"
        case .pulling: "Pulling"
        case .pushing: "Pushing"
        case .stopped: "Stopped"
        }
    }

    static func attention(_ attention: SyncEngine.Attention?) -> String {
        switch attention {
        case nil: "None"
        case .epochChanged(let known, let server): "Epoch changed (device \(known), server \(server))"
        case .serverRefused(let status, let message): "Server refused: \(status) \(message)"
        }
    }

    /// The last garbage collection attempt: what happened and when, plus the earliest time the server allows another.
    static func garbageCollection(_ log: GarbageCollectionLog) -> String {
        guard let outcome = log.lastOutcome, let at = log.lastAttemptAt else { return "Never" }
        let name = switch outcome {
        case .started: "Started"
        case .stale: "Stale, will retry"
        case .liveListMissing: "Live list missing, will retry"
        case .rateLimited: "Rate limited"
        case .failed: "Failed, will retry"
        case .tooManyBlobs: "Skipped, too many blobs"
        }
        var text = "\(name) at \(at.formatted(date: .abbreviated, time: .standard))"
        if let retry = log.retryNotBefore, retry > at { text += ", not before \(retry.formatted(date: .omitted, time: .standard))" }
        return text
    }

    static func quota(_ quota: SyncEngine.BlobQuota?) -> String {
        guard let quota else { return "Not exceeded" }
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return "\(format(quota.usedBytes)) of \(format(quota.limitBytes)) used"
    }

    static func offset(_ seconds: TimeInterval) -> String {
        String(format: "%+.3f s", seconds)
    }

    static func checks(violations: Int) -> String {
        violations == 0 ? "Passed" : "Failed: \(violations) \(violations == 1 ? "violation" : "violations")"
    }
}

@MainActor
@Observable
final class SyncLabModel {
    struct Snapshot {
        var status: SyncEngine.Status?
        var outbox = 0
        var held = 0
        var parked = 0
        var garbageCollection = GarbageCollectionLog()
    }

    private(set) var snapshot = Snapshot()
    private(set) var lastSync: Date?
    private(set) var isSyncing = false
    private(set) var isChecking = false
    private(set) var checksResult: String?
    private(set) var violations: [String] = []

    private(set) var isSigningIn = false
    private(set) var accountMessage: String?
    /// The vault this device holds the key for (never the key itself).
    private(set) var accountVaultID: String?
    private(set) var iCloudEnabled = ICloudKeyCopy().isEnabled
    private(set) var iCloudCopyExists = false
    private(set) var isJoining = false
    private(set) var joinStep: JoinGate.Step?
    private(set) var recoveryCode: String?
    private(set) var invitation: SyncAccountService.Invitation?
    private(set) var inviteMessage: String?
    private var pendingJoin: SyncDebugSession.JoinSource?

    var offset: TimeInterval { ServerClockOffset(defaults: .standard).current }

    func signIn(in context: ModelContext) async {
        isSigningIn = true
        accountMessage = await SyncDebugSession.signInAndCreateVault(container: context.container)
        isSigningIn = false
        await refresh()
    }

    func forgetAccount() async {
        await SyncDebugSession.forgetAccount()
        accountMessage = "Key forgotten."
        recoveryCode = nil
        await refresh()
    }

    // MARK: iCloud Keychain copy

    func setICloudCopy(_ enabled: Bool) async {
        do {
            try SyncDebugSession.setICloudCopy(enabled: enabled)
        } catch {
            accountMessage = "Couldn't update the iCloud Keychain copy: \(error)"
        }
        iCloudEnabled = ICloudKeyCopy().isEnabled
        await refresh()
    }

    func deleteICloudCopy() async {
        ICloudKeyCopy().delete()
        accountMessage = "iCloud Keychain copy deleted."
        await refresh()
    }

    // MARK: Joining

    enum JoinDialog { case join, ask, confirmErase }

    /// Starts a join. A mistyped code or a missing iCloud copy stops here with a message; otherwise the person is asked to
    /// confirm, and then, with thoughts on this device, what to do with them, before anything is sent.
    func requestJoin(_ source: SyncDebugSession.JoinSource, in context: ModelContext) async {
        if let problem = SyncDebugSession.preflight(source) {
            accountMessage = problem
            return
        }
        pendingJoin = source
        accountMessage = nil
        let count = (try? context.fetchCount(FetchDescriptor<Thought>())) ?? 0
        apply(JoinGate.begin(thoughtCount: count), in: context)
    }

    func answerJoin(_ action: JoinGate.Action, in context: ModelContext) {
        guard let joinStep else { return }
        apply(JoinGate.advance(joinStep, action), in: context)
    }

    /// A dialog closed without one of its buttons (a tap outside it): the same as Cancel, if it is still the one showing.
    func dialogDismissed(_ dialog: JoinDialog, in context: ModelContext) {
        switch (dialog, joinStep) {
        case (.join, .confirmJoin), (.ask, .askMergeOrErase), (.confirmErase, .confirmErase): answerJoin(.cancel, in: context)
        default: break
        }
    }

    private func apply(_ step: JoinGate.Step, in context: ModelContext) {
        switch step {
        case .confirmJoin, .askMergeOrErase, .confirmErase:
            joinStep = step
        case .cancelled:
            joinStep = nil
            pendingJoin = nil
        case .join(let eraseFirst):
            joinStep = nil
            guard let source = pendingJoin else { return }
            pendingJoin = nil
            Task { await runJoin(source, eraseFirst: eraseFirst, in: context) }
        }
    }

    private func runJoin(_ source: SyncDebugSession.JoinSource, eraseFirst: Bool, in context: ModelContext) async {
        isJoining = true
        accountMessage = await SyncDebugSession.join(source, container: context.container, beforeStart: {
            !eraseFirst || ThoughtStore(context: context).deleteAll()
        })
        isJoining = false
        await refresh()
    }

    func showRecoveryCode() {
        recoveryCode = SyncDebugSession.recoveryCode()
        if recoveryCode == nil { accountMessage = "No key on this device." }
    }

    // MARK: Inviting

    func openInvitation() async {
        invitation = nil
        inviteMessage = nil
        do {
            invitation = try await SyncDebugSession.createInvitation()
        } catch let error as SyncAccountError {
            inviteMessage = error == .notRegistered ? "Start syncing on this device first." : error.pairingMessage
        } catch {
            inviteMessage = "Failed: \(error)"
        }
    }

    func closeInvitation() {
        invitation = nil
        inviteMessage = nil
    }

    func refresh(state: SyncState = .shared) async {
        var next = Snapshot(status: await SyncDebugSession.status())
        next.outbox = (try? await state.outboxCount()) ?? 0
        next.held = (try? await state.heldCount()) ?? 0
        next.parked = (try? await state.parkedCount()) ?? 0
        next.garbageCollection = (try? await state.garbageCollectionLog()) ?? GarbageCollectionLog()
        snapshot = next
        lastSync = SyncDebugSession.lastSuccessfulSync
        accountVaultID = (try? KeychainSyncCredentialStore().load())?.vaultID
        iCloudEnabled = ICloudKeyCopy().isEnabled
        iCloudCopyExists = ((try? ICloudKeyCopy().load()) ?? nil) != nil
    }

    func syncNow() async {
        isSyncing = true
        await SyncDebugSession.syncNow()
        isSyncing = false
        await refresh()
    }

    func runChecks(in context: ModelContext, index: SearchIndex = .shared) async {
        isChecking = true
        checksResult = nil
        var found: [String] = []
        do {
            found += try IntegrityChecker.check(context).map(\.description)
            found += try await SearchIndexChecker.check(context, index: index)
        } catch {
            found.append("Check failed to fetch: \(error)")
        }
        violations = found
        checksResult = SyncLabText.checks(violations: found.count)
        isChecking = false
    }
}

/// DEBUG only, reached from Settings. The full lab (pairing, scripted scenarios, fault switches) is a later phase.
struct SyncLabView: View {
    @Environment(\.modelContext) private var context
    @State private var model = SyncLabModel()
    @State private var recoveryEntry = ""
    @State private var showInvite = false
    @State private var showScan = false

    private var busy: Bool {
        model.isSigningIn || model.isJoining || SyncDebugSession.usesEnvironmentVault
    }

    private var joinBinding: Binding<Bool> {
        Binding(
            get: { if case .confirmJoin = model.joinStep { true } else { false } },
            set: { if !$0 { model.dialogDismissed(.join, in: context) } }
        )
    }

    private var askBinding: Binding<Bool> {
        Binding(
            get: { if case .askMergeOrErase = model.joinStep { true } else { false } },
            set: { if !$0 { model.dialogDismissed(.ask, in: context) } }
        )
    }

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { if case .confirmErase = model.joinStep { true } else { false } },
            set: { if !$0 { model.dialogDismissed(.confirmErase, in: context) } }
        )
    }

    private var step: (count: Int, device: String) {
        let device = SyncDeviceName.current
        switch model.joinStep {
        case .askMergeOrErase(let count), .confirmErase(let count): return (count, device)
        default: return (0, device)
        }
    }

    var body: some View {
        Form {
            Section("Debug sync") {
                if let target = SyncDebugSession.target {
                    LabeledContent("Server", value: target.url)
                    LabeledContent("Vault", value: target.vault)
                } else {
                    Text("Not configured. Launch with THOUGHTREPS_SYNC_URL, _VAULT, _DEV_SECRET and _KEY.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let vault = model.accountVaultID {
                    LabeledContent("Account vault", value: vault)
                    Button("Show recovery code") { model.showRecoveryCode() }
                    if let code = model.recoveryCode {
                        Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    Button("Add a device") { showInvite = true }
                    Button("Sign out and forget key", role: .destructive) {
                        Task { await model.forgetAccount() }
                    }
                } else {
                    Button {
                        Task { await model.signIn(in: context) }
                    } label: {
                        HStack {
                            Text("Sign in with Apple and create vault")
                            if model.isSigningIn { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy)
                    if model.iCloudCopyExists {
                        Button("Join vault from iCloud Keychain") {
                            Task { await model.requestJoin(.iCloudKeychain, in: context) }
                        }
                        .disabled(busy)
                    }
                    Button("Join by scanning a QR code") { showScan = true }
                        .disabled(busy)
                    TextField("Recovery code", text: $recoveryEntry, axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    Button("Join with recovery code") {
                        Task { await model.requestJoin(.recoveryCode(recoveryEntry), in: context) }
                    }
                    .disabled(busy || recoveryEntry.isEmpty)
                }
                if model.isJoining { ProgressView() }
                if let message = model.accountMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Needs a real device. Forgetting also drops this device's App Attest key, so the next sign-in registers a new device (the old one still counts toward the device limit). The vault stays on the server; rejoin it with iCloud Keychain, a recovery code or a QR code.")
            }

            Section {
                Toggle("Save sync key to iCloud Keychain", isOn: Binding(
                    get: { model.iCloudEnabled },
                    set: { value in Task { await model.setICloudCopy(value) } }
                ))
                if model.iCloudCopyExists {
                    Button("Delete iCloud copy", role: .destructive) {
                        Task { await model.deleteICloudCopy() }
                    }
                }
            } header: {
                Text("iCloud Keychain")
            } footer: {
                Text("Lets your other devices on this Apple account join the vault. Turning it off deletes the copy. Signing out leaves it; delete it here.")
            }

            Section("Engine") {
                if let status = model.snapshot.status {
                    LabeledContent("Phase", value: SyncLabText.phase(status.phase))
                    LabeledContent("Attention", value: SyncLabText.attention(status.attention))
                    LabeledContent("Last error", value: status.lastError ?? "None")
                    LabeledContent("Update required", value: status.updateRequired ? "Yes" : "No")
                    LabeledContent("Cycles", value: "\(status.cycles)")
                    LabeledContent("Cursor", value: "\(status.cursor)")
                } else {
                    Text("Not running").foregroundStyle(.secondary)
                }
                LabeledContent("Outbox", value: "\(model.snapshot.outbox)")
                LabeledContent("Held for blobs", value: "\(model.snapshot.held)")
                LabeledContent("Parked", value: "\(model.snapshot.parked)")
                if let status = model.snapshot.status {
                    LabeledContent("Held for storage limit", value: "\(status.quotaExceededThoughts)")
                    LabeledContent("Storage", value: SyncLabText.quota(status.blobQuota))
                }
                LabeledContent("Garbage collection", value: SyncLabText.garbageCollection(model.snapshot.garbageCollection))
                LabeledContent("Last successful sync", value: model.lastSync.map { $0.formatted(date: .omitted, time: .standard) } ?? "Never")
                LabeledContent("Server clock offset", value: SyncLabText.offset(model.offset))
            }

            Section {
                Button {
                    Task { await model.syncNow() }
                } label: {
                    HStack {
                        Text("Sync now")
                        if model.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isSyncing || SyncDebugSession.target == nil)
                Button {
                    Task { await model.runChecks(in: context) }
                } label: {
                    HStack {
                        Text("Run checks")
                        if model.isChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isChecking)
                if let result = model.checksResult {
                    Text(result)
                        .foregroundStyle(model.violations.isEmpty ? .green : .red)
                        .accessibilityIdentifier("syncLabChecksResult")
                    ForEach(model.violations.prefix(5), id: \.self) { Text($0).font(.footnote) }
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("Run checks runs the integrity and search index checks over every thought.")
            }
        }
        .navigationTitle("Sync lab")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showInvite) { SyncInviteSheet(model: model) }
        .sheet(isPresented: $showScan) {
            SyncScanSheet { invite in
                Task { await model.requestJoin(.invite(invite), in: context) }
            }
        }
        .alert(JoinGate.joinTitle, isPresented: joinBinding) {
            Button("Join") { model.answerJoin(.confirmJoin, in: context) }
            Button("Cancel", role: .cancel) { model.answerJoin(.cancel, in: context) }
        } message: {
            Text(JoinGate.joinMessage)
        }
        .confirmationDialog(
            JoinGate.askTitle(count: step.count, device: step.device), isPresented: askBinding, titleVisibility: .visible
        ) {
            Button("Merge") { model.answerJoin(.merge, in: context) }
            Button("Erase \(step.device) first", role: .destructive) { model.answerJoin(.erase, in: context) }
            Button("Cancel", role: .cancel) { model.answerJoin(.cancel, in: context) }
        } message: {
            Text(JoinGate.askMessage(device: step.device))
        }
        .alert(JoinGate.confirmTitle(count: step.count, device: step.device), isPresented: confirmBinding) {
            Button("Erase", role: .destructive) { model.answerJoin(.confirmErase, in: context) }
            Button("Cancel", role: .cancel) { model.answerJoin(.cancel, in: context) }
        } message: {
            Text(JoinGate.confirmMessage)
        }
    }
}
#endif
