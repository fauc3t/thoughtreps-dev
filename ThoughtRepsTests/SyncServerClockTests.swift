import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// The server-clock offset and how the change-clock stamp uses it. Times are injected, never read.
@MainActor
@Suite("Sync server clock offset")
struct SyncServerClockTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    func ms(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }

    func defaults() -> UserDefaults {
        let suite = "SyncServerClockTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// One sample whose round trip is 0.1 s and whose server clock reads `ahead` seconds past the local one.
    @discardableResult
    func sample(_ offset: ServerClockOffset, at seconds: Double, ahead: Double, best: TimeInterval? = 0.1) -> ServerClockOffset.Outcome {
        offset.observe(sentAt: at(seconds), receivedAt: at(seconds + 0.1), serverTimeMs: ms(1_790_000_000 + seconds + 0.05 + ahead), bestRoundTrip: best)
    }

    @Test func nothingIsAdoptedUntilThreeSamplesAgree() {
        let offset = ServerClockOffset(defaults: defaults())
        #expect(sample(offset, at: 0, ahead: 30) == .pending)
        #expect(sample(offset, at: 10, ahead: 30.5) == .pending)
        #expect(offset.current == 0 && offset.defaults.object(forKey: ServerClockOffset.key) == nil)
        guard case .applied(let value) = sample(offset, at: 20, ahead: 29.5) else {
            Issue.record("expected the third agreeing sample to be adopted")
            return
        }
        #expect(abs(value - 30) < 0.01 && abs(offset.current - 30) < 0.01)
    }

    @Test func samplesThatDisagreeKeepTheEstimateUnadopted() {
        let offset = ServerClockOffset(defaults: defaults())
        sample(offset, at: 0, ahead: 30)
        sample(offset, at: 10, ahead: 40)
        #expect(sample(offset, at: 20, ahead: 30) == .pending, "the window of the last three spans more than 2 s")
        #expect(offset.defaults.object(forKey: ServerClockOffset.key) == nil)
        sample(offset, at: 30, ahead: 30)
        guard case .applied = sample(offset, at: 40, ahead: 30.2) else {
            Issue.record("expected adoption once the last three agree")
            return
        }
    }

    func adopted(_ ahead: Double) -> ServerClockOffset {
        let offset = ServerClockOffset(defaults: defaults())
        for i in 0..<3 { sample(offset, at: Double(i) * 10, ahead: ahead) }
        return offset
    }

    @Test func laterSamplesWithinAMinuteAreSmoothed() {
        let offset = adopted(10)
        #expect(abs(offset.current - 10) < 0.01)
        sample(offset, at: 60, ahead: 20)
        #expect(abs(offset.current - (10 * 0.7 + 20 * 0.3)) < 0.01)
    }

    @Test func aJumpOverAMinuteNeedsThreeConsecutiveAgreeingSamples() {
        let offset = adopted(10)
        #expect(sample(offset, at: 60, ahead: 200) == .pending)
        #expect(sample(offset, at: 70, ahead: 11) != .pending, "a sample near the estimate clears the pending jump")
        #expect(sample(offset, at: 80, ahead: 200) == .pending)
        #expect(sample(offset, at: 90, ahead: 200.5) == .pending)
        #expect(abs(offset.current - 10) < 1)
        guard case .applied(let value) = sample(offset, at: 100, ahead: 199.5) else {
            Issue.record("expected the real clock change to be adopted")
            return
        }
        #expect(abs(value - 200) < 0.01)
    }

    @Test func slowResponsesAreIgnored() {
        let offset = ServerClockOffset(defaults: defaults())
        #expect(offset.observe(sentAt: at(10), receivedAt: at(10.5), serverTimeMs: ms(1_790_000_010.25 + 40), bestRoundTrip: 0.1) == .slowResponse, "far slower than the best")
        #expect(offset.observe(sentAt: at(20), receivedAt: at(23), serverTimeMs: ms(1_790_000_021.5 + 40), bestRoundTrip: 2.9) == .slowResponse, "over the absolute cap")
        #expect(offset.observe(sentAt: at(30), receivedAt: at(29), serverTimeMs: ms(1_790_000_030), bestRoundTrip: nil) == .slowResponse, "time ran backwards")
        #expect(offset.defaults.object(forKey: ServerClockOffset.pendingKey) == nil)
    }

    @Test func anOffsetOverADayIsIgnored() {
        let offset = ServerClockOffset(defaults: defaults())
        let wild = sample(offset, at: 0, ahead: 90_000)
        guard case .implausible(let seconds) = wild else {
            Issue.record("expected the sample to be ignored")
            return
        }
        #expect(abs(seconds - 90_000) < 0.01)
        #expect(offset.current == 0 && offset.defaults.object(forKey: ServerClockOffset.pendingKey) == nil)
    }

    @Test func adoptingAnOffsetFloorsLaterStampsAboveTheRawClock() {
        let defaults = defaults()
        let offset = ServerClockOffset(defaults: defaults)
        for i in 0..<3 { sample(offset, at: 100 + Double(i), ahead: -30) }
        #expect(SyncClock(defaults: defaults).highestSeen >= at(102.1), "the raw clock at adoption is observed")
        #expect(SyncClock(defaults: defaults).stamp(at(105)) > at(102.1), "now - 30 s alone would be lower")
    }

    @Test func theStampMovesNowOntoTheServerClockAndStaysAboveEverythingSeen() {
        let defaults = defaults()
        let clock = SyncClock(defaults: defaults)
        #expect(clock.stamp(at(5)) == at(5))
        defaults.set(30.0, forKey: ServerClockOffset.key)
        #expect(clock.stamp(at(5)) == at(35))
        defaults.set(-30.0, forKey: ServerClockOffset.key)
        #expect(clock.stamp(at(5)) == at(-25), "nothing seen yet, so nothing to floor it")
        clock.observe(at(100))
        #expect(clock.stamp(at(5)) == at(100).addingTimeInterval(0.001))
        clock.reset()
        #expect(clock.serverOffset == 0 && clock.highestSeen == .distantPast)
    }

    func syncingStore(_ defaults: UserDefaults) async throws -> (store: ThoughtStore, container: ModelContainer) {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), save: { try $0.save() })
        store.pendingImageSaves = PendingImageSaves(defaults: defaults)
        store.ratingPrompt = RatingPrompt(defaults: defaults)
        store.searchIndex = SearchIndex(location: .inMemory)
        store.syncDefaults = defaults
        let state = SyncState(location: .inMemory)
        try await state.configure(vaultID: "v")
        store.syncState = state
        return (store, container)
    }

    @Test func everyStampWhileSyncIsOnIsRememberedSoNoneIsLower() async throws {
        let defaults = defaults()
        let (store, container) = try await syncingStore(defaults)
        defer { withExtendedLifetime(container) {} }
        defaults.set(-60.0, forKey: ServerClockOffset.key)
        let first = store.stamp(at(100))
        #expect(first == at(40))
        #expect(SyncClock(defaults: defaults).highestSeen == first)
        let second = store.stamp(at(100))
        #expect(second > first, "the same instant stamps later the second time")
        defaults.set(-120.0, forKey: ServerClockOffset.key)
        #expect(store.stamp(at(101)) > second, "a lower offset can't lower a stamp")
    }

    @Test func withSyncOffNothingIsRemembered() throws {
        let defaults = defaults()
        let container = try ModelContainer.thoughtReps(inMemory: true)
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), save: { try $0.save() })
        store.syncDefaults = defaults
        #expect(store.stamp(at(5)) == at(5))
        #expect(SyncClock(defaults: defaults).highestSeen == .distantPast)
    }

    @Test func aWriteStampsWithTheOffsetButKeepsRealTimesForDueDates() async throws {
        let defaults = defaults()
        let (store, container) = try await syncingStore(defaults)
        defer { withExtendedLifetime(container) {} }
        defaults.set(120.0, forKey: ServerClockOffset.key)
        let thought = store.create(body: "x", now: at(0))
        #expect(thought.updatedAt == at(120))
        #expect(thought.createdAt == at(0))
        #expect(thought.nextDueAt == at(0).addingTimeInterval(7 * 86_400))
    }

    /// A device whose clock runs 30 s ahead pins, then learns the offset (-30 s) and unpins: the unpin must not stamp
    /// below the pin, or the other device would reject it and the two would diverge.
    @Test func anUnpinAfterAdoptingANegativeOffsetStillWins() async throws {
        let server = FakeSyncServer()
        let a = try await SyncDevice("A", server: server, clockOffset: 30)
        let b = try await SyncDevice("B", server: server)
        let thought = a.store.create(body: "pin me", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.setPinned(thought, true, now: a.now(at(1)))
        await a.sync()
        await b.sync()
        #expect(try b.thought(thought.id)?.isPinned == true)

        let offset = ServerClockOffset(defaults: a.defaults)
        for i in 0..<3 { sample(offset, wall: a.now(at(2 + Double(i))), serverTime: at(2 + Double(i))) }
        #expect(abs(offset.current + 30) < 0.01)

        a.store.setPinned(thought, false, now: a.now(at(10)))
        #expect(thought.stateChangedAt > a.now(at(1)))
        await a.sync()
        await b.sync()
        #expect(try b.thought(thought.id)?.isPinned == false)
        #expect(try a.canonicalDump() == b.canonicalDump())
    }

    func sample(_ offset: ServerClockOffset, wall: Date, serverTime: Date) {
        offset.observe(sentAt: wall, receivedAt: wall.addingTimeInterval(0.1), serverTimeMs: ms(serverTime.timeIntervalSince1970 + 0.05), bestRoundTrip: 0.1)
    }
}
