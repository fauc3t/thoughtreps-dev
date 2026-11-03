import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync subscription hold and push storage limit")
struct SyncSubscriptionAndQuotaTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func aLapsedSubscriptionPausesWithTheOutboxKeptAndAHeadCheckResumesIt() async throws {
        let a = try await SyncDevice("A", server: server)
        a.store.create(body: "one", now: a.now(at(0)))
        await server.requireSubscription(entitledUntil: 1_000, purgeAt: 2_000)

        let held = await a.sync()
        #expect(held.subscriptionHold == SyncEngine.SubscriptionHold(entitledUntil: 1_000, purgeAt: 2_000))
        #expect(held.attention == nil && held.phase == .idle && held.lastError == nil, "a hold is not a stop")
        #expect(held.pending > 0, "the outbox is kept")
        #expect(await server.pushCalls == 0)

        #expect(await a.engine.syncIfHeadMoved() == false)
        #expect(await a.engine.status.subscriptionHold != nil, "still lapsed")

        await server.clearSubscriptionRequirement()
        #expect(await a.engine.syncIfHeadMoved(), "the head answered, so a cycle runs")
        let resumed = await a.engine.status
        #expect(resumed.subscriptionHold == nil && resumed.pending == 0 && resumed.attention == nil)
        #expect(await server.liveRecordCount > 0)
    }

    @Test func aLaterCycleEndsTheHoldToo() async throws {
        let a = try await SyncDevice("A", server: server)
        a.store.create(body: "one", now: a.now(at(0)))
        await server.requireSubscription()
        let held = await a.sync()
        #expect(held.subscriptionHold == SyncEngine.SubscriptionHold(entitledUntil: nil, purgeAt: nil))

        await server.clearSubscriptionRequirement()
        let resumed = await a.sync()
        #expect(resumed.subscriptionHold == nil && resumed.pending == 0 && resumed.lastError == nil)
    }

    @Test func aHoldReportsToTheObserver() async throws {
        let a = try await SyncDevice("A", server: server)
        let seen = LockedBox<[SyncEngine.Status]>([])
        await a.engine.setObserver { status in seen.mutate { $0.append(status) } }
        await server.requireSubscription(purgeAt: 5)
        await a.sync()
        #expect(seen.value.contains { $0.subscriptionHold?.purgeAt == 5 })
    }

    @Test func aPushThatGrowsStorageIsHeldWhileDeletesStillGoOut() async throws {
        let a = try await SyncDevice("A", server: server)
        a.store.create(body: "keep", now: a.now(at(0)))
        let drop = a.store.create(body: "drop", now: a.now(at(1)))
        let dropID = drop.id
        await a.sync()
        await a.sync()
        await server.refuseGrowingPushes()

        a.store.create(body: String(repeating: "this grows the vault ", count: 100), now: a.now(at(10)))
        a.store.delete(drop, now: a.now(at(11)))
        let status = await a.sync()

        #expect(status.quotaExceededThoughts == 1 && status.pending == 1)
        #expect(status.blobQuota == SyncEngine.BlobQuota(usedBytes: 100, limitBytes: 100))
        #expect(status.attention == nil && status.lastError == nil)
        let contentKey = a.keys.recordKey(type: .thoughtContent, entityID: dropID.uuidString)
        #expect(await server.rows[contentKey]?.deleted == true, "the delete went out in the same cycle")

        await server.refuseGrowingPushes(false)
        let released = await a.sync()
        #expect(released.quotaExceededThoughts == 0 && released.pending == 0 && released.blobQuota == nil)
    }

    @Test func whenEveryThoughtGrowsAllAreHeldAndNothingStops() async throws {
        let a = try await SyncDevice("A", server: server)
        await server.refuseGrowingPushes()
        for index in 0..<3 { a.store.create(body: "thought \(index)", now: a.now(at(Double(index)))) }
        let status = await a.sync()
        #expect(status.quotaExceededThoughts == status.pending && status.pending >= 3, "the settings entry waits with the thoughts")
        #expect(status.attention == nil && status.phase == .idle)
        #expect(await server.liveRecordCount == 0)
    }
}

