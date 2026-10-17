import CryptoKit
import Foundation
import Testing
@testable import ThoughtReps

/// What a contract scenario needs: a transport on a fresh vault, and a way to erase that vault (the dev route on the
/// server, `erase()` on the fake). `erase` returns the new epoch.
struct ContractSubject {
    var transport: any SyncTransport
    var erase: @Sendable () async throws -> Int64
}

/// The HTTP half runs only when `THOUGHTREPS_SYNC_TEST_URL` and `THOUGHTREPS_SYNC_TEST_SECRET` reach the test process
/// (xcodebuild passes `TEST_RUNNER_`-prefixed variables on): a local server, see DEVELOPMENT.md.
enum HTTPTestServer {
    static let url = ProcessInfo.processInfo.environment["THOUGHTREPS_SYNC_TEST_URL"].flatMap(URL.init(string:))
    static let secret = ProcessInfo.processInfo.environment["THOUGHTREPS_SYNC_TEST_SECRET"]
    static var isConfigured: Bool { url != nil && secret != nil }

    /// A transport on a new vault with a random id, so tests never share rows.
    static func transport(vault: String = "t-" + UUID().uuidString.lowercased()) async throws -> HTTPSyncTransport {
        let transport = HTTPSyncTransport(
            baseURL: try #require(url), vaultID: vault, devSecret: try #require(secret), sleep: { _ in }
        )
        try await transport.createVault()
        return transport
    }
}

/// Every scenario is written once against `SyncTransport` and run against both servers.
enum SyncContract {
    static func payload(_ text: String) -> Data { Data(text.utf8) }

    static func record(_ key: String, base: Int64? = nil, deleted: Bool = false, _ text: String = "") -> PushRecord {
        PushRecord(recordKey: key, baseSeq: base, payload: deleted ? Data() : payload(text.isEmpty ? key : text), deleted: deleted)
    }

    static func pulled(_ transport: any SyncTransport, after cursor: Int64 = 0, limit: Int = 500) async throws -> PullPage {
        try await transport.pull(after: cursor, limit: limit)
    }

    static func pushedOK(_ transport: any SyncTransport, _ records: [PushRecord], epoch: Int64) async throws -> (seqs: [String: Int64], headSeq: Int64) {
        guard case .ok(let seqs, let headSeq) = try await transport.push(records, epoch: epoch) else {
            Issue.record("expected the push to commit")
            throw SyncTransportError.unavailable
        }
        return (seqs, headSeq)
    }

