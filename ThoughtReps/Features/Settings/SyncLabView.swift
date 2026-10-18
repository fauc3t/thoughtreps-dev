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

    private(set) var devices: SyncDeviceList?
    private(set) var devicesMessage: String?
    private(set) var isLoadingDevices = false
    private(set) var isWorking = false
    private(set) var leaveStep: LeaveGate.Step?
    private(set) var confirmsDeleteData = false
    var pendingRemoval: SyncDeviceList.Device?
    var awaitingResume: Bool { SyncDebugSession.awaitingResume }

    var offset: TimeInterval { ServerClockOffset(defaults: .standard).current }

    func signIn(in context: ModelContext) async {
        isSigningIn = true
        accountMessage = await SyncDebugSession.signInAndCreateVault(container: context.container)
        isSigningIn = false
        await reload()
    }

    func forgetAccount() async {
        await SyncDebugSession.forgetAccount()
        accountMessage = "Key forgotten."
        recoveryCode = nil
        await refresh()
    }

    // MARK: Resuming

    func resume(in context: ModelContext) async {
        await SyncDebugSession.resume(container: context.container)
        accountMessage = nil
        await reload()
    }

    // MARK: Devices

    private var service: SyncAccountService { SyncDebugSession.accountService() }

    private func heldSession() throws -> (SyncCredentials, SyncSessionSource) {
        guard let held = try KeychainSyncCredentialStore().load() else { throw SyncAccountError.notRegistered }
        return (held, SyncDebugSession.sessionSource(for: held, service: service))
    }

    func loadDevices() async {
        guard accountVaultID != nil, !awaitingResume else {
            devices = nil
            return
        }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        do {
            let (held, session) = try heldSession()
            devices = try await service.listDevices(credentials: held, session: session)
            devicesMessage = nil
        } catch {
            devicesMessage = SyncDebugSession.failureText(error)
        }
    }

    func renameThisDevice(to name: String) async {
        guard let keyId = devices?.current?.keyId else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let (held, session) = try heldSession()
            try await service.renameDevice(keyId: keyId, to: name, credentials: held, session: session)
            devicesMessage = nil
        } catch {
            devicesMessage = SyncDebugSession.failureText(error)
        }
        await loadDevices()
    }

    func removePendingDevice() async {
        guard let device = pendingRemoval else { return }
        pendingRemoval = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let (held, session) = try heldSession()
            try await service.removeDevice(keyId: device.keyId, credentials: held, session: session)
            devicesMessage = "Removed \(device.name)."
        } catch {
            devicesMessage = SyncDebugSession.failureText(error)
        }
        await loadDevices()
    }

    // MARK: Leaving and deleting

    func requestLeave(erase: Bool, in context: ModelContext) {
        do {
            leaveStep = LeaveGate.begin(erase: erase, thoughtCount: try context.fetchCount(FetchDescriptor<Thought>()))
        } catch {
            accountMessage = "Couldn't count the thoughts on this device: \(error)"
        }
    }

    func answerLeave(_ action: LeaveGate.Action, in context: ModelContext) {
        guard let leaveStep else { return }
        let next = LeaveGate.advance(leaveStep, action)
        switch next {
        case .run(let erase):
            self.leaveStep = nil
            isWorking = true
            Task { await runLeave(erase: erase, in: context) }
        case .cancelled:
            self.leaveStep = nil
        default:
            self.leaveStep = next
        }
    }

    private func runLeave(erase: Bool, in context: ModelContext) async {
        let result = await SyncDebugSession.leaveSync(erase: erase ? { ThoughtStore(context: context).deleteAll() } : nil)
        isWorking = false
        switch result {
        case .left: accountMessage = "Left sync. This device keeps its thoughts."
        case .leftAndErased: accountMessage = "Left sync and erased this device."
        case .eraseFailed: accountMessage = "Left sync, but erasing this device failed."
        case .failed(let text): accountMessage = text
        }
        recoveryCode = nil
        devices = nil
        await refresh()
    }

    func requestDeleteData() {
        confirmsDeleteData = true
    }

    func answerDeleteData(_ confirmed: Bool) {
        confirmsDeleteData = false
        guard confirmed, !isWorking else { return }
        isWorking = true
        Task {
            let failure = await SyncDebugSession.deleteSyncData()
            isWorking = false
            accountMessage = failure ?? "Sync data deleted. This device keeps its thoughts."
            if failure == nil {
                recoveryCode = nil
                devices = nil
            }
            await refresh()
        }
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
        await reload()
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

    func reload() async {
        await refresh()
        await loadDevices()
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
    @State private var showRename = false
    @State private var renameText = ""

    private var busy: Bool {
        model.isSigningIn || model.isJoining || model.isWorking || SyncDebugSession.usesEnvironmentVault
    }

    private var leaveBinding: Binding<Bool> {
        Binding(
            get: { if case .confirmLeave = model.leaveStep { true } else { false } },
            set: { if !$0, case .confirmLeave = model.leaveStep { model.answerLeave(.cancel, in: context) } }
        )
    }

    private var eraseBinding: Binding<Bool> {
        Binding(
            get: { if case .confirmErase = model.leaveStep { true } else { false } },
            set: { if !$0, case .confirmErase = model.leaveStep { model.answerLeave(.cancel, in: context) } }
        )
    }

    private var removeBinding: Binding<Bool> {
        Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } })
    }

    private var deleteDataBinding: Binding<Bool> {
        Binding(get: { model.confirmsDeleteData }, set: { if !$0 { model.answerDeleteData(false) } })
    }

    private var leaveErases: Bool {
        if case .confirmLeave(let erase, _) = model.leaveStep { erase } else { false }
    }

    private var eraseCount: Int {
        if case .confirmErase(let count) = model.leaveStep { count } else { 0 }
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
                if let vault = model.accountVaultID, model.awaitingResume {
                    LabeledContent("Account vault", value: vault)
                    Text(SyncResumeGate.title).font(.headline)
                    Text(SyncResumeGate.message).font(.footnote).foregroundStyle(.secondary)
                    Button("Resume") { Task { await model.resume(in: context) } }
                    Button("Forget", role: .destructive) { Task { await model.forgetAccount() } }
                } else if let vault = model.accountVaultID {
                    LabeledContent("Account vault", value: vault)
                    Button("Show recovery code") { model.showRecoveryCode() }
                    if let code = model.recoveryCode {
                        Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    Button("Add a device") { showInvite = true }
                    Button("Leave sync", role: .destructive) { model.requestLeave(erase: false, in: context) }
                        .disabled(busy)
                    Button("Erase this device and leave sync", role: .destructive) { model.requestLeave(erase: true, in: context) }
                        .disabled(busy)
                    Button("Delete sync data", role: .destructive) { model.requestDeleteData() }
                        .disabled(busy)
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
                if model.isJoining || model.isWorking { ProgressView() }
                if let message = model.accountMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Needs a real device. Forgetting also drops this device's App Attest key, so the next sign-in registers a new device (the old one still counts toward the device limit). The vault stays on the server; rejoin it with iCloud Keychain, a recovery code or a QR code.")
            }

            if model.accountVaultID != nil, !model.awaitingResume {
                devicesSection
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
        .task { await model.reload() }
        .refreshable { await model.reload() }
        .sheet(isPresented: $showInvite) { SyncInviteSheet(model: model) }
        .sheet(isPresented: $showScan) {
            SyncScanSheet { invite in
                Task { await model.requestJoin(.invite(invite), in: context) }
            }
        }
        .alert(LeaveGate.leaveTitle(device: SyncDeviceName.current), isPresented: leaveBinding) {
            Button(leaveErases ? "Continue" : "Leave sync", role: leaveErases ? nil : .destructive) { model.answerLeave(.confirm, in: context) }
            Button("Cancel", role: .cancel) { model.answerLeave(.cancel, in: context) }
        } message: {
            Text(LeaveGate.leaveMessage(erase: leaveErases))
        }
        .alert(LeaveGate.eraseTitle(count: eraseCount, device: SyncDeviceName.current), isPresented: eraseBinding) {
            Button("Erase", role: .destructive) { model.answerLeave(.confirm, in: context) }
            Button("Cancel", role: .cancel) { model.answerLeave(.cancel, in: context) }
        } message: {
            Text(LeaveGate.eraseMessage)
        }
        .alert(LeaveGate.removeTitle(name: model.pendingRemoval?.name ?? ""), isPresented: removeBinding) {
            Button("Remove", role: .destructive) { Task { await model.removePendingDevice() } }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            Text(LeaveGate.removeMessage)
        }
        .alert(LeaveGate.deleteDataTitle, isPresented: deleteDataBinding) {
            Button("Delete sync data", role: .destructive) { model.answerDeleteData(true) }
            Button("Cancel", role: .cancel) { model.answerDeleteData(false) }
        } message: {
            Text(LeaveGate.deleteDataMessage)
        }
        .alert("Rename this device", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await model.renameThisDevice(to: renameText) } }
            Button("Cancel", role: .cancel) {}
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

    private var devicesSection: some View {
        Section {
            if let devices = model.devices {
                ForEach(devices.devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(device.name).font(.headline)
                            if device.isCurrent { Text("This device").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text("Added \(device.addedAt.formatted(date: .abbreviated, time: .shortened)), last seen \(device.lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                        if device.isCurrent {
                            Button("Rename") {
                                renameText = device.name == SyncDeviceList.unnamed ? "" : device.name
                                showRename = true
                            }
                            .disabled(busy)
                        } else {
                            Button("Remove", role: .destructive) { model.pendingRemoval = device }
                                .disabled(busy)
                        }
                    }
                }
                Text(devices.countText).font(.footnote).foregroundStyle(.secondary)
            } else if model.isLoadingDevices {
                ProgressView()
            }
            if let message = model.devicesMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Pull to refresh. Removing a device stops it syncing; its thoughts stay on it.")
        }
    }
}
#endif
