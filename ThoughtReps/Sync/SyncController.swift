import Foundation
import Observation
import SwiftData
import os

/// The app's one owner of the running sync engine: starts and stops it with its triggers (a cycle at launch, when the app
/// comes to the foreground, about 2 s after a local write, and a 30 s head check), and publishes what the Settings row and the
/// Sync lab show. One scene only, so one instance, like `AppNavigation`.
///
/// Nothing starts without a vault key in the Keychain, so a person who never set sync up never runs the engine or touches the
/// network. It is a pure reader of the engine's `Status`; the mapping to what the person sees is `SyncStatusMapping`.
@MainActor
@Observable
final class SyncController {
    static let shared = SyncController()

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "sync")

    private(set) var display: SyncDisplayStatus = .off
    private(set) var attention: SyncAttention?
    /// The footer count of thoughts that can't sync until something outside the engine changes.
    private(set) var heldThoughts = 0
    /// When the engine last finished a cycle without an error or attention state.
    private(set) var lastSyncedAt: Date?
    private(set) var engineStatus: SyncEngine.Status?
    /// A launch found a vault key but no sync history (a reinstall): the engine waits for `resume` or `forget`.
    private(set) var awaitingResume = false
    /// The server and vault the running engine syncs with (never the secret or key).
    @ObservationIgnored private(set) var target: (url: String, vault: String)?

    /// False runs the engine only at launch, on foreground and on demand: no debounce after a write and no head check.
    @ObservationIgnored var automaticTriggers = true
    /// Called on the main actor with every status the engine reports (the DEBUG status file).
    @ObservationIgnored var statusTap: (@MainActor (SyncEngine.Status) -> Void)?

    @ObservationIgnored private(set) var container: ModelContainer?
    @ObservationIgnored private(set) var state: SyncState = .shared
    @ObservationIgnored private(set) var session: SyncSessionProvider?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var triggers: SyncTriggers?
    @ObservationIgnored private var lapseSeen = false
    @ObservationIgnored private var entitlement: SyncHTTPWireV1.Entitlement.Status?
    @ObservationIgnored private var lastCycles = 0
    @ObservationIgnored private(set) var starting = false
    @ObservationIgnored private(set) var enginesBuilt = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lookupTried = false
    @ObservationIgnored private var episode = 0
    @ObservationIgnored var onEngineBuilt: ((SyncEngine) -> Void)?
    /// Fetches the account's entitlement; replaced in tests.
    @ObservationIgnored var entitlementLookup: (@MainActor (SyncSessionProvider?) async -> SyncHTTPWireV1.Entitlement.Status?) = { session in
        guard let session else { return nil }
        return try? await SyncController.accountService().entitlement(session: session).status
    }

    var isRunning: Bool { engine != nil }

    // MARK: Starting and stopping

    static func accountService() -> SyncAccountService {
        SyncAccountService(
            api: SyncAccountAPI(baseURL: SyncAccountAPI.defaultBaseURL()), apple: AuthenticationServicesSignIn(),
            credentials: KeychainSyncCredentialStore(), iCloud: ICloudKeyCopy()
        )
    }

    /// The sync state at launch; nil when there is no state file.
    static func progress(of state: SyncState) async -> SyncProgress? {
        guard state.isEnabled else { return nil }
        do {
            return SyncProgress(
                vaultID: try await state.configuredVaultID(), cursor: try await state.cursor(), epoch: try await state.epoch(),
                records: try await state.recordCount(), outbox: try await state.outboxCount()
            )
        } catch {
            logger.error("Reading the sync state failed: \(error)")
            return nil
        }
    }

    /// The launch: unless the Keychain holds a vault key for which this device has no sync history (a reinstall), turns the
    /// outbox on, reconciles and starts the engine. Then it waits for `resume`. `begin` replaces the start (the DEBUG launch).
    func launch(
        container: ModelContainer, state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore(),
        begin: (() async -> Void)? = nil
    ) async {
        if let held = try? credentials.load(),
           SyncResumeGate.needsConfirmation(heldVaultID: held.vaultID, progress: await Self.progress(of: state)) {
            awaitingResume = true
            refresh()
            return
        }
        if let begin { await begin() } else { await beginFromCredentials(container: container, state: state, credentials: credentials) }
    }

    func resume(
        container: ModelContainer, state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore(),
        begin: (() async -> Void)? = nil
    ) async {
        guard awaitingResume else { return }
        awaitingResume = false
        refresh()
        if let begin { await begin() } else { await beginFromCredentials(container: container, state: state, credentials: credentials) }
    }

    /// Turns the outbox on for the held vault, reconciles, and starts the engine on its account. Does nothing without a key.
    func beginFromCredentials(container: ModelContainer, state: SyncState, credentials: SyncCredentialStore) async {
        await state.enableFromCredentials(credentials)
        await SyncReconcileRunner.reconcile(container: container, state: state)
        do {
            guard let held = try credentials.load() else { return }
            await startAccount(container: container, state: state, credentials: held, seed: nil)
        } catch {
            Self.logger.error("Reading the sync credentials failed: \(error)")
        }
    }

    /// Runs the engine for an account vault over a bearer session, which `seed` (from sign-in or a join) starts with.
    func startAccount(
        container: ModelContainer, state: SyncState, credentials: SyncCredentials, seed: SyncHTTPWireV1.SessionToken?,
        service: SyncAccountService = SyncController.accountService()
    ) async {
        let provider = SyncSessionProvider(
            api: service.api, vaultID: credentials.vaultID,
            serverNow: { Date().addingTimeInterval(ServerClockOffset(defaults: .standard).current) },
            rejoin: { try await service.rejoin(credentials) }
        )
        if let seed { await provider.adopt(seed) }
        // A start issued while a torn-down start is still unwinding returns here without starting (accepted: the caller retries).
        guard engine == nil, !starting else { return }
        session = provider
        let transport = HTTPSyncTransport(
            baseURL: service.api.baseURL, vaultID: credentials.vaultID, auth: .session(provider), offset: ServerClockOffset(defaults: .standard)
        )
        target = (service.api.baseURL.absoluteString, credentials.vaultID)
        await start(container: container, state: state, transport: transport, key: credentials.vaultKey, vaultID: credentials.vaultID)
    }

    /// Builds the engine and triggers over `transport` and runs a first cycle.
    func start(container: ModelContainer, state: SyncState, transport: HTTPSyncTransport, key: Data, vaultID: String) async {
        guard engine == nil, !starting else { return }
        starting = true
        defer { starting = false }
        generation += 1
        let mine = generation
        do {
            var store = ThoughtStore(context: container.mainContext)
            store.syncState = state
            let local = ThoughtSyncLocal(store: store, reconcile: {
                await SyncReconcileRunner.reconcile(container: container, state: state)
            })
            let engine = SyncEngine(transport: transport, state: state, local: local, keys: try SyncKeys(vaultKey: key), vaultID: vaultID)
            enginesBuilt += 1
            onEngineBuilt?(engine)
            let triggers = SyncTriggers(engine: engine)
            if automaticTriggers { await triggers.start(observing: state) }
            await engine.setObserver { [weak self] status in
                Task { @MainActor in self?.note(status) }
            }
            guard mine == generation else {
                await triggers.stop(observing: state)
                await engine.stop()
                return
            }
            self.engine = engine
            self.triggers = triggers
            self.container = container
            self.state = state
            refresh()
            let status = await engine.syncNow()
            Self.logger.info("Sync started against \(transport.baseURL.absoluteString): \(String(describing: status))")
        } catch {
            Self.logger.error("Starting sync failed: \(error)")
        }
    }

    /// Stops the triggers and the engine (awaiting its running cycle). The key, the state file and the outbox stay.
    func stop() async {
        generation += 1
        await triggers?.stop(observing: state)
        await engine?.stop()
        engine = nil
        triggers = nil
        session = nil
        container = nil
        target = nil
        awaitingResume = false
        lapseSeen = false
        entitlement = nil
        lookupTried = false
        engineStatus = nil
        refresh()
    }

    /// Stops syncing, empties the outbox and deletes the vault key and the sync App Attest key id from the Keychain, so the
    /// next sign-in registers a fresh device with the server. Returns once the state file is gone, so nothing written after
    /// this is enqueued. The iCloud Keychain copy is left.
    func forget(
        state: SyncState = .shared, credentials: SyncCredentialStore = KeychainSyncCredentialStore(),
        attestKeys: KeyIdStore = SyncAccountAPI.defaultKeyStore()
    ) async {
        await stop()
        state.disable()
        await state.flush()
        credentials.clear()
        attestKeys.clear()
    }

    // MARK: Triggers

    /// A cycle now, or after the one running. Nil when the engine isn't running.
    @discardableResult
    func syncNow() async -> SyncEngine.Status? {
        guard let engine else { return nil }
        return await engine.syncNow()
    }

    /// The engine's own current status, which `engineStatus` trails by one main-actor hop.
    func currentEngineStatus() async -> SyncEngine.Status? {
        guard let engine else { return nil }
        return await engine.status
    }

    // MARK: Status

    func note(_ status: SyncEngine.Status) {
        guard engine != nil else { return }
        engineStatus = status
        if status.subscriptionHold != nil { lapseSeen = true }
        if status.phase == .idle, status.lastError == nil, status.attention == nil, status.subscriptionHold == nil,
           status.cycles > 0, status.cycles != lastCycles {
            lastCycles = status.cycles
            lastSyncedAt = .now
            lapseSeen = false
        }
        if case .epochChanged? = status.attention {
            if !lapseSeen, entitlement == nil, !lookupTried { lookUpEntitlement() }
        } else {
            lookupTried = false
            entitlement = nil
            episode += 1
        }
        refresh()
        statusTap?(status)
    }

    /// After an epoch change that no lapse preceded in this run (a relaunch after the purge), the account's entitlement tells a
    /// purge from another device's erase. Best effort: without an answer it reads as the erase.
    private func lookUpEntitlement() {
        lookupTried = true
        let started = generation
        let startedEpisode = episode
        let session = session
        Task {
            let found = await entitlementLookup(session)
            guard started == generation, startedEpisode == episode, let found else { return }
            entitlement = found
            refresh()
        }
    }

    private func refresh() {
        let input = SyncStatusMapping.Input(engine: engineStatus, awaitingResume: awaitingResume, lapseSeen: lapseSeen, entitlement: entitlement)
        display = SyncStatusMapping.display(input)
        attention = SyncStatusMapping.attention(input)
        heldThoughts = SyncStatusMapping.heldThoughts(engineStatus)
    }
}