    static func roundTrip(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let start = try await transport.head()
        #expect(start.headSeq == 0 && start.liveRecordCount == 0)
        let ok = try await pushedOK(transport, [record("a", "one"), record("b", "two")], epoch: start.epoch)
        #expect(ok.seqs == ["a": 1, "b": 2] && ok.headSeq == 2)
        let page = try await pulled(transport)
        #expect(page.records == [
            PulledRecord(recordKey: "a", seq: 1, payload: payload("one"), deleted: false),
            PulledRecord(recordKey: "b", seq: 2, payload: payload("two"), deleted: false),
        ])
        #expect(page.nextSeq == 2 && page.headSeq == 2 && !page.hasMore && page.epoch == start.epoch)
        let head = try await transport.head()
        #expect(head == SyncHead(headSeq: 2, epoch: start.epoch, liveRecordCount: 2))
        let after = try await pulled(transport, after: 2)
        #expect(after.records.isEmpty && after.nextSeq == 2 && !after.hasMore)
    }

    static func latestVersionOnly(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        _ = try await pushedOK(transport, [record("a", "v1"), record("b", "b1")], epoch: epoch)
        let second = try await pushedOK(transport, [record("a", base: 1, "v2")], epoch: epoch)
        #expect(second.seqs == ["a": 3] && second.headSeq == 3)
        let page = try await pulled(transport)
        #expect(page.records.map(\.recordKey) == ["b", "a"])
        #expect(page.records.map(\.seq) == [2, 3])
        #expect(page.records.last?.payload == payload("v2"))
    }

    static func compareAndSwap(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        _ = try await pushedOK(transport, [record("k")], epoch: epoch)
        #expect(try await transport.push([record("k")], epoch: epoch) == .conflict(keys: ["k"]), "a null baseSeq on an existing row conflicts")
        #expect(try await transport.push([record("k", base: 99)], epoch: epoch) == .conflict(keys: ["k"]), "a stale baseSeq conflicts")
        let mixed = try await transport.push([record("fresh"), record("k", base: 99)], epoch: epoch)
        #expect(mixed == .conflict(keys: ["k"]))
        #expect(try await pulled(transport).records.map(\.recordKey) == ["k"], "a conflicting push commits nothing")
        #expect(try await transport.head().headSeq == 1)
        let ok = try await pushedOK(transport, [record("k", base: 1, "next"), record("absent", base: 7)], epoch: epoch)
        #expect(ok.seqs == ["k": 2, "absent": 3], "a baseSeq on a row that doesn't exist yet passes")
    }

    static func deletions(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        _ = try await pushedOK(transport, [record("a"), record("b")], epoch: epoch)
        #expect(try await transport.head().liveRecordCount == 2)
        let ok = try await pushedOK(transport, [record("a", base: 1, deleted: true)], epoch: epoch)
        #expect(ok.seqs == ["a": 3])
        let page = try await pulled(transport, after: 1)
        #expect(page.records == [
            PulledRecord(recordKey: "b", seq: 2, payload: payload("b"), deleted: false),
            PulledRecord(recordKey: "a", seq: 3, payload: Data(), deleted: true),
        ])
        #expect(try await transport.head().liveRecordCount == 1)
        _ = try await pushedOK(transport, [record("a", base: 3, "back")], epoch: epoch)
        #expect(try await transport.head().liveRecordCount == 2, "a deleted record can be written again")
    }

    static func epochChange(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let old = try await transport.head().epoch
        _ = try await pushedOK(transport, [record("a")], epoch: old)
        let new = try await subject.erase()
        #expect(new == old + 1)
        await #expect(throws: SyncTransportError.epochChanged(server: new)) { try await transport.push([record("b")], epoch: old) }
        let head = try await transport.head()
        #expect(head.epoch == new && head.liveRecordCount == 0)
        let page = try await pulled(transport)
        #expect(page.epoch == new && page.records.isEmpty)
        let ok = try await pushedOK(transport, [record("b")], epoch: new)
        #expect(ok.seqs["b"] == head.headSeq + 1, "seqs never repeat across an erase")
        await #expect(throws: SyncTransportError.epochChanged(server: new)) { try await transport.push([], epoch: old) }
    }

    static func paging(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        _ = try await pushedOK(transport, (1...5).map { record("k\($0)") }, epoch: epoch)
        let first = try await pulled(transport, limit: 2)
        #expect(first.records.map(\.seq) == [1, 2] && first.hasMore && first.nextSeq == 2 && first.headSeq == 5)
        let second = try await pulled(transport, after: first.nextSeq, limit: 2)
        #expect(second.records.map(\.seq) == [3, 4] && second.hasMore && second.nextSeq == 4)
        let third = try await pulled(transport, after: second.nextSeq, limit: 2)
        #expect(third.records.map(\.seq) == [5] && !third.hasMore && third.nextSeq == 5)
        let exact = try await pulled(transport, limit: 5)
        #expect(exact.records.count == 5 && !exact.hasMore && exact.nextSeq == 5)
        let scratch = try await pulled(transport, limit: 3)
        #expect(scratch.records.map(\.seq) == [1, 2, 3] && scratch.hasMore && scratch.nextSeq == 3)
    }

    static func sizeLimits(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        let limit = SyncLimits.maxInlinePayload
        let atLimit = PushRecord(recordKey: "big", baseSeq: nil, payload: Data(repeating: 7, count: limit), deleted: false)
        _ = try await pushedOK(transport, [atLimit], epoch: epoch)
        let over = PushRecord(recordKey: "over", baseSeq: nil, payload: Data(repeating: 7, count: limit + 1), deleted: false)
        await #expect(throws: SyncTransportError.tooLarge) { try await transport.push([over], epoch: epoch) }
        let many = (0..<(SyncLimits.maxRecordsPerPush + 1)).map { record("m\($0)") }
        await #expect(throws: SyncTransportError.tooLarge) { try await transport.push(many, epoch: epoch) }
        let full = (0..<SyncLimits.maxRecordsPerPush).map { record("f\($0)") }
        _ = try await pushedOK(transport, full, epoch: epoch)
        let heavy = (0..<32).map { PushRecord(recordKey: "h\($0)", baseSeq: nil, payload: Data(repeating: 1, count: limit), deleted: false) }
        #expect(heavy.reduce(0) { $0 + $1.payload.count } > SyncLimits.maxBytesPerPush)
        await #expect(throws: SyncTransportError.tooLarge) { try await transport.push(heavy, epoch: epoch) }
        #expect(try await pulled(transport).records.count == 1 + SyncLimits.maxRecordsPerPush, "refused pushes commit nothing")
    }

    static func epochIsCheckedBeforeSize(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let old = try await transport.head().epoch
        let new = try await subject.erase()
        let over = PushRecord(recordKey: "over", baseSeq: nil, payload: Data(repeating: 7, count: SyncLimits.maxInlinePayload + 1), deleted: false)
        await #expect(throws: SyncTransportError.epochChanged(server: new)) { try await transport.push([over], epoch: old) }
        await #expect(throws: SyncTransportError.tooLarge) { try await transport.push([over], epoch: new) }
    }

    static func duplicateKeys(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        await #expect(throws: SyncTransportError.refused(status: 400, message: "Duplicate record keys")) {
            try await transport.push([record("a"), record("a", "again")], epoch: epoch)
        }
        let stale = epoch + 5
        await #expect(throws: SyncTransportError.refused(status: 400, message: "Duplicate record keys"), "400 comes before the epoch check") {
            try await transport.push([record("a"), record("a")], epoch: stale)
        }
        #expect(try await transport.head().headSeq == 0)
    }

    static func emptyPush(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        let empty = try await pushedOK(transport, [], epoch: epoch)
        #expect(empty.seqs.isEmpty && empty.headSeq == 0)
        _ = try await pushedOK(transport, [record("a"), record("b")], epoch: epoch)
        let again = try await pushedOK(transport, [], epoch: epoch)
        #expect(again.seqs.isEmpty && again.headSeq == 2)
        await #expect(throws: SyncTransportError.epochChanged(server: epoch)) { try await transport.push([], epoch: epoch + 1) }
    }

    /// A valid blob name (43 URL-safe characters) for `label`.
    static func blobName(_ label: String) -> String {
        SyncCrypto.base64URL(Data(SHA256.hash(data: Data(label.utf8))))
    }

    static func blobRoundTrip(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        let name = blobName("round trip")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        #expect(try await !transport.hasBlob(name: name, epoch: epoch))
        await #expect(throws: SyncTransportError.blobMissing(name)) { try await transport.getBlob(name: name, epoch: epoch, maxBytes: 10_000) }
        try await transport.putBlob(name: name, data: bytes, epoch: epoch)
        #expect(try await transport.hasBlob(name: name, epoch: epoch))
        #expect(try await transport.getBlob(name: name, epoch: epoch, maxBytes: 10_000) == bytes)
        try await transport.putBlob(name: name, data: bytes, epoch: epoch)
        #expect(try await transport.getBlob(name: name, epoch: epoch, maxBytes: bytes.count) == bytes, "a second upload of a present blob is a no-op")
        await #expect(throws: SyncTransportError.tooLarge) { try await transport.getBlob(name: name, epoch: epoch, maxBytes: bytes.count - 1) }
        #expect(try await !transport.hasBlob(name: blobName("other"), epoch: epoch))
    }

    static func blobsFollowTheEpoch(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let old = try await transport.head().epoch
        let name = blobName("epoch")
        try await transport.putBlob(name: name, data: Data("kept until the erase".utf8), epoch: old)
        let new = try await subject.erase()
        await #expect(throws: SyncTransportError.epochChanged(server: new)) { try await transport.hasBlob(name: name, epoch: old) }
        await #expect(throws: SyncTransportError.epochChanged(server: new)) { try await transport.putBlob(name: name, data: Data("x".utf8), epoch: old) }
        await #expect(throws: SyncTransportError.epochChanged(server: new)) { try await transport.getBlob(name: name, epoch: old, maxBytes: 100) }
        #expect(try await !transport.hasBlob(name: name, epoch: new), "an erase takes the blobs with it")
    }

    static func pointerPushes(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        let name = blobName("pointer target")
        let pointer = PushRecord(recordKey: "big", baseSeq: nil, payload: SyncCrypto.pointer(toBlob: name), deleted: false)
        #expect(try await transport.push([record("small"), pointer], epoch: epoch) == .blobsMissing(names: [name]))
        #expect(try await transport.head().headSeq == 0, "a push with a missing blob commits nothing")
        try await transport.putBlob(name: name, data: Data("sealed record".utf8), epoch: epoch)
        let ok = try await pushedOK(transport, [record("small"), pointer], epoch: epoch)
        #expect(ok.seqs == ["small": 1, "big": 2])
        #expect(try await pulled(transport).records.last == PulledRecord(recordKey: "big", seq: 2, payload: pointer.payload, deleted: false))
        let new = try await subject.erase()
        let again = PushRecord(recordKey: "big", baseSeq: nil, payload: pointer.payload, deleted: false)
        #expect(try await transport.push([again], epoch: new) == .blobsMissing(names: [name]), "the blob did not survive the erase")
    }

    static let liveList = Data((blobName("kept one") + "\n" + blobName("kept two") + "\n").utf8)

    static func garbageCollectionRun(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        let ok = try await pushedOK(transport, [record("a"), record("b")], epoch: epoch)
        #expect(try await transport.startGarbageCollection(liveList: liveList, epoch: epoch, asOfSeq: ok.headSeq - 1) == .stale, "a list built at another head")
        #expect(try await transport.startGarbageCollection(liveList: liveList, epoch: epoch, asOfSeq: ok.headSeq + 1) == .stale)
        #expect(try await transport.startGarbageCollection(liveList: liveList, epoch: epoch, asOfSeq: ok.headSeq) == .started)
    }

    static func garbageCollectionFollowsTheEpoch(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let old = try await transport.head().epoch
        let new = try await subject.erase()
        await #expect(throws: SyncTransportError.epochChanged(server: new)) {
            try await transport.startGarbageCollection(liveList: liveList, epoch: old, asOfSeq: 0)
        }
        #expect(try await transport.startGarbageCollection(liveList: Data(), epoch: new, asOfSeq: 0) == .started, "an empty list is a list")
    }

    static func malformedPointers(_ subject: ContractSubject) async throws {
        let transport = subject.transport
        let epoch = try await transport.head().epoch
        for payload in [Data("TRP1short".utf8), SyncCrypto.pointerMagic + Data(repeating: 0x21, count: SyncCrypto.blobNameLength)] {
            do {
                _ = try await transport.push([PushRecord(recordKey: "bad", baseSeq: nil, payload: payload, deleted: false)], epoch: epoch)
                Issue.record("a malformed pointer should be refused")
            } catch SyncTransportError.refused(let status, _) {
                #expect(status == 400)
            }
        }
        #expect(try await transport.head().headSeq == 0)
    }
}