extension SyncSubscriptionAndQuotaTests {
    private func heldDevice() async throws -> (device: SyncDevice, thought: Thought) {
        let a = try await SyncDevice("A", server: server)
        await a.sync()
        await server.refuseGrowingPushes()
        let big = a.store.create(body: String(repeating: "this grows the vault ", count: 100), now: a.now(at(10)))
        let status = await a.sync()
        #expect(status.quotaExceededThoughts == 1)
        return (a, big)
    }

    @Test func aHeldThoughtIsNotSentAgainByTheNextDebouncedCycle() async throws {
        let (a, _) = try await heldDevice()
        let before = await server.pushCalls
        await a.engine.syncAfterLocalChange()
        #expect(await server.pushCalls == before, "nothing new to send, and the held thought is left alone")
        #expect(await a.engine.status.quotaExceededThoughts == 1)
    }

    @Test func aForegroundRunRetriesHeldThoughts() async throws {
        let (a, _) = try await heldDevice()
        let before = await server.pushCalls
        await a.engine.syncNow()
        #expect(await server.pushCalls > before)
        await server.refuseGrowingPushes(false)
        let released = await a.sync()
        #expect(released.quotaExceededThoughts == 0 && released.pending == 0)
    }

    @Test func aHeadMoveRetriesHeldThoughts() async throws {
        let (a, _) = try await heldDevice()
        let b = try await SyncDevice("B", server: server)
        await server.refuseGrowingPushes(false)
        b.store.create(body: "from b", now: b.now(at(20)))
        await b.sync()
        await server.refuseGrowingPushes()
        let before = await server.pushCalls
        #expect(await a.engine.syncIfHeadMoved())
        #expect(await server.pushCalls > before, "the held thought was tried again")
    }

    @Test func anEditToAHeldThoughtRetriesItOnce() async throws {
        let (a, big) = try await heldDevice()
        await server.refuseGrowingPushes(false)
        a.store.update(big, body: "shrunk", blocks: [], intervalDays: nil, now: a.now(at(30)))
        await a.engine.syncAfterLocalChange()
        let released = await a.engine.status
        #expect(released.quotaExceededThoughts == 0 && released.pending == 0)
    }

    @Test func aLapsedSubscriptionMakesNoRequestOnALocalWriteButTheHeadCheckProbes() async throws {
        let a = try await SyncDevice("A", server: server)
        await a.sync()
        await server.requireSubscription()
        await a.sync()
        #expect(await a.engine.status.subscriptionHold != nil)
        let before = await server.callCount
        a.store.create(body: "written while lapsed", now: a.now(at(10)))
        await a.engine.syncAfterLocalChange()
        #expect(await server.callCount == before)

        await server.clearSubscriptionRequirement()
        #expect(await a.engine.syncIfHeadMoved())
        let resumed = await a.engine.status
        #expect(resumed.subscriptionHold == nil && resumed.pending == 0)
    }

    @Test func deletesStillGoOutWhileThoughtsAreHeld() async throws {
        let a = try await SyncDevice("A", server: server)
        let drop = a.store.create(body: "drop", now: a.now(at(0)))
        let dropID = drop.id
        await a.sync()
        await server.refuseGrowingPushes()
        a.store.create(body: String(repeating: "this grows the vault ", count: 100), now: a.now(at(10)))
        await a.sync()
        a.store.delete(drop, now: a.now(at(11)))
        await a.engine.syncAfterLocalChange()
        let contentKey = a.keys.recordKey(type: .thoughtContent, entityID: dropID.uuidString)
        #expect(await server.rows[contentKey]?.deleted == true)
        #expect(await a.engine.status.quotaExceededThoughts == 1)
    }

    @Test func aDeleteThatFreesQuotaReleasesHeldThoughtsOnTheNextCycle() async throws {
        let a = try await SyncDevice("A", server: server)
        let drop = a.store.create(body: "drop", now: a.now(at(0)))
        await a.sync()
        await server.refuseGrowingPushes()
        a.store.create(body: String(repeating: "this grows the vault ", count: 100), now: a.now(at(10)))
        await a.sync()
        #expect(await a.engine.status.quotaExceededThoughts == 1)
        a.store.delete(drop, now: a.now(at(11)))
        await a.engine.syncAfterLocalChange()
        #expect(await a.engine.status.quotaExceededThoughts == 1)

        await server.refuseGrowingPushes(false)
        await a.engine.syncAfterLocalChange()
        let released = await a.engine.status
        #expect(released.quotaExceededThoughts == 0 && released.pending == 0)
    }

