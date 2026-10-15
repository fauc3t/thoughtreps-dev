#if DEBUG
import Foundation
import SwiftData
import os

/// DEBUG only: runs the sync engine against a dev server when the launch environment names one. Not a write path; the
/// engine reaches the store through `ThoughtSyncLocal`, like in tests.
///
///     THOUGHTREPS_SYNC_URL         http://127.0.0.1:8787/api/v1
///     THOUGHTREPS_SYNC_VAULT       the vault id (also turns on the outbox, see `SyncState.enableForDebugging`)
///     THOUGHTREPS_SYNC_DEV_SECRET  the server's dev secret
///     THOUGHTREPS_SYNC_KEY         base64 of the 32-byte vault key, the same on every device of the vault
///
/// With any of them missing, nothing starts and the outbox just fills.
@MainActor
enum SyncDebugSession {
    struct Environment {
        var url: URL
        var vault: String
        var secret: String
        var key: Data

        init?(_ values: [String: String] = ProcessInfo.processInfo.environment) {
            guard let url = values["THOUGHTREPS_SYNC_URL"].flatMap(URL.init(string:)), url.scheme != nil,
                  let vault = values["THOUGHTREPS_SYNC_VAULT"], !vault.isEmpty,
                  let secret = values["THOUGHTREPS_SYNC_DEV_SECRET"], !secret.isEmpty,
                  let key = values["THOUGHTREPS_SYNC_KEY"].flatMap({ Data(base64Encoded: $0) }), key.count == SyncKeys.keyLength
            else { return nil }
            self.url = url
            self.vault = vault
            self.secret = secret
            self.key = key
        }
    }

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "sync")
    private static var engine: SyncEngine?
    private static var triggers: SyncTriggers?
    /// When the engine last finished a cycle without an error or attention state.
    private(set) static var lastSuccessfulSync: Date?

    /// The server and vault this launch syncs with (never the secret or key), or nil when it isn't configured.
    static var target: (url: String, vault: String)? {
        Environment().map { ($0.url.absoluteString, $0.vault) }
    }

    /// The engine's status, or nil before it has started.
    static func status() async -> SyncEngine.Status? {
        guard let engine else { return nil }
        return await engine.status
    }

    /// Builds the engine and triggers, creates the vault on the server if it is new, and runs a first cycle. Call once the
    /// outbox is on and reconciled.
    static func start(container: ModelContainer, state: SyncState = .shared) async {
        guard engine == nil, let environment = Environment() else { return }
        do {
            let transport = HTTPSyncTransport(
                baseURL: environment.url, vaultID: environment.vault, devSecret: environment.secret,
                offset: ServerClockOffset(defaults: .standard)
            )
            try await transport.createVault()
            var store = ThoughtStore(context: container.mainContext)
            store.syncState = state
            let local = ThoughtSyncLocal(store: store, reconcile: {
                await SyncReconcileRunner.reconcile(container: container, state: state)
            })
            let engine = SyncEngine(
                transport: transport, state: state, local: local, keys: try SyncKeys(vaultKey: environment.key),
                vaultID: environment.vault
            )
            let triggers = SyncTriggers(engine: engine)
            await triggers.start(observing: state)
            await engine.setObserver(Self.noteStatus)
            self.engine = engine
            self.triggers = triggers
            let status = await engine.syncNow()
            logger.info("Debug sync started against \(environment.url.absoluteString): \(String(describing: status))")
        } catch {
            logger.error("Starting debug sync failed: \(error)")
        }
    }

    /// A cycle when the app comes to the foreground, or from the Sync lab.
    @discardableResult
    static func syncNow() async -> SyncEngine.Status? {
        guard let engine else { return nil }
        return await engine.syncNow()
    }

    /// What the status file holds: enough for a test to tell that a cycle has pushed its outbox and pulled up to a seq.
    /// Never the secret or key.
    struct StatusSnapshot: Codable, Equatable {
        var cycles: Int
        var cursor: Int64
        var outbox: Int
        var phase: String
        var attention: String?
        var lastError: String?

        init(_ status: SyncEngine.Status) {
            cycles = status.cycles
            cursor = status.cursor
            outbox = status.pending
            phase = SyncLabText.phase(status.phase)
            attention = status.attention.map { SyncLabText.attention($0) }
            lastError = status.lastError
        }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }
    }

    /// `THOUGHTREPS_SYNC_STATUS_FILE`: a path the app rewrites with a `StatusSnapshot` after every cycle.
    private nonisolated static let statusFile: URL? = ProcessInfo.processInfo.environment["THOUGHTREPS_SYNC_STATUS_FILE"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

    private static let noteStatus: @Sendable (SyncEngine.Status) -> Void = { status in
        if let file = statusFile, status.phase == .idle || status.phase == .stopped,
           let data = try? StatusSnapshot(status).encoded() {
            try? data.write(to: file, options: .atomic)
        }
        guard status.phase == .idle, status.lastError == nil, status.attention == nil, status.cycles > 0 else { return }
        Task { @MainActor in
            if status.cycles != lastCycles {
                lastCycles = status.cycles
                lastSuccessfulSync = .now
            }
        }
    }

    private static var lastCycles = 0
}
#endif
