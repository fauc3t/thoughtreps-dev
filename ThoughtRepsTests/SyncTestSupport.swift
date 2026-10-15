import Foundation
import SwiftData
import Testing
import os
@testable import ThoughtReps

/// An in-process server that implements the `SyncTransport` contract exactly (all-or-nothing pushes, per-record
/// compare-and-swap on the seq, seqs assigned in order, pulls of the latest version only, 410 below the pruned
/// seq), with controls to make it misbehave.
actor FakeSyncServer: SyncTransport {
    struct Row: Equatable {
        var seq: Int64
        var deleted: Bool
        var payload: Data
    }

    enum Event: Equatable {
        case push([String])
        case putBlob(String)
    }

    private(set) var rows: [String: Row] = [:]
    private(set) var headSeq: Int64 = 0
    private(set) var epoch: Int64 = 1
    private(set) var prunedBeforeSeq: Int64 = 0
    private(set) var blobs: [String: Data] = [:]

    private(set) var pushCalls = 0
    private(set) var pullCalls = 0
    private(set) var headCalls = 0
    private(set) var conflicts = 0
    private(set) var epochRejections = 0
    /// How many times each record key was pushed (and committed).
    private(set) var recordPushes: [String: Int] = [:]
    private(set) var blobPuts: [String: Int] = [:]
    private(set) var blobGets = 0
    private(set) var events: [Event] = []

    private var dropPushResponses = 0
    private var failCountdown: Int?
    private var beforeNextPush: (@Sendable () async -> Void)?
    private var afterNextPullQuery: (@Sendable () async -> Void)?
    private var stallingPulls = false

    var liveRecordCount: Int { rows.values.filter { !$0.deleted }.count }
    var callCount: Int { pushCalls + pullCalls + headCalls }

    // MARK: Controls

    /// The next push commits, then fails as if the response was lost.
    func dropNextPushResponse() {
        dropPushResponses += 1
    }

    /// After `calls` more successful calls, the next one fails before doing anything.
    func failNextCall(after calls: Int = 0) {
        failCountdown = calls
    }

    func clearFailures() {
        failCountdown = nil
        dropPushResponses = 0
    }

    /// Runs `hook` inside the next push, before it is checked (another device getting in first).
    func beforeNextPush(_ hook: @escaping @Sendable () async -> Void) {
        beforeNextPush = hook
    }

    /// Runs `hook` inside the next pull, after its page was read and before the head is (a push landing in between).
    func afterNextPullQuery(_ hook: @escaping @Sendable () async -> Void) {
        afterNextPullQuery = hook
    }

    /// Every pull answers "more to come" without moving past the cursor.
    func stallPulls(_ stalling: Bool = true) {
        stallingPulls = stalling
    }

    /// The vault is erased: every record and blob is gone and the epoch moves on.
    func erase() {
        rows = [:]
        blobs = [:]
        epoch += 1
    }

    /// Drops tombstones older than `seq` and makes a pull from before it answer 410.
    func prune(tombstonesBelow seq: Int64) {
        rows = rows.filter { !($0.value.deleted && $0.value.seq < seq) }
        prunedBeforeSeq = max(prunedBeforeSeq, seq)
    }

    /// Takes every blob off the server and hands them back.
    func removeAllBlobs() -> [String: Data] {
        defer { blobs = [:] }
        return blobs
    }

    func restoreBlobs(_ saved: [String: Data]) {
        blobs.merge(saved) { _, new in new }
    }

    /// Adds a record as another (newer) version of the app might have written it.
    func inject(recordKey: String, payload: Data, deleted: Bool = false) -> Int64 {
        headSeq += 1
        rows[recordKey] = Row(seq: headSeq, deleted: deleted, payload: payload)
        return headSeq
    }

    func bumpEpoch() {
        epoch += 1
    }

    func forget(recordKeys: [String]) {
        for key in recordKeys { rows[key] = nil }
    }

    // MARK: Contract

    private func begin() throws {
        if let countdown = failCountdown {
            if countdown == 0 {
                failCountdown = nil
                throw SyncTransportError.unavailable
            }
            failCountdown = countdown - 1
        }
    }

    func push(_ records: [PushRecord], epoch pushEpoch: Int64) async throws -> PushResult {
        try begin()
        pushCalls += 1
        if let hook = beforeNextPush {
            beforeNextPush = nil
            await hook()
        }
        guard pushEpoch == epoch else {
            epochRejections += 1
            throw SyncTransportError.epochChanged(server: epoch)
        }
        guard records.count <= SyncLimits.maxRecordsPerPush, records.reduce(0, { $0 + $1.payload.count }) <= SyncLimits.maxBytesPerPush,
              records.allSatisfy({ $0.payload.count <= SyncLimits.maxInlinePayload }),
              Set(records.map(\.recordKey)).count == records.count
        else { throw SyncTransportError.tooLarge }
        let failed = records.filter { record in
            guard let row = rows[record.recordKey] else { return false }
            return row.seq != record.baseSeq
        }
        guard failed.isEmpty else {
            conflicts += 1
            return .conflict(keys: failed.map(\.recordKey))
        }
        var seqs: [String: Int64] = [:]
        for (index, record) in records.enumerated() {
            let seq = headSeq + Int64(index) + 1
            rows[record.recordKey] = Row(seq: seq, deleted: record.deleted, payload: record.payload)
            seqs[record.recordKey] = seq
            recordPushes[record.recordKey, default: 0] += 1
        }
        headSeq += Int64(records.count)
        events.append(.push(records.map(\.recordKey)))
        if dropPushResponses > 0 {
            dropPushResponses -= 1
            throw SyncTransportError.unavailable
        }
        return .ok(seqs: seqs, headSeq: headSeq)
    }

    func pull(after cursor: Int64, limit: Int, fullResync: Bool) async throws -> PullResult {
        try begin()
        pullCalls += 1
        if !fullResync, cursor < prunedBeforeSeq { return .gone }
        if stallingPulls { return .page(PullPage(records: [], nextSeq: cursor, headSeq: headSeq, epoch: epoch, hasMore: true)) }
        let snapshotHead = headSeq
        let newer = rows.filter { $0.value.seq > cursor }.sorted { $0.value.seq < $1.value.seq }
        let page = newer.prefix(limit).map { PulledRecord(recordKey: $0.key, seq: $0.value.seq, payload: $0.value.payload, deleted: $0.value.deleted) }
        let hasMore = newer.count > limit
        if let hook = afterNextPullQuery {
            afterNextPullQuery = nil
            await hook()
        }
        return .page(PullPage(
            records: page, nextSeq: hasMore ? (page.last?.seq ?? cursor) : snapshotHead, headSeq: headSeq, epoch: epoch, hasMore: hasMore
        ))
    }

    func head() async throws -> SyncHead {
        try begin()
        headCalls += 1
        return SyncHead(headSeq: headSeq, epoch: epoch, liveRecordCount: liveRecordCount)
    }

    /// Seeds a blob as the vault's current epoch would accept it.
    func putBlob(name: String, data: Data) async throws {
        try await putBlob(name: name, data: data, epoch: epoch)
    }

    func putBlob(name: String, data: Data, epoch blobEpoch: Int64) async throws {
        try begin()
        guard blobEpoch == epoch else {
            epochRejections += 1
            throw SyncTransportError.epochChanged(server: epoch)
        }
        blobs[name] = data
        blobPuts[name, default: 0] += 1
        events.append(.putBlob(name))
    }

    func getBlob(name: String, maxBytes: Int) async throws -> Data {
        try begin()
        blobGets += 1
        guard let data = blobs[name] else { throw SyncTransportError.blobMissing(name) }
        guard data.count <= maxBytes else { throw SyncTransportError.tooLarge }
        return data
    }

    func hasBlob(name: String, epoch blobEpoch: Int64) async throws -> Bool {
        try begin()
        guard blobEpoch == epoch else {
            epochRejections += 1
            throw SyncTransportError.epochChanged(server: epoch)
        }
        return blobs[name] != nil
    }
}