@Suite("Sync transport contract: fake server")
struct SyncContractFakeTests {
    func subject() -> ContractSubject {
        let server = FakeSyncServer()
        return ContractSubject(transport: server, erase: {
            await server.erase()
            return await server.epoch
        })
    }

    @Test func roundTrip() async throws { try await SyncContract.roundTrip(subject()) }
    @Test func latestVersionOnly() async throws { try await SyncContract.latestVersionOnly(subject()) }
    @Test func compareAndSwap() async throws { try await SyncContract.compareAndSwap(subject()) }
    @Test func deletions() async throws { try await SyncContract.deletions(subject()) }
    @Test func epochChange() async throws { try await SyncContract.epochChange(subject()) }
    @Test func paging() async throws { try await SyncContract.paging(subject()) }
    @Test func sizeLimits() async throws { try await SyncContract.sizeLimits(subject()) }
    @Test func epochIsCheckedBeforeSize() async throws { try await SyncContract.epochIsCheckedBeforeSize(subject()) }
    @Test func duplicateKeys() async throws { try await SyncContract.duplicateKeys(subject()) }
    @Test func emptyPush() async throws { try await SyncContract.emptyPush(subject()) }
    @Test func blobRoundTrip() async throws { try await SyncContract.blobRoundTrip(subject()) }
    @Test func blobsFollowTheEpoch() async throws { try await SyncContract.blobsFollowTheEpoch(subject()) }
    @Test func pointerPushes() async throws { try await SyncContract.pointerPushes(subject()) }
    @Test func malformedPointers() async throws { try await SyncContract.malformedPointers(subject()) }
    @Test func garbageCollectionRun() async throws { try await SyncContract.garbageCollectionRun(subject()) }
    @Test func garbageCollectionFollowsTheEpoch() async throws { try await SyncContract.garbageCollectionFollowsTheEpoch(subject()) }
}

