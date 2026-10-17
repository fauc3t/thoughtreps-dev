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
/// With any of them missing, the engine uses the account signed in from the Sync lab (its key in the Keychain, a bearer
/// session) instead, unless `THOUGHTREPS_SYNC_VAULT` is set. With neither, nothing starts and the outbox just fills.
/// `THOUGHTREPS_SYNC_URL` alone points the account at another server.
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
        Environment().map { ($0.url.absoluteString, $0.vault) } ?? accountTarget
    }

    private(set) static var accountTarget: (url: String, vault: String)?

    /// A launch that names a vault in the environment syncs with that, never with the account in the Keychain.
    static var usesEnvironmentVault: Bool {
        !(ProcessInfo.processInfo.environment["THOUGHTREPS_SYNC_VAULT"] ?? "").isEmpty
    }

    /// The engine's status, or nil before it has started.
    static func status() async -> SyncEngine.Status? {
        guard let engine else { return nil }
        return await engine.status
    }

    /// Builds the engine and triggers and runs a first cycle: against the launch environment's dev server if it names one
    /// (creating the vault there if it is new), otherwise with the account in the Keychain, if there is one. Call once the
    /// outbox is on and reconciled.
    static func start(
        container: ModelContainer, state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore()
    ) async {
        guard engine == nil else { return }
        if let environment = Environment() {
            do {
                let transport = HTTPSyncTransport(
                    baseURL: environment.url, vaultID: environment.vault, devSecret: environment.secret,
                    offset: ServerClockOffset(defaults: .standard)
                )
                try await transport.createVault()
                await begin(container: container, state: state, transport: transport, key: environment.key, vaultID: environment.vault)
            } catch {
                logger.error("Starting debug sync failed: \(error)")
            }
        } else if !usesEnvironmentVault {
            do {
                guard let held = try credentials.load() else { return }
                await beginAccount(container: container, state: state, credentials: held, seed: nil)
            } catch {
                logger.error("Reading the sync credentials failed: \(error)")
            }
        }
    }

    /// Signs in with Apple, creates the account's vault if it has none, and starts the engine with it. The text is what the
    /// Sync lab shows.
    static func signInAndCreateVault(container: ModelContainer, state: SyncState = .shared) async -> String {
        guard engine == nil else { return "Already syncing. Forget the key first." }
        let service = SyncAccountService(
            api: SyncAccountAPI(baseURL: SyncAccountAPI.defaultBaseURL()), apple: AuthenticationServicesSignIn(),
            credentials: KeychainSyncCredentialStore()
        )
        do {
            switch try await service.signInAndCreateVault() {
            case .vaultCreated(let held, let session):
                try await enableOutbox(state: state, container: container, vaultID: held.vaultID)
                await beginAccount(container: container, state: state, credentials: held, seed: session)
                return "Vault created."
            case .signedIn(let held, let session):
                try await enableOutbox(state: state, container: container, vaultID: held.vaultID)
                await beginAccount(container: container, state: state, credentials: held, seed: session)
                return "Signed in."
            case .accountHasVault:
                return "This account already has a vault; joining another device comes in the next round."
            case .deviceInVault:
                return "This device belongs to a vault of another account."
            }
        } catch SyncAccountError.appleSignInCancelled {
            return "Sign in cancelled."
        } catch {
            logger.error("Sign in failed: \(error)")
            return "Sign in failed: \(error)"
        }
    }

    /// Stops syncing, empties the outbox and deletes the vault key and the sync App Attest keyId from the Keychain, so the
    /// next sign-in registers a fresh device with the server.
    static func forgetAccount(
        state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore(),
        attestKeys: KeyIdStore = SyncAccountAPI.defaultKeyStore()
    ) async {
        await triggers?.stop(observing: state)
        engine = nil
        triggers = nil
        accountTarget = nil
        state.disable()
        credentials.clear()
        attestKeys.clear()
    }

    private static func enableOutbox(state: SyncState, container: ModelContainer, vaultID: String) async throws {
        try await state.configure(vaultID: vaultID)
        await SyncReconcileRunner.reconcile(container: container, state: state)
    }

    private static func beginAccount(
        container: ModelContainer, state: SyncState, credentials: SyncCredentials, seed: SyncHTTPWireV1.SessionToken?
    ) async {
        let url = SyncAccountAPI.defaultBaseURL()
        let provider = SyncSessionProvider(
            api: SyncAccountAPI(baseURL: url), vaultID: credentials.vaultID,
            serverNow: { Date().addingTimeInterval(ServerClockOffset(defaults: .standard).current) }
        )
        if let seed { await provider.adopt(seed) }
        let transport = HTTPSyncTransport(
            baseURL: url, vaultID: credentials.vaultID, auth: .session(provider), offset: ServerClockOffset(defaults: .standard)
        )
        accountTarget = (url.absoluteString, credentials.vaultID)
        await begin(container: container, state: state, transport: transport, key: credentials.vaultKey, vaultID: credentials.vaultID)
    }

    private static func begin(container: ModelContainer, state: SyncState, transport: HTTPSyncTransport, key: Data, vaultID: String) async {
        do {
            var store = ThoughtStore(context: container.mainContext)
            store.syncState = state
            let local = ThoughtSyncLocal(store: store, reconcile: {
                await SyncReconcileRunner.reconcile(container: container, state: state)
            })
            let engine = SyncEngine(transport: transport, state: state, local: local, keys: try SyncKeys(vaultKey: key), vaultID: vaultID)
            let triggers = SyncTriggers(engine: engine)
            await triggers.start(observing: state)
            await engine.setObserver(Self.noteStatus)
            self.engine = engine
            self.triggers = triggers
            let status = await engine.syncNow()
            logger.info("Debug sync started against \(transport.baseURL.absoluteString): \(String(describing: status))")
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