/// Decodes the thoughts the server holds, to compare with a device's.
extension FakeSyncServer {
    func liveThoughtIDs(keys: SyncKeys, vaultID: String) -> Set<UUID> {
        var ids = Set<UUID>()
        for (key, row) in rows where !row.deleted {
            var frame = row.payload
            if let name = SyncCrypto.blobName(inPointer: frame), let sealed = blobs[name],
               let inner = try? SyncCrypto.openBlob(sealed, vaultID: vaultID, name: name, keys: keys) {
                frame = inner
            }
            guard let opened = try? SyncCrypto.open(frame, vaultID: vaultID, recordKey: key, keys: keys),
                  case .thoughtContent(let content)? = try? SyncPayload.decode(opened.plaintext)
            else { continue }
            ids.insert(content.id)
        }
        return ids
    }
}

/// A virtual clock for `SyncTriggers`: `sleep` parks until `advance` moves time past its deadline.
actor ManualSleeper {
    private struct Waiter {
        var deadline: Duration
        var continuation: CheckedContinuation<Void, Error>
        var id: Int
    }

    private var now = Duration.zero
    private var waiters: [Waiter] = []
    private var nextID = 0
    private(set) var sleepCalls = 0

    func sleep(_ duration: Duration) async throws {
        sleepCalls += 1
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(deadline: now + duration, continuation: continuation, id: id))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func advance(by duration: Duration) {
        now += duration
        let due = waiters.filter { $0.deadline <= now }
        waiters.removeAll { $0.deadline <= now }
        for waiter in due { waiter.continuation.resume() }
    }

    var waiting: Int { waiters.count }
}