/// What only the fake can show: the dev routes can't force these.
@Suite("Sync transport contract: fake server only")
struct SyncContractFakeOnlyTests {
    @Test func aBadKeyIsRefusedLikeTheServerDoes() async throws {
        let server = FakeSyncServer()
        let epoch = await server.epoch
        await #expect(throws: SyncTransportError.refused(status: 400, message: "Invalid request body")) {
            try await server.push([SyncContract.record("not a key!")], epoch: epoch)
        }
    }
}

@Suite("Sync transport contract: local server", .enabled(if: HTTPTestServer.isConfigured, "set TEST_RUNNER_THOUGHTREPS_SYNC_TEST_URL and TEST_RUNNER_THOUGHTREPS_SYNC_TEST_SECRET (a local sync server, see DEVELOPMENT.md)"))
struct SyncContractHTTPTests {
    func subject() async throws -> ContractSubject {
        let transport = try await HTTPTestServer.transport()
        return ContractSubject(transport: transport, erase: { try await transport.eraseVault() })
    }

    @Test func roundTrip() async throws { try await SyncContract.roundTrip(subject()) }
    @Test func latestVersionOnly() async throws { try await SyncContract.latestVersionOnly(subject()) }
    @Test func compareAndSwap() async throws { try await SyncContract.compareAndSwap(subject()) }
    @Test func deletions() async throws { try await SyncContract.deletions(subject()) }
    @Test func epochChange() async throws { try await SyncContract.epochChange(subject()) }
    @Test func paging() async throws { try await SyncContract.paging(subject()) }
    @Test func sizeLimits() async throws { try await SyncContract.sizeLimits(subject()) }
    @Test func epochIsCheckedBeforeSize() async throws { try await SyncContract.epochIsCheckedBeforeSize(subject()) }
    @Test func duplicateKeys() async throws { try await SyncContract.duplicateKeys(subject()) }
    @Test func emptyPush() async throws { try await SyncContract.emptyPush(subject()) }
    @Test func blobRoundTrip() async throws { try await SyncContract.blobRoundTrip(subject()) }
    @Test func blobsFollowTheEpoch() async throws { try await SyncContract.blobsFollowTheEpoch(subject()) }
    @Test func pointerPushes() async throws { try await SyncContract.pointerPushes(subject()) }
    @Test func malformedPointers() async throws { try await SyncContract.malformedPointers(subject()) }
    @Test func garbageCollectionRun() async throws { try await SyncContract.garbageCollectionRun(subject()) }
    @Test func garbageCollectionFollowsTheEpoch() async throws { try await SyncContract.garbageCollectionFollowsTheEpoch(subject()) }