    @Test func writesMadeDuringAHoldDrainWhenTheHeadCheckEndsIt() async throws {
        let a = try await SyncDevice("A", server: server)
        await a.sync()
        await server.requireSubscription()
        await a.sync()
        a.store.create(body: "during the hold one", now: a.now(at(10)))
        await a.engine.syncAfterLocalChange()
        a.store.create(body: "during the hold two", now: a.now(at(11)))
        await a.engine.syncAfterLocalChange()
        let before = await server.liveRecordCount

        await server.clearSubscriptionRequirement()
        #expect(await a.engine.syncIfHeadMoved())
        let resumed = await a.engine.status
        #expect(resumed.subscriptionHold == nil && resumed.pending == 0)
        #expect(await server.liveRecordCount >= before + 4, "both thoughts' content and meta records went up")
    }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

@Suite("Sync attention mapping")
struct SyncAttentionMappingTests {
    func input(_ configure: (inout SyncEngine.Status) -> Void = { _ in }, resume: Bool = false, lapseSeen: Bool = false, entitlement: SyncHTTPWireV1.Entitlement.Status? = nil) -> SyncStatusMapping.Input {
        var status = SyncEngine.Status()
        status.cycles = 3
        configure(&status)
        return SyncStatusMapping.Input(engine: status, awaitingResume: resume, lapseSeen: lapseSeen, entitlement: entitlement)
    }

    @Test func withoutAnEngineItIsOffOrWaitingForResume() {
        #expect(SyncStatusMapping.display(.init(engine: nil)) == .off)
        #expect(SyncStatusMapping.display(.init(engine: nil, awaitingResume: true)) == .paused)
        #expect(SyncStatusMapping.attention(.init(engine: nil)) == nil)
    }

    @Test func aLapseCarriesThePurgeDate() {
        let lapsed = input { $0.subscriptionHold = .init(entitledUntil: 1_767_225_600_000, purgeAt: 1_769_817_600_000) }
        #expect(SyncStatusMapping.attention(lapsed) == .subscriptionLapsed(purgeAt: Date(timeIntervalSince1970: 1_769_817_600)))
        #expect(SyncStatusMapping.display(lapsed) == .needsAttention(.subscriptionLapsed(purgeAt: Date(timeIntervalSince1970: 1_769_817_600))))
        let never = input { $0.subscriptionHold = .init(entitledUntil: nil, purgeAt: nil) }
        #expect(SyncStatusMapping.attention(never) == .subscriptionLapsed(purgeAt: nil))
    }

    @Test func anEpochChangeAfterALapseOrAnEndedSubscriptionIsAPurge() {
        let changed: (inout SyncEngine.Status) -> Void = { $0.attention = .epochChanged(known: 1, server: 2); $0.phase = .stopped }
        #expect(SyncStatusMapping.attention(input(changed, lapseSeen: true)) == .syncedCopyPurged)
        #expect(SyncStatusMapping.attention(input(changed, entitlement: .expired)) == .syncedCopyPurged)
        #expect(SyncStatusMapping.attention(input(changed, entitlement: .revoked)) == .syncedCopyPurged)
    }

    @Test func anEpochChangeWithAnActiveOrUnknownSubscriptionIsAnEraseElsewhere() {
        let changed: (inout SyncEngine.Status) -> Void = { $0.attention = .epochChanged(known: 1, server: 2); $0.phase = .stopped }
        #expect(SyncStatusMapping.attention(input(changed)) == .resetFromAnotherDevice)
        #expect(SyncStatusMapping.attention(input(changed, entitlement: .active)) == .resetFromAnotherDevice)
        #expect(SyncStatusMapping.attention(input(changed, entitlement: .grace)) == .resetFromAnotherDevice)
    }

