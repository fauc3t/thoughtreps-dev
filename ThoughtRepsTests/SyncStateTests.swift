import Foundation
import Testing
@testable import ThoughtReps

func temporarySyncFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "SyncStateTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "sync.sqlite")
}

func syncedRecord(
    _ key: String = "key", type: SyncRecordType = .thoughtContent, entityID: String = "entity", seq: Int64 = 1,
    fingerprint: String = "c1", content: String = "{}"
) -> SyncedRecord {
    SyncedRecord(
        recordKey: key, type: type, entityID: entityID, seq: seq, fingerprint: fingerprint,
        baseHash: SyncPayload.hash(of: Data(content.utf8)), baseContent: Data(content.utf8)
    )
}

@Suite("SyncState")
struct SyncStateTests {
    let state = SyncState(location: .inMemory)

    func enabled() async throws -> SyncState {
        try await state.configure(vaultID: "vault-1")
        return state
    }

    @Test func offByDefaultAndEnqueueIsANoOp() async throws {
        #expect(!state.isEnabled)
        state.enqueue([.settings])
        await #expect(throws: SyncState.Failure.notConfigured) { try await state.outboxCount() }
        #expect(!state.isEnabled)
    }

    @Test func offDoesNotCreateTheFile() async throws {
        let url = temporarySyncFile()
        let off = SyncState(location: .file(url))
        off.enqueue([.thought(UUID())])
        await off.flush()
        #expect(!off.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func enqueueIsIdempotentAndBumpsGeneration() async throws {
        let state = try await enabled()
        let id = UUID()
        state.enqueue([.thought(id), .thought(id), .tag("swift")])
        state.enqueue([.thought(id)])
        let entries = try await state.outbox(limit: 10)
        #expect(entries.count == 2)
        #expect(entries.first { $0.entity == .thought(id) }?.generation == 3)
        #expect(entries.first { $0.entity == .tag("swift") }?.generation == 1)
        #expect(try await state.outboxCount() == 2)
    }

    @Test func outboxPagesInEntityOrder() async throws {
        let state = try await enabled()
        let ids = (0..<5).map { _ in UUID() }
        state.enqueue(ids.map(SyncEntity.thought))
        state.enqueue([.settings, .tag("a")])
        var seen: [SyncEntity] = []
        var after: SyncEntity?
        while true {
            let page = try await state.outbox(limit: 3, after: after)
            seen += page.map(\.entity)
            guard let last = page.last, page.count == 3 else { break }
            after = last.entity
        }
        #expect(seen.count == 7)
        #expect(Set(seen) == Set(ids.map(SyncEntity.thought) + [.settings, .tag("a")]))
        #expect(seen.map(\.kind.rawValue) == seen.map(\.kind.rawValue).sorted())
    }

    @Test func markSyncedDequeuesWhatWasPushed() async throws {
        let state = try await enabled()
        let id = UUID()
        state.enqueue([.thought(id)])
        let pushed = try await state.outbox(limit: 10)
        let record = syncedRecord("k1", entityID: id.uuidString, seq: 7, fingerprint: "c5", content: "{\"a\":1}")
        #expect(try await state.markSynced([record], dequeuing: pushed) == 1)
        #expect(try await state.outboxCount() == 0)
        #expect(try await state.record(forKey: "k1") == record)
        #expect(try await state.fingerprints(type: .thoughtContent, entityIDs: [id.uuidString]) == [id.uuidString: "c5"])
    }

    @Test func aWriteDuringAPushKeepsTheEntryQueued() async throws {
        let state = try await enabled()
        let id = UUID()
        state.enqueue([.thought(id)])
        let pushed = try await state.outbox(limit: 10)
        state.enqueue([.thought(id)])
        #expect(try await state.markSynced([syncedRecord("k1", entityID: id.uuidString)], dequeuing: pushed) == 0)
        let remaining = try await state.outbox(limit: 10)
        #expect(remaining.map(\.entity) == [.thought(id)])
        #expect(try await state.record(forKey: "k1") != nil)
        #expect(try await state.markSynced([], dequeuing: remaining) == 1)
        #expect(try await state.outboxCount() == 0)
    }

    @Test func markSyncedReplacesARecordAndKeepsBinaryBase() async throws {
        let state = try await enabled()
        var record = syncedRecord("k1", seq: 1, fingerprint: "c1")
        try await state.markSynced([record])
        record.seq = 9
        record.fingerprint = "c2"
        record.baseContent = Data([0, 1, 2, 255])
        try await state.markSynced([record])
        #expect(try await state.record(forKey: "k1") == record)
        #expect(try await state.recordCount() == 1)
        #expect(try await state.record(forKey: "missing") == nil)
    }

