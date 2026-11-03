#if DEBUG
import Foundation
import SwiftData
import os

/// DEBUG only: the launch environment's way to run the sync engine against a dev server, the Sync lab's account actions and
/// the status file. The engine itself is `SyncController`'s. Not a write path; the engine reaches the store through
/// `ThoughtSyncLocal`, like in tests.
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

    /// The shared controller, set up for this launch's debug options.
    static let controller: SyncController = {
        let controller = SyncController.shared
        controller.automaticTriggers = !manualSyncOnly
        controller.statusTap = { report($0) }
        return controller
    }()

    /// When the engine last finished a cycle without an error or attention state.
    static var lastSuccessfulSync: Date? { controller.lastSyncedAt }

    /// The server and vault this launch syncs with (never the secret or key), or nil when it isn't configured.
    static var target: (url: String, vault: String)? {
        Environment().map { ($0.url.absoluteString, $0.vault) } ?? controller.target
    }

    /// A launch that names a vault in the environment syncs with that, never with the account in the Keychain.
    static var usesEnvironmentVault: Bool {
        !(ProcessInfo.processInfo.environment["THOUGHTREPS_SYNC_VAULT"] ?? "").isEmpty
    }

    /// The engine's status, or nil before it has started.
    static func status() async -> SyncEngine.Status? {
        await controller.currentEngineStatus()
    }

    /// Builds the engine and triggers and runs a first cycle: against the launch environment's dev server if it names one
    /// (creating the vault there if it is new), otherwise with the account in the Keychain, if there is one. Call once the
    /// outbox is on and reconciled.
    static func start(
        container: ModelContainer, state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore()
    ) async {
        guard !controller.isRunning else { return }
        if let environment = Environment() {
            do {
                let transport = HTTPSyncTransport(
                    baseURL: environment.url, vaultID: environment.vault, devSecret: environment.secret,
                    offset: ServerClockOffset(defaults: .standard)
                )
                try await transport.createVault()
                await controller.start(container: container, state: state, transport: transport, key: environment.key, vaultID: environment.vault)
            } catch {
                logger.error("Starting debug sync failed: \(error)")
            }
        } else if !usesEnvironmentVault {
            do {
                guard let held = try credentials.load() else { return }
                await controller.startAccount(container: container, state: state, credentials: held, seed: nil)
            } catch {
                logger.error("Reading the sync credentials failed: \(error)")
            }
        }
    }

    /// Signs in with Apple, creates the account's vault if it has none, and starts the engine with it. The text is what the
    /// Sync lab shows.
    static func signInAndCreateVault(container: ModelContainer, state: SyncState = .shared) async -> String {
        guard !controller.isRunning else { return "Already syncing. Forget the key first." }
        let service = accountService()
        do {
            switch try await service.signInAndCreateVault() {
            case .vaultCreated(let held, let session):
                try await enableOutbox(state: state, container: container, vaultID: held.vaultID)
                await controller.startAccount(container: container, state: state, credentials: held, seed: session)
                return "Vault created."
            case .signedIn(let held, let session):
                try await enableOutbox(state: state, container: container, vaultID: held.vaultID)
                await controller.startAccount(container: container, state: state, credentials: held, seed: session)
                return "Signed in."
            case .accountHasVault:
                return "This account already has a vault. Join it from iCloud Keychain, with a recovery code or by scanning a QR code."
            case .deviceInVault:
                return "This device belongs to a vault of another account."
            }
        } catch SyncAccountError.appleSignInCancelled {
            return "Sign in cancelled."
        } catch SyncAccountError.subscriptionRequired {
            return "A subscription is required to create a vault."
        } catch {
            logger.error("Sign in failed: \(error)")
            return "Sign in failed: \(error)"
        }
    }

    /// Where a join gets the vault id and key from.
    enum JoinSource {
        case iCloudKeychain
        case recoveryCode(String)
        case invite(SyncPairingInvite)
    }

    /// What a join says before anything is sent, or nil if it can go ahead: a mistyped recovery code, or no iCloud copy.
    static func preflight(_ source: JoinSource, iCloud: ICloudKeyCopy = ICloudKeyCopy()) -> String? {
        switch source {
        case .recoveryCode(let text):
            do { _ = try SyncRecoveryCode.parse(text) } catch let failure as SyncRecoveryCode.Failure { return failure.message } catch { return "\(error)" }
        case .iCloudKeychain:
            if (try? iCloud.load()) == nil { return "No sync key in iCloud Keychain." }
        case .invite:
            break
        }
        return nil
    }

    /// Joins the account's vault through `/pair` and starts the engine on the session it returns. The text is what the Sync
    /// lab shows. `beforeStart` (the erase the person chose) runs only after `/pair` succeeded and the key is saved, and before
    /// the outbox is on, so the erase is neither queued nor pushed. If it returns false, the key stays saved and sync is not
    /// started.
    static func join(
        _ source: JoinSource, container: ModelContainer, state: SyncState = .shared, service: SyncAccountService = accountService(),
        beforeStart: () -> Bool = { true }, start: ((SyncAccountService.Joined) async throws -> Void)? = nil
    ) async -> String {
        guard !controller.isRunning else { return "Already syncing. Forget the key first." }
        do {
            let joined: SyncAccountService.Joined
            switch source {
            case .iCloudKeychain: joined = try await service.joinFromICloudKeychain()
            case .recoveryCode(let text): joined = try await service.joinWithRecoveryCode(text)
            case .invite(let invite): joined = try await service.joinWithInvite(invite)
            }
            guard beforeStart() else {
                return "Joined the vault, but couldn't erase this \(SyncDeviceName.current), so sync did not start. The key is saved."
            }
            if let start {
                try await start(joined)
            } else {
                try await enableOutbox(state: state, container: container, vaultID: joined.credentials.vaultID)
                await controller.startAccount(container: container, state: state, credentials: joined.credentials, seed: joined.session)
            }
            return "Joined the vault."
        } catch let failure as SyncRecoveryCode.Failure {
            return failure.message
        } catch let error as SyncAccountError {
            logger.error("Joining failed: \(error)")
            return error.pairingMessage
        } catch {
            logger.error("Joining failed: \(error)")
            return "Joining failed: \(error)"
        }
    }

    /// The recovery code for the vault key this device holds, or nil without one.
    static func recoveryCode(credentials: SyncCredentialStore = KeychainSyncCredentialStore()) -> String? {
        guard let held = try? credentials.load() else { return nil }
        return try? SyncRecoveryCode.encode(vaultID: held.vaultID, vaultKey: held.vaultKey)
    }

    /// Opens an invitation to this device's vault. Needs the engine's session, so only while syncing.
    static func createInvitation(credentials: SyncCredentialStore = KeychainSyncCredentialStore()) async throws -> SyncAccountService.Invitation {
        guard let provider = controller.session, let held = try credentials.load() else { throw SyncAccountError.notRegistered }
        return try await accountService().createInvitation(credentials: held, session: provider)
    }

    /// Turns the iCloud Keychain copy on or off for the key this device holds.
    static func setICloudCopy(
        enabled: Bool, credentials: SyncCredentialStore = KeychainSyncCredentialStore(), iCloud: ICloudKeyCopy = ICloudKeyCopy()
    ) throws {
        try iCloud.setEnabled(enabled, local: try credentials.load())
    }

    static func accountService() -> SyncAccountService { SyncController.accountService() }

    /// Stops syncing, empties the outbox and deletes the vault key and the sync App Attest keyId from the Keychain, so the
    /// next sign-in registers a fresh device with the server. Returns once the state file is gone, so nothing written after
    /// this is enqueued. The iCloud Keychain copy is left.
    static func forgetAccount(
        state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore(),
        attestKeys: KeyIdStore = SyncAccountAPI.defaultKeyStore()
    ) async {
        await controller.forget(state: state, credentials: credentials, attestKeys: attestKeys)
    }

    // MARK: Leaving and deleting

    enum LeaveResult: Equatable {
        case left
        case leftAndErased
        /// The server leave worked and sync is cleared, but the erase failed.
        case eraseFailed
        /// Nothing was cleared or erased.
        case failed(String)
    }

    /// Removes this device from the vault on the server, then stops the engine and clears the key, the App Attest key id and
    /// the sync state. `erase` (the person's second confirmation) runs only after all of that, so its deletes are neither
    /// enqueued nor pushed. A failed server call leaves everything as it was. The iCloud Keychain copy is kept.
    static func leaveSync(
        erase: (() -> Bool)? = nil, service: SyncAccountService = accountService(), state: SyncState = .shared,
        session: SyncSessionSource? = nil
    ) async -> LeaveResult {
        do {
            guard let held = try service.credentials.load() else { return .failed("No key on this device.") }
            try await service.leaveVault(credentials: held, session: session ?? sessionSource(for: held, service: service))
        } catch SyncAccountError.server(let status, _) where status == 401 || status == 403 {
            return .failed("This device was removed from sync or can't reach its account. Use Sign out and forget key.")
        } catch {
            logger.error("Leaving sync failed: \(error)")
            return .failed(failureText(error))
        }
        await forgetAccount(state: state, credentials: service.credentials, attestKeys: service.api.keyStore)
        guard let erase else { return .left }
        return erase() ? .leftAndErased : .eraseFailed
    }

    /// Deletes the account's sync data on the server (every device stops syncing), then clears this device like a leave and
    /// also deletes the iCloud Keychain copy. A server failure leaves everything as it was. Returns the failure text, or nil.
    static func deleteSyncData(
        service: SyncAccountService = accountService(), state: SyncState = .shared, session: SyncSessionSource? = nil
    ) async -> String? {
        do {
            guard let held = try service.credentials.load() else { return "No key on this device." }
            try await service.deleteAccount(vaultID: held.vaultID, session: session ?? sessionSource(for: held, service: service))
        } catch SyncAccountError.differentAccount {
            return "That Apple ID's sync account isn't the one this device is in. Nothing was deleted."
        } catch SyncAccountError.appleSignInCancelled {
            return "Sign in cancelled. Nothing was deleted."
        } catch {
            logger.error("Deleting sync data failed: \(error)")
            return failureText(error)
        }
        await forgetAccount(state: state, credentials: service.credentials, attestKeys: service.api.keyStore)
        service.iCloud?.delete()
        return nil
    }

    static func failureText(_ error: Error) -> String {
        (error as? SyncAccountError)?.pairingMessage ?? "Failed: \(error)"
    }

    /// The engine's session if it is running, otherwise one minted through the device key.
    static func sessionSource(for held: SyncCredentials, service: SyncAccountService) -> SyncSessionSource {
        controller.session ?? SyncSessionProvider(
            api: service.api, vaultID: held.vaultID, serverNow: { Date().addingTimeInterval(ServerClockOffset(defaults: .standard).current) },
            rejoin: rejoin(held, service: service)
        )
    }

    static func rejoin(_ held: SyncCredentials, service: SyncAccountService) -> @Sendable () async throws -> SyncHTTPWireV1.SessionToken {
        { try await service.rejoin(held) }
    }

    // MARK: Launch and reinstall

    /// True after a launch found a vault key but no sync history: the engine waits for `resume` or `forgetAccount`.
    static var awaitingResume: Bool { controller.awaitingResume }

    static func progress(of state: SyncState) async -> SyncProgress? {
        await SyncController.progress(of: state)
    }

    /// A new device whose first cycle never succeeded has no history either, so it is asked too; Resume is harmless there.
    /// The DEBUG launch: turns the outbox on, reconciles and starts the engine, unless the Keychain holds a vault key for
    /// which this device has no sync history (a reinstall). Then it waits for the person. A launch environment that names a
    /// vault always starts.
    static func launch(
        container: ModelContainer, state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore()
    ) async {
        if let nonce = SyncTestReset.nonce(in: ProcessInfo.processInfo.arguments) {
            SyncTestReset.writeResult(await SyncTestReset.run(nonce: nonce, state: state))
            return
        }
        let startUp: () async -> Void = { await begin(container: container, state: state, credentials: credentials) }
        if usesEnvironmentVault || Environment() != nil {
            await startUp()
        } else {
            await controller.launch(container: container, state: state, credentials: credentials, begin: startUp)
        }
    }

    /// `start` replaces the engine start in tests.
    static func resume(
        container: ModelContainer, state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore(),
        start: (() async -> Void)? = nil
    ) async {
        await controller.resume(container: container, state: state, credentials: credentials, begin: start ?? {
            await begin(container: container, state: state, credentials: credentials)
        })
    }

    private static func begin(container: ModelContainer, state: SyncState, credentials: SyncCredentialStore) async {
        await state.enableForDebugging(credentials: credentials)
        await SyncReconcileRunner.reconcile(container: container, state: state)
        let seeds = SyncTestSeed.requests(in: ProcessInfo.processInfo.arguments)
        if !seeds.isEmpty {
            var store = ThoughtStore(context: container.mainContext)
            store.syncState = state
            for request in seeds { await SyncTestSeed.run(request, store: store, now: .now) }
        }
        await start(container: container, state: state, credentials: credentials)
    }

    private static func enableOutbox(state: SyncState, container: ModelContainer, vaultID: String) async throws {
        try await state.configure(vaultID: vaultID)
        await SyncReconcileRunner.reconcile(container: container, state: state)
    }

    /// `THOUGHTREPS_SYNC_MANUAL`: no debounce after a local change and no 30 s head check, so the engine runs only on launch,
    /// when the app comes to the foreground, or from the Sync lab. Lets a test edit on two devices before either syncs.
    private nonisolated static let manualSyncOnly = !(ProcessInfo.processInfo.environment["THOUGHTREPS_SYNC_MANUAL"] ?? "").isEmpty

    @discardableResult
    static func syncNow() async -> SyncEngine.Status? {
        await controller.syncNow()
    }

    /// What the status file holds: enough for a test to tell that a cycle has pushed its outbox and pulled up to a seq, and
    /// (from `Extras`, filled after a cycle) whether two devices converged. Never the secret or key.
    struct StatusSnapshot: Codable, Equatable {
        var cycles: Int
        var cursor: Int64
        var outbox: Int
        var phase: String
        var attention: String?
        var lastError: String?
        /// All thoughts in the store, conflict copies and archived ones included.
        var thoughts: Int?
        /// `SyncContentDigest` of the store.
        var digest: String?
        /// Records from a newer app version, or pointers to blobs not fetched yet.
        var parked: Int?
        /// Thoughts or records held back for any reason (a missing blob, a pending merge, the storage limit, a transport
        /// without blobs).
        var held: Int?

        struct Extras: Equatable {
            var thoughts: Int
            var digest: String
            var parked: Int
            var heldRecords: Int
        }

        init(_ status: SyncEngine.Status, extras: Extras? = nil) {
            cycles = status.cycles
            cursor = status.cursor
            outbox = status.pending
            phase = SyncLabText.phase(status.phase)
            attention = status.attention.map { SyncLabText.attention($0) }
            lastError = status.lastError
            guard let extras else { return }
            thoughts = extras.thoughts
            digest = extras.digest
            parked = extras.parked
            held = extras.heldRecords + status.blockedThoughts + status.waitingThoughts + status.oversizedThoughts
                + status.missingAttachments + status.waitingForBlobs + status.quotaExceededThoughts
        }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(self)
        }
    }

    /// `THOUGHTREPS_SYNC_STATUS_FILE`: a path the app rewrites with a `StatusSnapshot` after every cycle. A relative path
    /// is inside the app's container (`Documents/status-a.json`), which `devicectl` can pull from a device.
    private nonisolated static let statusFile: URL? = ProcessInfo.processInfo.environment["THOUGHTREPS_SYNC_STATUS_FILE"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, relativeTo: .homeDirectory) }

    private static var reportTail: Task<Void, Never>?
    private static var reportGeneration = 0

    /// Writes the snapshot for `status` after the previous report, skipping it if a newer status arrived meanwhile. The digest
    /// is computed off the main actor.
    private static func report(_ status: SyncEngine.Status) {
        guard status.phase == .idle || status.phase == .stopped else { return }
        guard statusFile != nil || SyncStatusProbe.isOn else { return }
        reportGeneration += 1
        let generation = reportGeneration
        let previous = reportTail
        let container = controller.container
        let state = controller.state
        reportTail = Task {
            await previous?.value
            guard generation == reportGeneration else { return }
            var found: StatusSnapshot.Extras?
            if let container { found = await Task.detached { try? await extras(of: container, state: state) }.value }
            let extras = found
            guard let data = try? StatusSnapshot(status, extras: extras).encoded() else { return }
            if let file = statusFile {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            if SyncStatusProbe.isOn { SyncStatusProbe.shared.json = String(decoding: data, as: UTF8.self) }
        }
    }

    private nonisolated static func extras(of container: ModelContainer, state: SyncState) async throws -> StatusSnapshot.Extras {
        let digest = try SyncContentDigest.compute(in: container)
        return StatusSnapshot.Extras(
            thoughts: digest.count, digest: digest.digest, parked: try await state.parkedCount(), heldRecords: try await state.heldCount()
        )
    }
}
#endif