    @Test func storageFullCountsTheWaitingThoughts() {
        let full = input { $0.quotaExceededThoughts = 12 }
        #expect(SyncStatusMapping.attention(full) == .storageFull(waitingThoughts: 12))
    }

    @Test func updateRequiredIsItsOwnState() {
        #expect(SyncStatusMapping.attention(input { $0.updateRequired = true }) == .updateRequired)
    }

    @Test func removedByAnotherDeviceIs401Or403AndOtherRefusalsStop() {
        for code in [401, 403] {
            let removed = input { $0.attention = .serverRefused(status: code, message: "x"); $0.phase = .stopped }
            #expect(SyncStatusMapping.attention(removed) == .removedFromSync)
        }
        for code in [400, 404, 410] {
            let other = input { $0.attention = .serverRefused(status: code, message: "x"); $0.phase = .stopped }
            #expect(SyncStatusMapping.attention(other) == .syncStopped(status: code))
        }
    }

    @Test func theMostSevereStateWins() {
        let all = input {
            $0.attention = .serverRefused(status: 403, message: "")
            $0.subscriptionHold = .init(entitledUntil: nil, purgeAt: nil)
            $0.quotaExceededThoughts = 2
            $0.updateRequired = true
        }
        #expect(SyncStatusMapping.attention(all) == .removedFromSync)
        let lapseAndQuota = input {
            $0.subscriptionHold = .init(entitledUntil: nil, purgeAt: nil)
            $0.quotaExceededThoughts = 2
            $0.updateRequired = true
        }
        #expect(SyncStatusMapping.attention(lapseAndQuota) == .subscriptionLapsed(purgeAt: nil))
        let quotaAndUpdate = input { $0.quotaExceededThoughts = 2; $0.updateRequired = true }
        #expect(SyncStatusMapping.attention(quotaAndUpdate) == .storageFull(waitingThoughts: 2))
    }

    @Test func heldThoughtsAreTheOnesOnlyAFixCanRelease() {
        var status = SyncEngine.Status()
        status.oversizedThoughts = 1
        status.missingAttachments = 2
        status.waitingForBlobs = 4
        status.blockedThoughts = 8
        status.waitingThoughts = 16
        status.quotaExceededThoughts = 32
        #expect(SyncStatusMapping.heldThoughts(status) == 15)
        #expect(SyncStatusMapping.heldThoughts(nil) == 0)
        #expect(SyncStatusMapping.attention(.init(engine: status)) == .storageFull(waitingThoughts: 32), "held thoughts alone are a footer, not an attention state")
        status.quotaExceededThoughts = 0
        #expect(SyncStatusMapping.attention(.init(engine: status)) == nil)
    }

    @Test func displayFollowsThePhaseAndTheLastCycle() {
        #expect(SyncStatusMapping.display(input()) == .upToDate)
        #expect(SyncStatusMapping.display(input { $0.phase = .pulling }) == .syncing)
        #expect(SyncStatusMapping.display(input { $0.phase = .pushing }) == .syncing)
        #expect(SyncStatusMapping.display(input { $0.cycles = 0 }) == .syncing)
        #expect(SyncStatusMapping.display(input { $0.lastError = "offline" }) == .paused)
    }
}

private final class MemoryCredentials: SyncCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: SyncCredentials?
    init(_ value: SyncCredentials? = nil) { self.value = value }
    func load() throws -> SyncCredentials? { lock.withLock { value } }
    func save(_ credentials: SyncCredentials) throws { lock.withLock { value = credentials } }
    func clear() { lock.withLock { value = nil } }
}

private final class MemoryKeyId: KeyIdStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = "key"
    func load() throws -> String? { lock.withLock { value } }
    func save(_ keyId: String) throws { lock.withLock { value = keyId } }
    func clear() { lock.withLock { value = nil } }
}

@MainActor
@Suite("Sync controller")
struct SyncControllerTests {
    let held = SyncCredentials(vaultKey: Data(repeating: 7, count: 32), vaultID: "vault-1", userID: "user-1")