    @Test func aSecondRunSoonAfterTheFirstIsRateLimited() async throws {
        let transport = try await HTTPTestServer.transport()
        let epoch = try await transport.head().epoch
        #expect(try await transport.startGarbageCollection(liveList: SyncContract.liveList, epoch: epoch, asOfSeq: 0) == .started)
        guard case .rateLimited(let seconds) = try await transport.startGarbageCollection(liveList: SyncContract.liveList, epoch: epoch, asOfSeq: 0) else {
            Issue.record("expected the second run to be rate limited")
            return
        }
        #expect(seconds >= 1)
    }

    @Test func aWrongSecretIsRefused() async throws {
        let good = try await HTTPTestServer.transport()
        let bad = HTTPSyncTransport(baseURL: good.baseURL, vaultID: good.vaultID, devSecret: "wrong", sleep: { _ in })
        await #expect(throws: SyncTransportError.refused(status: 401, message: "Unauthorized")) { try await bad.head() }
    }

    @Test func anUnknownVaultIsRefused() async throws {
        let server = try #require(HTTPTestServer.url)
        let transport = HTTPSyncTransport(baseURL: server, vaultID: "missing-" + UUID().uuidString.lowercased(), devSecret: try #require(HTTPTestServer.secret), sleep: { _ in })
        await #expect(throws: SyncTransportError.refused(status: 404, message: "Unknown vault")) { try await transport.head() }
    }

    @Test func aBlobStaysReadableAcrossTransports() async throws {
        let first = try await HTTPTestServer.transport()
        let second = HTTPSyncTransport(baseURL: first.baseURL, vaultID: first.vaultID, devSecret: try #require(HTTPTestServer.secret), sleep: { _ in })
        let epoch = try await first.head().epoch
        let name = SyncContract.blobName("shared")
        try await first.putBlob(name: name, data: Data("from the first device".utf8), epoch: epoch)
        #expect(try await second.getBlob(name: name, epoch: epoch, maxBytes: 100) == Data("from the first device".utf8))
    }

    @Test func theServerClockOffsetIsTracked() async throws {
        let suite = "SyncContractHTTP-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = try await HTTPTestServer.transport()
        let tracked = HTTPSyncTransport(
            baseURL: good.baseURL, vaultID: good.vaultID, devSecret: try #require(HTTPTestServer.secret),
            offset: ServerClockOffset(defaults: defaults)
        )
        for _ in 0..<12 where defaults.object(forKey: ServerClockOffset.key) == nil { _ = try await tracked.head() }
        #expect(defaults.object(forKey: ServerClockOffset.key) != nil, "three accepted samples adopt an offset")
        #expect(abs(ServerClockOffset(defaults: defaults).current) < 5, "a local server shares this machine's clock")
    }
}
