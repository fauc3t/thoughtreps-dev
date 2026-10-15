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
            self.engine = engine
            self.triggers = triggers
            let status = await engine.syncNow()
            logger.info("Debug sync started against \(environment.url.absoluteString): \(String(describing: status))")
        } catch {
            logger.error("Starting debug sync failed: \(error)")
        }
    }

    /// A cycle when the app comes to the foreground.
    static func syncNow() async {
        guard let engine else { return }
        await engine.syncNow()
    }
}
#endif