    @Test func fingerprintLookupFiltersByTypeAndChunks() async throws {
        let state = try await enabled()
        let ids = (0..<1200).map { "id\($0)" }
        try await state.markSynced(ids.map { syncedRecord("c-\($0)", type: .thoughtContent, entityID: $0, fingerprint: "c-\($0)") })
        try await state.markSynced([syncedRecord("m-id1", type: .thoughtMeta, entityID: "id1", fingerprint: "m")])
        let content = try await state.fingerprints(type: .thoughtContent, entityIDs: ids)
        #expect(content.count == 1200)
        #expect(content["id77"] == "c-id77")
        #expect(try await state.fingerprints(type: .thoughtMeta, entityIDs: ids) == ["id1": "m"])
    }

    @Test func cursorAndEpochRoundTrip() async throws {
        let state = try await enabled()
        #expect(try await state.cursor() == 0)
        #expect(try await state.epoch() == nil)
        try await state.setCursor(1_234_567_890_123)
        try await state.setEpoch(3)
        #expect(try await state.cursor() == 1_234_567_890_123)
        #expect(try await state.epoch() == 3)
    }

    @Test func resetSyncProgressKeepsTheVault() async throws {
        let state = try await enabled()
        state.enqueue([.settings])
        try await state.markSynced([syncedRecord()])
        try await state.setCursor(5)
        try await state.resetSyncProgress()
        #expect(try await state.cursor() == 0)
        #expect(try await state.outboxCount() == 0)
        #expect(try await state.recordCount() == 0)
        #expect(try await state.configuredVaultID() == "vault-1")
        #expect(state.isEnabled)
    }

    @Test func disableTurnsOffAndForgetsEverything() async throws {
        let state = try await enabled()
        state.enqueue([.settings])
        state.disable()
        #expect(!state.isEnabled)
        state.enqueue([.thought(UUID())])
        try await state.configure(vaultID: "vault-2")
        #expect(try await state.outboxCount() == 0)
        #expect(state.isEnabled)
    }

    @Test func aDifferentVaultStartsOver() async throws {
        let url = temporarySyncFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = SyncState(location: .file(url))
        try await first.configure(vaultID: "a")
        first.enqueue([.settings])
        try await first.setCursor(9)
        await first.flush()

        let second = SyncState(location: .file(url))
        try await second.configure(vaultID: "b")
        #expect(try await second.outboxCount() == 0)
        #expect(try await second.cursor() == 0)
        #expect(try await second.configuredVaultID() == "b")
    }

    @Test func fileSurvivesRelaunchAndIsExcludedFromBackup() async throws {
        let url = temporarySyncFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = SyncState(location: .file(url))
        try await first.configure(vaultID: "a")
        first.enqueue([.tag("swift")])
        try await first.setCursor(42)
        await first.flush()

        let second = SyncState(location: .file(url))
        #expect(second.isEnabled)
        #expect(try await second.configuredVaultID() == "a")
        #expect(try await second.cursor() == 42)
        #expect(try await second.outbox(limit: 10).map(\.entity) == [.tag("swift")])
        let excluded = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
    }

    @Test func aDamagedFileIsRebuiltEmptyKeepingTheVault() async throws {
        let url = temporarySyncFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let first = SyncState(location: .file(url))
            try await first.configure(vaultID: "a")
            try await first.setCursor(42)
        }
        try Data(repeating: 0x41, count: 4096).write(to: url)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let second = SyncState(location: .file(url))
        try await second.configure(vaultID: "a")
        #expect(try await second.cursor() == 0)
        #expect(try await second.configuredVaultID() == "a")
        second.enqueue([.settings])
        #expect(try await second.outboxCount() == 1)
    }

    @Test func aFileFromAnotherSchemaVersionIsRebuilt() async throws {
        let url = temporarySyncFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let database = try SQLiteDatabase(path: url.path)
            try database.execute("PRAGMA user_version = 99")
        }
        let state = SyncState(location: .file(url))
        try await state.configure(vaultID: "a")
        #expect(try await state.cursor() == 0)
        #expect(try await state.configuredVaultID() == "a")
    }

    @Test func anOpenErrorThatIsNotCorruptionLeavesTheFileAlone() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SyncStateTests-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = SyncState(location: .file(directory.appending(path: "sync.sqlite")))
        await #expect(throws: (any Error).self) { try await state.configure(vaultID: "a") }
        #expect(!state.isEnabled)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func aDamagedFileWithoutAKnownVaultTurnsSyncOff() async throws {
        let url = temporarySyncFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: url)
        let state = SyncState(location: .file(url))
        #expect(state.isEnabled)
        await #expect(throws: SyncState.Failure.notConfigured) { try await state.cursor() }
        #expect(!state.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