/// One simulated device: its own in-memory store, `sync.sqlite`, defaults and wall clock, all against a shared server.
@MainActor
final class SyncDevice {
    static let vaultKey = Data(repeating: 9, count: 32)
    static let vaultID = "test-vault"

    let name: String
    let container: ModelContainer
    let state = SyncState(location: .inMemory)
    let defaults: UserDefaults
    let index = SearchIndex(location: .inMemory)
    let server: FakeSyncServer
    let keys: SyncKeys
    /// How far this device's wall clock is from the test's.
    var clockOffset: TimeInterval
    var failSaves = 0
    /// Saves that go through before `failSaves` starts failing.
    var skipSaves = 0
    var store: ThoughtStore
    var engine: SyncEngine!
    private let config: SyncEngine.Configuration

    static let testCodec = SyncBlobCodec(
        image: { ProcessedImage(data: $0, thumbnailData: Data([$0.first ?? 0]), width: 40, height: 30) },
        file: { data, record in
            FileDraft(
                id: record.id, filename: record.filename, typeIdentifier: record.typeIdentifier, byteCount: data.count,
                thumbnailData: Data([data.first ?? 0]), data: data
            )
        }
    )

    init(
        _ name: String, server: FakeSyncServer, clockOffset: TimeInterval = 0, config: SyncEngine.Configuration = .init(),
        defaultInterval: Int = 7
    ) async throws {
        self.name = name
        self.server = server
        self.clockOffset = clockOffset
        self.config = config
        keys = try SyncKeys(vaultKey: Self.vaultKey)
        container = try ModelContainer.thoughtReps(inMemory: true)
        let suite = "SyncDevice-\(name)-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var store = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: defaultInterval, saveErrors: SaveErrorCenter(), save: { _ in }
        )
        store.pendingImageSaves = PendingImageSaves(defaults: defaults)
        store.ratingPrompt = RatingPrompt(defaults: defaults)
        store.searchIndex = index
        store.syncState = state
        store.syncDefaults = defaults
        self.store = store
        self.store.save = { [unowned self] context in
            if self.skipSaves > 0 { self.skipSaves -= 1; try context.save(); return }
            if self.failSaves > 0 {
                self.failSaves -= 1
                throw InjectedSaveFailure()
            }
            try context.save()
        }
        try await state.configure(vaultID: Self.vaultID)
        makeEngine()
    }

    var context: ModelContext { container.mainContext }

    /// A fresh engine over the same state, as after a relaunch.
    func makeEngine(config: SyncEngine.Configuration? = nil, wrap: (SyncLocalStore) -> SyncLocalStore = { $0 }) {
        let container = container
        let state = state
        let local = ThoughtSyncLocal(store: store, reconcile: { [self] in
            let settings = await MainActor.run { SettingsRecord.current(defaults: self.defaults) }
            _ = try? await Task.detached {
                try await SyncReconciler(modelContainer: container).reconcile(state: state, settings: settings)
            }.value
        })
        engine = SyncEngine(
            transport: server, state: state, local: wrap(local), keys: keys, vaultID: Self.vaultID, codec: Self.testCodec,
            config: config ?? self.config
        )
    }

    func now(_ global: Date) -> Date { global.addingTimeInterval(clockOffset) }

    @discardableResult
    func sync() async -> SyncEngine.Status {
        await state.flush()
        return await engine.syncNow()
    }

    /// Queues everything the store has that sync.sqlite doesn't show as synced.
    @discardableResult
    func reconcile() async throws -> SyncReconciler.Summary {
        let container = container
        let settings = SettingsRecord.current(defaults: defaults)
        let state = state
        return try await Task.detached {
            try await SyncReconciler(modelContainer: container).reconcile(state: state, settings: settings)
        }.value
    }

    func thoughts() throws -> [Thought] {
        try context.fetch(FetchDescriptor<Thought>(sortBy: [SortDescriptor(\.id)]))
    }

    func thought(_ id: UUID) throws -> Thought? {
        try context.fetch(FetchDescriptor<Thought>(predicate: #Predicate { $0.id == id })).first
    }

    func tombstones() throws -> [Tombstone] {
        try context.fetch(FetchDescriptor<Tombstone>(sortBy: [SortDescriptor(\.id)]))
    }

    /// Everything that should be identical on devices that have synced to quiescence.
    func canonicalDump() throws -> [String] {
        var lines: [String] = []
        var usedTags = Set<String>()
        for thought in try thoughts() {
            let content = try SyncPayload.thoughtContent(ThoughtContentRecord(thought)).encoded()
            let meta = try SyncPayload.thoughtMeta(ThoughtMetaRecord(thought)).encoded()
            let assets = (thought.images ?? []).sorted { $0.id.uuidString < $1.id.uuidString }.map { "\($0.id)=\($0.data?.base64EncodedString() ?? "-")" }
                + (thought.files ?? []).sorted { $0.id.uuidString < $1.id.uuidString }.map { "\($0.id)=\($0.data?.base64EncodedString() ?? "-")" }
            lines.append("T \(thought.id) \(SyncPayload.hash(of: content)) \(SyncPayload.hash(of: meta)) \(assets.joined(separator: ","))")
            usedTags.formUnion((thought.tags ?? []).map(\.name))
        }
        for tag in try context.fetch(FetchDescriptor<ThoughtReps.Tag>(sortBy: [SortDescriptor(\.name)])) where usedTags.contains(tag.name) {
            lines.append("G \(tag.name) \(tag.displayName) \(tag.colorHex ?? "-") \(SyncFingerprint.exact(tag.updatedAt))")
        }
        let settings = SettingsRecord.current(defaults: defaults)
        lines.append("S \(settings.defaultIntervalDays) \(SyncFingerprint.exact(settings.changedAt))")
        return lines
    }

    func expectClean(_ message: String = "") async throws {
        let violations = try IntegrityChecker.check(context)
        #expect(violations.isEmpty, "\(name) \(message) integrity: \(violations.map(\.description))")
        let indexViolations = try await SearchIndexChecker.check(context, index: index)
        #expect(indexViolations.isEmpty, "\(name) \(message) search index: \(indexViolations)")
    }
}

extension SyncEngine.Configuration {
    static func paged(pull: Int, push: Int = 49) -> SyncEngine.Configuration {
        var config = SyncEngine.Configuration()
        config.pullLimit = pull
        config.pushEntities = push
        return config
    }
}

/// Syncs every device in turn until a whole round changes nothing (nothing pending, no new records).
@MainActor
func syncToQuiescence(_ devices: [SyncDevice], server: FakeSyncServer, maxRounds: Int = 12) async throws {
    var lastHead: Int64 = -1
    for _ in 0..<maxRounds {
        for device in devices { await device.sync() }
        var pending = 0
        for device in devices { pending += try await device.state.outboxCount() }
        let head = await server.headSeq
        if pending == 0, head == lastHead { return }
        lastHead = head
    }
}

/// Forwards to the real local store and counts the batches the engine hands to `apply`.
final class CountingLocal: SyncLocalStore, @unchecked Sendable {
    private let inner: SyncLocalStore
    private let thoughtsPerApply = OSAllocatedUnfairLock(initialState: [Int]())

    init(_ inner: SyncLocalStore) {
        self.inner = inner
    }

    var applies: [Int] { thoughtsPerApply.withLock { $0 } }

    func snapshots(of entities: [SyncEntity]) async throws -> [SyncSnapshot] { try await inner.snapshots(of: entities) }
    func blobBytes(_ refs: [BlobRef]) async throws -> [BlobRef: Data] { try await inner.blobBytes(refs) }
    func missingBlobs(for contents: [ThoughtContentRecord]) async throws -> Set<BlobRef> { try await inner.missingBlobs(for: contents) }
    func discardUnchanged(_ expected: [String: String], now: Date) async -> Bool { await inner.discardUnchanged(expected, now: now) }
    func reconcile() async { await inner.reconcile() }

    func apply(_ batch: RemoteBatch, now: Date) async -> RemoteOutcome {
        thoughtsPerApply.withLock { $0.append(batch.thoughts.count) }
        return await inner.apply(batch, now: now)
    }
}