    @Test func withoutAKeyNothingStarts() async throws {
        let controller = SyncController()
        let container = try ModelContainer.thoughtReps(inMemory: true)
        await controller.launch(container: container, state: SyncState(location: .inMemory), credentials: MemoryCredentials())
        #expect(!controller.isRunning && !controller.awaitingResume)
        #expect(controller.display == .off && controller.attention == nil && controller.heldThoughts == 0)
    }

    @Test func aKeyWithoutHistoryWaitsForResumeAndResumeRunsTheStart() async throws {
        let controller = SyncController()
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let state = SyncState(location: .inMemory)
        let started = LockedCounter()
        await controller.launch(container: container, state: state, credentials: MemoryCredentials(held), begin: { started.bump() })
        #expect(controller.awaitingResume && controller.display == .paused && started.value == 0)

        await controller.resume(container: container, state: state, credentials: MemoryCredentials(held), begin: { started.bump() })
        #expect(!controller.awaitingResume && started.value == 1)
        #expect(controller.display == .off, "the replaced start ran no engine")
    }

    @Test func aKeyWithHistoryStartsWithoutAsking() async throws {
        let controller = SyncController()
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let state = SyncState(location: .inMemory)
        try await state.configure(vaultID: held.vaultID)
        try await state.setEpoch(1)
        let started = LockedCounter()
        await controller.launch(container: container, state: state, credentials: MemoryCredentials(held), begin: { started.bump() })
        #expect(!controller.awaitingResume && started.value == 1)
    }

    @Test func forgettingClearsTheKeyTheDeviceKeyAndTheWait() async throws {
        let controller = SyncController()
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let state = SyncState(location: .inMemory)
        let credentials = MemoryCredentials(held)
        let keyIds = MemoryKeyId()
        await controller.launch(container: container, state: state, credentials: credentials)
        #expect(controller.awaitingResume)
        await controller.forget(state: state, credentials: credentials, attestKeys: keyIds)
        #expect(!controller.awaitingResume && controller.display == .off)
        #expect(try credentials.load() == nil && (try keyIds.load()) == nil && !state.isEnabled)
    }
}

extension SyncControllerTests {
    private func transport() -> HTTPSyncTransport {
        HTTPSyncTransport(baseURL: URL(string: "http://127.0.0.1:1")!, vaultID: held.vaultID, devSecret: "x", sleep: { _ in })
    }

    private func running(_ controller: SyncController) async throws {
        controller.automaticTriggers = false
        let container = try ModelContainer.thoughtReps(inMemory: true)
        await controller.start(container: container, state: SyncState(location: .inMemory), transport: transport(), key: held.vaultKey, vaultID: held.vaultID)
        #expect(controller.isRunning)
    }

    private func status(cycles: Int, hold: Bool = false, epochChanged: Bool = false) -> SyncEngine.Status {
        var status = SyncEngine.Status()
        status.cycles = cycles
        status.phase = .idle
        if hold { status.subscriptionHold = .init(entitledUntil: nil, purgeAt: nil) }
        if epochChanged { status.attention = .epochChanged(known: 1, server: 2) }
        return status
    }

    @Test func aLapseIsForgottenOnceSyncResumesSoALaterEraseReadsAsAnErase() async throws {
        let controller = SyncController()
        controller.entitlementLookup = { _ in .active }
        try await running(controller)
        controller.note(status(cycles: 100, hold: true))
        controller.note(status(cycles: 101))
        controller.note(status(cycles: 102, epochChanged: true))
        #expect(controller.attention == .resetFromAnotherDevice)
    }

    @Test func aLapseThenAnEpochChangeInTheSameRunStaysAPurge() async throws {
        let controller = SyncController()
        try await running(controller)
        controller.note(status(cycles: 100, hold: true))
        controller.note(status(cycles: 101, epochChanged: true))
        #expect(controller.attention == .syncedCopyPurged)
    }

    @Test func twoConcurrentStartsBuildOneEngine() async throws {
        let controller = SyncController()
        controller.automaticTriggers = false
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let state = SyncState(location: .inMemory)
        async let first: Void = controller.start(container: container, state: state, transport: transport(), key: held.vaultKey, vaultID: held.vaultID)
        async let second: Void = controller.start(container: container, state: state, transport: transport(), key: held.vaultKey, vaultID: held.vaultID)
        _ = await (first, second)
        #expect(controller.isRunning)
        #expect(controller.enginesBuilt == 1)
    }

