#if DEBUG
import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
struct SyncLabTests {
    @Test func attentionTextNamesTheStopReason() {
        #expect(SyncLabText.attention(nil) == "None")
        #expect(SyncLabText.attention(.epochChanged(known: 1, server: 2)) == "Epoch changed (device 1, server 2)")
        #expect(SyncLabText.attention(.serverRefused(status: 403, message: "nope")) == "Server refused: 403 nope")
    }

    @Test func phaseAndOffsetText() {
        #expect(SyncLabText.phase(.pulling) == "Pulling")
        #expect(SyncLabText.phase(.stopped) == "Stopped")
        #expect(SyncLabText.offset(1.5) == "+1.500 s")
        #expect(SyncLabText.offset(-0.25) == "-0.250 s")
    }

    @Test func checksTextCountsViolations() {
        #expect(SyncLabText.checks(violations: 0) == "Passed")
        #expect(SyncLabText.checks(violations: 1) == "Failed: 1 violation")
        #expect(SyncLabText.checks(violations: 3) == "Failed: 3 violations")
    }

    @Test func debugTargetNeverCarriesTheSecret() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let environment = SyncDebugSession.Environment([
            "THOUGHTREPS_SYNC_URL": "http://127.0.0.1:8787/api/v1", "THOUGHTREPS_SYNC_VAULT": "v1",
            "THOUGHTREPS_SYNC_DEV_SECRET": "s3cret", "THOUGHTREPS_SYNC_KEY": key,
        ])
        #expect(environment?.vault == "v1")
        #expect(SyncDebugSession.Environment(["THOUGHTREPS_SYNC_URL": "http://x", "THOUGHTREPS_SYNC_VAULT": "v1"]) == nil)
    }

    @Test func statusSnapshotEncodesTheFieldsATestWaitsOn() throws {
        var status = SyncEngine.Status()
        status.cycles = 3
        status.cursor = 42
        status.pending = 0
        status.attention = .epochChanged(known: 1, server: 2)
        let data = try SyncDebugSession.StatusSnapshot(status).encoded()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["cycles"] as? Int == 3)
        #expect(json["cursor"] as? Int == 42)
        #expect(json["outbox"] as? Int == 0)
        #expect(json["phase"] as? String == "Idle")
        #expect(json["attention"] as? String == "Epoch changed (device 1, server 2)")
        #expect(json["lastError"] == nil)
        #expect(Set(json.keys) == ["cycles", "cursor", "outbox", "phase", "attention"])
        #expect(try JSONDecoder().decode(SyncDebugSession.StatusSnapshot.self, from: data) == SyncDebugSession.StatusSnapshot(status))
    }

    @Test func runChecksReportsAnEmptyStoreAsPassed() async throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let model = SyncLabModel()
        await model.runChecks(in: container.mainContext, index: SearchIndex(location: .inMemory))
        #expect(model.checksResult == "Passed")
        #expect(model.violations.isEmpty)
    }

    @Test func runChecksCountsAThoughtMissingFromTheIndex() async throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7)
        store.create(body: "Unindexed", intervalDays: nil, now: .now)
        let model = SyncLabModel()
        await model.runChecks(in: container.mainContext, index: SearchIndex(location: .inMemory))
        #expect(model.checksResult == "Failed: 1 violation")
    }
}
#endif
