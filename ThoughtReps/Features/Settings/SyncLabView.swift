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
        await refresh()
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
                    .disabled(model.isSigningIn || SyncDebugSession.usesEnvironmentVault)
                }
                if let message = model.accountMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Needs a real device. Forgetting also drops this device's App Attest key, so the next sign-in registers a new device. The vault stays on the server with no way back in until pairing exists.")
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
    }
}
#endif