    @Test func anEraseAfterAPurgeAndResubscribeIsNotReadAsAPurgeAgain() async throws {
        let controller = SyncController()
        let calls = LockedCounter()
        controller.entitlementLookup = { _ in calls.bump(); return calls.value == 1 ? .expired : nil }
        try await running(controller)
        controller.note(status(cycles: 1, epochChanged: true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.attention == .syncedCopyPurged)
        controller.note(status(cycles: 2))
        controller.note(status(cycles: 3, epochChanged: true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.attention == .resetFromAnotherDevice)
    }

    @Test func aSecondConcurrentStartAccountKeepsTheFirstSession() async throws {
        struct Declines: AppleSignIn {
            func identityToken(nonce: String) async throws -> String { throw SyncAccountError.appleSignInCancelled }
        }
        let controller = SyncController()
        controller.automaticTriggers = false
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let state = SyncState(location: .inMemory)
        let service = SyncAccountService(api: SyncAccountAPI(baseURL: URL(string: "http://127.0.0.1:1")!), apple: Declines(), credentials: MemoryCredentials())
        let seed = SyncHTTPWireV1.SessionToken(token: "seed", expiresAt: 4_102_444_800_000)
        async let first: Void = controller.startAccount(container: container, state: state, credentials: held, seed: seed, service: service)
        let second = SyncCredentials(vaultKey: Data(repeating: 8, count: 32), vaultID: "vault-2", userID: "user-2")
        async let other: Void = controller.startAccount(container: container, state: state, credentials: second, seed: seed, service: service)
        _ = await (first, other)
        #expect(controller.isRunning && controller.enginesBuilt == 1)
        #expect(controller.target?.vault == held.vaultID)
        #expect(controller.session?.vaultID == held.vaultID)
    }

    @Test func forgetDuringAStartLeavesNoEngine() async throws {
        let controller = SyncController()
        let built = BuiltEngines()
        controller.onEngineBuilt = { built.add($0) }
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let state = SyncState(location: .inMemory)
        let startTask = Task { @MainActor in
            await controller.start(container: container, state: state, transport: transport(), key: held.vaultKey, vaultID: held.vaultID)
        }
        while !controller.starting { await Task.yield() }
        await controller.forget(state: state, credentials: MemoryCredentials(held), attestKeys: MemoryKeyId())
        await startTask.value
        #expect(!controller.isRunning && controller.display == .off)
        let engine = try #require(built.engines.first)
        #expect(await engine.isShutDown)
        #expect(!state.hasEnqueueObserver)
    }

    @Test func aLateEntitlementAfterStopIsIgnoredAndRepeatedNotesLookUpOnce() async throws {
        let controller = SyncController()
        let calls = LockedCounter()
        let gate = AsyncStream<Void>.makeStream()
        controller.entitlementLookup = { _ in
            calls.bump()
            for await _ in gate.stream { break }
            return .expired
        }
        try await running(controller)
        controller.note(status(cycles: 1, epochChanged: true))
        controller.note(status(cycles: 1, epochChanged: true))
        await Task.yield()
        #expect(calls.value == 1)
        await controller.stop()
        gate.continuation.yield()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.attention == nil && controller.display == .off)
    }

    @Test func aLookupInFlightWhenTheEpisodeEndsDoesNotRestoreAnEntitlement() async throws {
        let controller = SyncController()
        let gate = AsyncStream<Void>.makeStream()
        controller.entitlementLookup = { _ in
            for await _ in gate.stream { break }
            return .expired
        }
        try await running(controller)
        controller.note(status(cycles: 1, epochChanged: true))
        await Task.yield()
        controller.note(status(cycles: 2))
        gate.continuation.yield()
        try await Task.sleep(for: .milliseconds(100))
        controller.note(status(cycles: 3, epochChanged: true))
        #expect(controller.attention != .syncedCopyPurged)
    }
}

private final class BuiltEngines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [SyncEngine] = []
    var engines: [SyncEngine] { lock.withLock { all } }
    func add(_ engine: SyncEngine) { lock.withLock { all.append(engine) } }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}
