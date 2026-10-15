import Foundation
import Testing
@testable import ThoughtReps

@Suite("SyncState pages, held records and blobs")
struct SyncStatePagesTests {
    let state = SyncState(location: .inMemory)

    func enabled() async throws -> SyncState {
        try await state.configure(vaultID: "vault-1")
        return state
    }

    func held(_ key: String, entity: String = "e1", seq: Int64 = 1) -> HeldRecord {
        HeldRecord(recordKey: key, type: .thoughtMeta, entityID: entity, seq: seq, payload: Data("{}".utf8))
    }

    @Test func aPageCommitsRecordsHeldRecordsCursorAndEpochTogether() async throws {
        let state = try await enabled()
        try await state.commit(PageCommit(
            records: [syncedRecord("a", seq: 3), syncedRecord("b", seq: 4)], hold: [held("m1", entity: "e9", seq: 2)], cursor: 4, epoch: 7
        ))
        #expect(try await state.cursor() == 4)
        #expect(try await state.epoch() == 7)
        #expect(try await state.records(forKeys: ["a", "b", "zzz"]).keys.sorted() == ["a", "b"])
        #expect(try await state.held(entityIDs: ["e9"]).map(\.recordKey) == ["m1"])
        #expect(try await state.heldCount() == 1)
    }

    @Test func releasingAnEntityDropsItsHeldRecordsAndANewVersionReplacesTheOld() async throws {
        let state = try await enabled()
        try await state.commit(PageCommit(hold: [held("m1", seq: 1)], cursor: 1, epoch: 1))
        try await state.commit(PageCommit(hold: [held("m1", seq: 5)], cursor: 5, epoch: 1))
        #expect(try await state.held(entityIDs: ["e1"]).map(\.seq) == [5])
        try await state.commit(PageCommit(release: ["e1"], cursor: 6, epoch: 1))
        #expect(try await state.heldCount() == 0)
        try await state.commit(PageCommit(hold: [held("m1")], cursor: 7, epoch: 1))
        try await state.releaseHeld(entityIDs: ["e1"])
        #expect(try await state.heldCount() == 0)
    }

    @Test func aPageQueuesItsRequeuedEntitiesInTheSameTransaction() async throws {
        let state = try await enabled()
        let id = UUID()
        try await state.commit(PageCommit(requeue: [.thought(id), .tag("swift")], cursor: 2, epoch: 1))
        #expect(Set(try await state.outbox(limit: 10).map(\.entity)) == [.thought(id), .tag("swift")])
        try await state.commit(PageCommit(requeue: [.thought(id)], cursor: 3, epoch: 1))
        #expect(try await state.outbox(limit: 10).first { $0.entity == .thought(id) }?.generation == 2)
    }

    @Test func aSecondResetKeepsTheUnresolvedSnapshot() async throws {
        let state = try await enabled()
        try await state.commit(PageCommit(records: [syncedRecord("k1", entityID: "e1")], cursor: 1, epoch: 1))
        try await state.resetSyncProgress(keepingEpoch: true, snapshotting: true)
        try await state.commit(PageCommit(records: [syncedRecord("k2", entityID: "e2")], cursor: 2, epoch: 1))
        try await state.resetSyncProgress(keepingEpoch: true, snapshotting: true)
        #expect(try await state.missingFromServer(after: nil, limit: 10).map(\.id) == ["e1"])
        try await state.replaceResyncSnapshot([])
        #expect(try await state.hasResyncSnapshot() == false)
    }

    @Test func blobsAreRememberedAndSurviveAResyncReset() async throws {
        let state = try await enabled()
        try await state.markBlobsUploaded(["x", "y"])
        #expect(try await state.uploadedBlobs(among: ["x", "z"]) == ["x"])
        try await state.commit(PageCommit(records: [syncedRecord("a")], hold: [held("m")], cursor: 9, epoch: 3))
        try await state.resetSyncProgress(keepingBlobs: true, keepingEpoch: true)
        #expect(try await state.cursor() == 0)
        #expect(try await state.recordCount() == 0)
        #expect(try await state.heldCount() == 0)
        #expect(try await state.epoch() == 3)
        #expect(try await state.uploadedBlobs(among: ["x", "y"]) == ["x", "y"])
        try await state.resetSyncProgress()
        #expect(try await state.epoch() == nil)
        #expect(try await state.uploadedBlobs(among: ["x"]).isEmpty)
        #expect(try await state.configuredVaultID() == "vault-1")
    }

    @Test func theEnqueueObserverHearsOnlyAcceptedEnqueues() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let counter = Counter()
        state.setEnqueueObserver { counter.increment() }
        state.enqueue([.settings])
        #expect(counter.count == 0, "sync is off")
        try await state.configure(vaultID: "vault-1")
        state.enqueue([.settings])
        state.enqueue([])
        #expect(counter.count == 1)
        state.setEnqueueObserver(nil)
        state.enqueue([.settings])
        #expect(counter.count == 1)
    }

    @Test func blobNamesAreStableOpaqueAndSealedWithTheBlobKey() throws {
        let keys = try SyncKeys(vaultKey: Data(repeating: 4, count: 32))
        let id = UUID()
        let name = keys.blobName(kind: .image, id: id)
        #expect(name == keys.blobName(kind: .image, id: id))
        #expect(name != keys.blobName(kind: .file, id: id))
        #expect(!name.contains(id.uuidString))
        let sealed = try SyncCrypto.sealBlob(Data("pixels".utf8), vaultID: "v", name: name, keys: keys)
        #expect(try SyncCrypto.openBlob(sealed, vaultID: "v", name: name, keys: keys) == Data("pixels".utf8))
        #expect(throws: SyncCrypto.Failure.decryptionFailed) { try SyncCrypto.openBlob(sealed, vaultID: "v", name: "other", keys: keys) }
        #expect(throws: SyncCrypto.Failure.badFormat) { try SyncCrypto.openBlob(Data("junk".utf8), vaultID: "v", name: name, keys: keys) }
    }
}
